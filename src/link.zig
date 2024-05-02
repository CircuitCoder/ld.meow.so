const load = @import("./load.zig");
const std = @import("std");
const util = @import("./util.zig");

// We'll use a colon-separated list here, because we don't want to induce any dyn linking on ourselves.
const SEARCH: [:0]const u8 = "/usr/lib:/lib";

const LinkError = error{
    ConflictingGlobalSymbols,
    SymbolNotFound,
};

pub const LinkContextState = union(enum) { trivial: void, loaded: struct {
    map: std.StringHashMap(load.LoadedElf),
    topo: std.ArrayList([]const u8),
} };

pub const LinkContext = struct {
    state: LinkContextState,

    pub fn trivial() LinkContext {
        return LinkContext{ .state = LinkContextState{
            .trivial = void{},
        } };
    }

    pub fn root(alloc: std.mem.Allocator) LinkContext {
        return LinkContext{ .state = LinkContextState{ .loaded = .{
            .map = std.StringHashMap(load.LoadedElf).init(alloc),
            .topo = std.ArrayList([]const u8).init(alloc),
        } } };
    }

    pub fn lookup(self: *const LinkContext, name: []u8, current: load.Dyn, current_base: [*]u8) !?[*]u8 {
        // FIXME: LD_PRELOAD

        var found: ?std.elf.Elf64_Sym = null;
        var at: [*]u8 = undefined;

        // Query self
        if (current.hash.lookup(name, current)) |symidx| {
            const sym: std.elf.Elf64_Sym = current.symtab[symidx];

            _ = try std.io.getStdOut().write("Found in local: ");
            try util.printNumHex(@intFromPtr(current_base + sym.st_value));
            _ = try std.io.getStdOut().write("\n");

            switch (sym.st_bind()) {
                std.elf.STB_LOCAL => {
                    return current_base + sym.st_value;
                },
                else => {
                    found = sym;
                    at = current_base + sym.st_value;
                },
            }
        }

        switch (self.state) {
            .trivial => {},
            .loaded => |s| {
                var it = s.map.valueIterator();
                while (it.next()) |elf| {
                    if (elf.*.dyn) |d| {
                        const symidx: ?usize = d.hash.lookup(name, d);
                        if (symidx == null) continue;

                        const sym: std.elf.Elf64_Sym = d.symtab[symidx.?];
                        const bind = sym.st_bind();
                        switch (bind) {
                            std.elf.STB_LOCAL => {
                                // Local
                                continue;
                            },
                            std.elf.STB_GLOBAL => {
                                if (found != null and found.?.st_bind() == std.elf.STB_GLOBAL) {
                                    _ = try std.io.getStdOut().write("Conflicting global symbol: ");
                                    _ = try std.io.getStdOut().write(name);
                                    _ = try std.io.getStdOut().write("\n");
                                    return LinkError.ConflictingGlobalSymbols;
                                }

                                found = sym;
                                at = elf.base + sym.st_value;
                            },
                            std.elf.STB_WEAK => {
                                if (found == null) {
                                    found = sym;
                                    at = elf.base + sym.st_value;
                                }
                            },
                            else => {
                                _ = try std.io.getStdOut().write("Unimp st_bind: ");
                                try util.printNumHex(@intCast(bind));
                                _ = try std.io.getStdOut().write("\n");
                            },
                        }
                    }
                }
            },
        }

        if (found == null) return null;
        return at;
    }

    pub fn append(self: *LinkContext, name: []const u8, elf: load.LoadedElf) !void {
        switch (self.state) {
            .loaded => |*s| {
                try s.map.put(name, elf);
                try s.topo.append(name);
            },
            .trivial => {},
        }
    }
};

pub fn elf_link(elf: load.LoadedElf, page_size: usize, ctx: *LinkContext) !void {
    if (elf.dyn == null) {
        return;
    }

    const dyn = elf.dyn.?;

    for (dyn.section) |d| {
        switch (d.d_tag) {
            std.elf.DT_NULL => {
                continue;
            },
            std.elf.DT_NEEDED => {
                _ = try std.io.getStdOut().write("Loading library: ");
                const lib_name: [*:0]u8 = @ptrCast(dyn.strtab + d.d_val);
                _ = try std.io.getStdOut().write(std.mem.sliceTo(lib_name, 0));
                _ = try std.io.getStdOut().write("\n");
                const lib = try load.elf_load(lib_name, page_size, SEARCH.ptr);
                try elf_link(lib, page_size, ctx);
                try ctx.append(std.mem.span(lib_name), lib);
            },
            std.elf.DT_STRTAB, std.elf.DT_SYMTAB, std.elf.DT_HASH, std.elf.DT_GNU_HASH, std.elf.DT_RELA, std.elf.DT_RELAENT, std.elf.DT_RELASZ, std.elf.DT_REL, std.elf.DT_RELENT, std.elf.DT_RELSZ, load.Consts.DT_RELR, load.Consts.DT_RELRENT, load.Consts.DT_RELRSZ, std.elf.DT_JMPREL, std.elf.DT_PLTREL, std.elf.DT_PLTRELSZ, std.elf.DT_SONAME, std.elf.DT_INIT, std.elf.DT_INIT_ARRAY, std.elf.DT_INIT_ARRAYSZ => {}, // Handled in load
            std.elf.DT_STRSZ, std.elf.DT_SYMENT => {}, // Ignored
            else => {
                _ = try std.io.getStdOut().write("Unimp d_tag: ");
                try util.printNumHex(@bitCast(d.d_tag));
                _ = try std.io.getStdOut().write("\n");
            },
        }
    }

    try elf_reloc(dyn, elf.base, ctx);
}

inline fn elf_reloc_perform(dyn: load.Dyn, base: [*]u8, ctx: *const LinkContext, offset: u64, ty: u32, sym: u32, addend: ?i64) !void {
    // Symbol lookup
    const symbol_loc: [*]u8 = switch (@as(std.elf.R_X86_64, @enumFromInt(ty))) {
        std.elf.R_X86_64.JUMP_SLOT, std.elf.R_X86_64.GLOB_DAT, std.elf.R_X86_64.@"64" => blk: {
            const sym_ent = dyn.symtab[sym];
            const sym_name = std.mem.span(@as([*:0]u8, @ptrCast(dyn.strtab + sym_ent.st_name)));
            _ = try std.io.getStdOut().write("Linking symbol: ");
            _ = try std.io.getStdOut().write(sym_name);
            _ = try std.io.getStdOut().write("...\n");
            const sym_concrete = try ctx.lookup(sym_name, dyn, base);
            if (sym_concrete == null) {
                _ = try std.io.getStdOut().write("Symbol not found: ");
                _ = try std.io.getStdOut().write(sym_name);
                _ = try std.io.getStdOut().write("\n");
                // return LinkError.SymbolNotFound;
                return;
            }
            break :blk sym_concrete.?;
        },
        else => undefined,
    };
    const symbol_loc_i64: i64 = @bitCast(@intFromPtr(symbol_loc));
    _ = try std.io.getStdOut().write("Reloc tgt: ");
    try util.printNumHex(@intFromPtr(base + offset));
    _ = try std.io.getStdOut().write("\n");
    switch (@as(std.elf.R_X86_64, @enumFromInt(ty))) {
        std.elf.R_X86_64.RELATIVE => {
            const tgt: *i64 = @alignCast(@ptrCast(base + offset));
            const real_addent = addend orelse tgt.*;
            tgt.* = @as(i64, @bitCast(@intFromPtr(base))) + real_addent;
        },
        std.elf.R_X86_64.GLOB_DAT, std.elf.R_X86_64.JUMP_SLOT => { // TODO: lazy jump slot
            const tgt: *i64 = @alignCast(@ptrCast(base + offset));
            tgt.* = symbol_loc_i64;
        },
        std.elf.R_X86_64.@"64" => {
            const tgt: *i64 = @alignCast(@ptrCast(base + offset));
            const real_addent = addend orelse tgt.*;
            tgt.* = symbol_loc_i64 + real_addent;
        },
        else => {
            _ = try std.io.getStdOut().write("Unimp r_type: ");
            try util.printNumHex(@intCast(ty));
            _ = try std.io.getStdOut().write("\n");
        },
    }
}

pub fn elf_reloc(dyn: load.Dyn, base: [*]u8, ctx: *const LinkContext) !void {
    _ = try std.io.getStdOut().write("Start relocation\n");
    if (dyn.rela) |t|
        for (t) |r|
            try elf_reloc_perform(dyn, base, ctx, r.r_offset, r.r_type(), r.r_sym(), r.r_addend);

    if (dyn.rel) |t|
        for (t) |r|
            try elf_reloc_perform(dyn, base, ctx, r.r_offset, r.r_type(), r.r_sym(), 0);

    if (dyn.jmprel) |j| {
        switch (j) {
            .rel => |t| {
                for (t) |r|
                    try elf_reloc_perform(dyn, base, ctx, r.r_offset, r.r_type(), r.r_sym(), 0);
            },
            .rela => |t| {
                for (t) |r|
                    try elf_reloc_perform(dyn, base, ctx, r.r_offset, r.r_type(), r.r_sym(), r.r_addend);
            },
        }
    }

    if (dyn.relr) |t| {
        var loc: [*]u64 = undefined;
        for (t) |ent| {
            if (ent & 1 == 0) { // Odd entry
                loc = @alignCast(@ptrCast(base + ent));
                loc[0] +%= @intFromPtr(base);
                loc += 1;
            } else {
                for (0..62) |i| {
                    if (((ent >> @intCast(i + 1)) & 1) != 0) {
                        loc[i] +%= @intFromPtr(base);
                    }
                }
                loc += 63;
            }
        }
    }
}
