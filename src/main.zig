const std = @import("std");
const load = @import("./load.zig");
const link = @import("./link.zig");
const util = @import("./util.zig");

extern const __ehdr_start: std.elf.Elf64_Ehdr;

pub fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ xorq %%rbp, %%rbp
        \\ movq %%rsp, %%rdi
        \\ leaq _DYNAMIC(%%rip), %%rsi
        \\ andq $-16, %%rsp
        \\ callq %[_dlstart:P]
        :
        : [_dlstart] "X" (_dlstart),
    );
}

pub fn _dlstart(arg_page: [*]usize, dyns: [*]std.elf.Dyn) callconv(.C) noreturn {
    // TODO: error messages
    _dlstart_impl(arg_page, dyns) catch exit(1);
}

const AUX_WE_CARE = [_]usize{
    std.elf.AT_ENTRY,
    std.elf.AT_BASE,
    std.elf.AT_PHENT,
    std.elf.AT_PHNUM,
    std.elf.AT_PHDR,
    std.elf.AT_EXECFN,
    std.elf.AT_PAGESZ,
    std.elf.AT_SYSINFO_EHDR,
};

const AUX_BUF_SIZE: usize = std.mem.max(usize, &AUX_WE_CARE) + 1;

pub fn _dlstart_impl(arg_page: [*]usize, dyns: [*]std.elf.Dyn) !noreturn {
    // Self relocation

    const argc = arg_page[0];
    const argv: [*][*:0]u8 = @ptrCast(arg_page + 1);
    const argv0 = std.mem.sliceTo(argv[0], 0);
    _ = try std.io.getStdOut().write("As: ");
    _ = try std.io.getStdOut().write(argv0);
    _ = try std.io.getStdOut().write("\n");

    // Iterate through env ptr
    const envp: [*](?[*:0]u8) = @ptrCast(arg_page + 2 + argc);
    var envidx: usize = 0;
    while (envp[envidx] != null) : (envidx += 1) {}

    const auxp: [*]usize = @ptrCast(envp + envidx + 1);
    var auxidx: usize = 0;
    var auxmap = std.mem.zeroes([AUX_BUF_SIZE]usize);
    while (auxp[auxidx] != 0) : (auxidx += 2) {
        if (auxp[auxidx] < AUX_BUF_SIZE) auxmap[auxp[auxidx]] = auxp[auxidx + 1];
    }

    _ = try std.io.getStdOut().write("Program: ");
    _ = try std.io.getStdOut().write(std.mem.sliceTo(@as([*:0]u8, @ptrFromInt(auxmap[std.elf.AT_EXECFN])), 0));
    _ = try std.io.getStdOut().write("\n");

    var trivial_link_ctx = link.LinkContext.trivial();

    var self_base = auxmap[std.elf.AT_BASE];
    if (self_base == 0) { // Directly invoked
        self_base = @intFromPtr(&__ehdr_start);
    }
    const self_phdr: [*]std.elf.Elf64_Phdr = @ptrFromInt(self_base + __ehdr_start.e_phoff);
    var self_dyn_len: usize = 0;
    while (dyns[self_dyn_len].d_tag != std.elf.DT_NULL) self_dyn_len += 1;
    const self_dyn = try load.elf_parse_dyn(dyns[0..(self_dyn_len + 1)], @ptrFromInt(self_base));
    try link.elf_reloc(self_dyn, @ptrFromInt(self_base), &trivial_link_ctx);
    _ = try std.io.getStdOut().write("Self relocation complete.\n");

    var alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    var link_ctx = link.LinkContext.root(alloc.allocator());

    // FIXME: append ld.so into link_ctx

    var page_size = auxmap[std.elf.AT_PAGESZ];
    if (page_size == 0) page_size = std.mem.page_size;

    // vDSO
    if (auxmap[std.elf.AT_SYSINFO_EHDR] != 0) {
        _ = try std.io.getStdOut().write("Found vDSO\n");
        const vdso = try load.elf_load_mapped(@ptrFromInt(auxmap[std.elf.AT_SYSINFO_EHDR]));
        try link.elf_link(
            vdso,
            page_size,
            &link_ctx,
        );
        const vdso_name = vdso.dyn.?.soname orelse "linux-vdso.so.??";
        try link_ctx.append(vdso_name, vdso);
    }

    const aux_phdr_ptr: [*]std.elf.Elf64_Phdr = @ptrFromInt(auxmap[std.elf.AT_PHDR]);
    const aux_phdr_num = auxmap[std.elf.AT_PHNUM];
    const aux_phdr = aux_phdr_ptr[0..aux_phdr_num];

    var app: load.LoadedElf = undefined;
    var modified_args = arg_page;

    if (self_phdr == aux_phdr_ptr) {
        _ = try std.io.getStdOut().write("Loading: ");
        _ = try std.io.getStdOut().write(std.mem.sliceTo(argv[1], 0));
        _ = try std.io.getStdOut().write("\n");
        app = try load.elf_load(argv[1], auxmap[std.elf.AT_PAGESZ], null);
        auxmap[std.elf.AT_ENTRY] = @intFromPtr(app.base) + @as(*std.elf.Elf64_Ehdr, @alignCast(@ptrCast(app.base))).*.e_entry;
        modified_args = arg_page + 1;
        modified_args[0] = arg_page[0] - 1;
    } else {
        var target_load: usize = undefined;
        for (aux_phdr) |phdr| {
            if (phdr.p_type == std.elf.PT_PHDR) {
                target_load = auxmap[std.elf.AT_PHDR] - phdr.p_vaddr;
                break;
            }
        }
        const base: [*]u8 = @ptrFromInt(target_load);
        app = load.LoadedElf{
            .base = base,
            .phdrs = aux_phdr,
            .dyn = try load.elf_find_dyn(aux_phdr, base),
        };
    }

    try link.elf_link(
        app,
        page_size,
        &link_ctx,
    );
    try link_ctx.append("", app);

    // Init, fini cannot be implemented without help from libc
    switch (link_ctx.state) {
        .trivial => unreachable,
        .loaded => |s| {
            for (s.topo.items) |name| {
                const elf = s.map.getPtr(name).?;
                if (elf.dyn == null) continue;
                if (elf.dyn.?.init) |i| {
                    i();
                }
                for (elf.dyn.?.inits) |i| {
                    _ = try std.io.getStdOut().write("Found init: ");
                    try util.printNumHex(@intFromPtr(i));
                    _ = try std.io.getStdOut().write("\n");
                    i();
                }
            }
        },
    }

    asm volatile (
        \\ movq %[args], %%rsp
        \\ jmpq *%[entry:P]
        :
        : [args] "X" (modified_args),
          [entry] "X" (auxmap[std.elf.AT_ENTRY]),
    );

    exit(255);
}

fn exit(code: usize) noreturn {
    asm volatile ("syscall"
        :
        : [_] "{rax}" (231),
          [_] "{rdi}" (code),
    );
    unreachable;
}

comptime {
    @export(_start, .{ .name = "_start" });
    @export(_dlstart, .{ .name = "_dlstart" });
}
