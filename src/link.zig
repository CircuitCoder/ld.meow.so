const load = @import("./load.zig");
const std = @import("std");
const util = @import("./util.zig");

// We'll use a colon-separated list here, because we don't want to induce any dyn linking on ourselves.
const SEARCH: [:0]const u8 = "/usr/lib:/lib";

pub const LinkContext = struct {
    syms: std.StringHashMap(std.elf.Elf64_Sym),
    loaded: std.StringHashMap(void),

    pub fn root(alloc: std.mem.Allocator) LinkContext {
        return LinkContext{
            .syms = std.StringHashMap(std.elf.Elf64_Sym).init(alloc),
            .loaded = std.StringHashMap(void).init(alloc),
        };
    }
};

pub fn elf_link(elf: load.LoadedElf, page_size: usize, ctx: *LinkContext) !void {
    for (elf.phdrs) |phdr| {
        if (phdr.p_type == std.elf.PT_DYNAMIC) {
            _ = try std.io.getStdOut().write("Handling dyn header\n");
            const dyn_section_ptr: [*]std.elf.Elf64_Dyn = @alignCast(@ptrCast(elf.base + phdr.p_vaddr));
            const dyn_section_len = phdr.p_memsz;
            const dyn_section = dyn_section_ptr[0..(dyn_section_len / @sizeOf(std.elf.Elf64_Dyn))];

            // First loop, populate single-occurance informations
            var dyn_strtab: [*]u8 = undefined;
            for (dyn_section) |dyn| {
                switch (dyn.d_tag) {
                    std.elf.DT_STRTAB => {
                        dyn_strtab = @alignCast(@ptrCast(elf.base + dyn.d_val));
                    },
                    else => continue,
                }
            }

            for (dyn_section) |dyn| {
                switch (dyn.d_tag) {
                    std.elf.DT_NULL => {
                        continue;
                    },
                    std.elf.DT_NEEDED => {
                        _ = try std.io.getStdOut().write("Loading library: ");
                        const lib_name: [*:0]u8 = @ptrCast(dyn_strtab + dyn.d_val);
                        _ = try std.io.getStdOut().write(std.mem.sliceTo(lib_name, 0));
                        _ = try std.io.getStdOut().write("\n");
                        const lib = try load.elf_load(lib_name, page_size, SEARCH.ptr);
                        // TODO: populate symbol table
                        try elf_link(lib, page_size, ctx);
                    },
                    else => {
                        _ = try std.io.getStdOut().write("Unimp d_tag: ");
                        try util.printNumHex(@bitCast(dyn.d_tag));
                        _ = try std.io.getStdOut().write("\n");
                    },
                }
            }
        }
    }
}
