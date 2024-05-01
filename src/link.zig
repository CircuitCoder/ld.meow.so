const load = @import("./load.zig");
const std = @import("std");
const util = @import("./util.zig");

// We'll use a colon-separated list here, because we don't want to induce any dyn linking on ourselves.
const SEARCH: [:0]const u8 = "/usr/lib:/lib";

pub const LinkContext = struct {
    loaded: std.StringHashMap(load.LoadedElf),

    pub fn root(alloc: std.mem.Allocator) LinkContext {
        return LinkContext{
            .loaded = std.StringHashMap(load.LoadedElf).init(alloc),
        };
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
                try ctx.loaded.put(std.mem.span(lib_name), lib);
            },
            else => {
                _ = try std.io.getStdOut().write("Unimp d_tag: ");
                try util.printNumHex(@bitCast(d.d_tag));
                _ = try std.io.getStdOut().write("\n");
            },
        }
    }
}

inline fn elf_reloc_perform(dyn: load.Dyn, base: [*]u8, offset: u64, ty: u32, sym: u32, info: u64, addend: i64) !void {
    _ = dyn;
    _ = sym;
    _ = info;
    switch (ty) {
        std.elf.R_X86_64_RELATIVE => {
            const tgt: *u64 = @alignCast(@ptrCast(base + offset));
            tgt.* = @as(u64, @bitCast(@intFromPtr(base))) + @as(u64, @bitCast(addend));
        },
        else => {
            _ = try std.io.getStdOut().write("Unimp r_type: ");
            try util.printNumHex(@intCast(ty));
            _ = try std.io.getStdOut().write("\n");
        },
    }
}

pub fn elf_reloc(dyn: load.Dyn, base: [*]u8) !void {
    _ = try std.io.getStdOut().write("Reloc!\n");
    if (dyn.rela) |t|
        for (t) |r|
            try elf_reloc_perform(dyn, base, r.r_offset, r.r_type(), r.r_sym(), r.r_info, r.r_addend);

    if (dyn.rel) |t|
        for (t) |r|
            try elf_reloc_perform(dyn, base, r.r_offset, r.r_type(), r.r_sym(), r.r_info, 0);
}
