const std = @import("std");
const load = @import("./load.zig");
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
};

const AUX_BUF_SIZE: usize = std.mem.max(usize, &AUX_WE_CARE) + 1;

pub fn _dlstart_impl(arg_page: [*]usize, dyns: [*]std.elf.Dyn) !noreturn {
    // TODO: self relocation

    const argc = arg_page[0];
    const argv: [*][*:0]u8 = @ptrCast(arg_page + 1);
    const argv0 = std.mem.sliceTo(argv[0], 0);
    _ = try std.io.getStdOut().write("As: ");
    _ = try std.io.getStdOut().write(argv0);
    _ = try std.io.getStdOut().write("\n");

    // Iterate through env ptr
    const envp: [*](?[*:0]u8) = @ptrCast(arg_page + 2 + argc);
    var envidx: usize = 0;
    while (envp[envidx] != null) : (envidx += 1) {
        // _ = try std.io.getStdOut().write("[E] ");
        // _ = try std.io.getStdOut().write(std.mem.sliceTo(envp[envidx].?, 0));
        // _ = try std.io.getStdOut().write("\n");
    }

    const auxp: [*]usize = @ptrCast(envp + envidx + 1);
    var auxidx: usize = 0;
    var auxmap: [AUX_BUF_SIZE]usize = .{};
    while (auxp[auxidx] != 0) : (auxidx += 2) {
        // _ = try std.io.getStdOut().write("[A] ");
        // try util.printNum(auxp[auxidx]);
        // _ = try std.io.getStdOut().write(" = ");
        // try util.printNumHex(auxp[auxidx + 1]);
        // _ = try std.io.getStdOut().write("\n");

        if (auxp[auxidx] < AUX_BUF_SIZE) auxmap[auxp[auxidx]] = auxp[auxidx + 1];
    }

    _ = try std.io.getStdOut().write("Program: ");
    _ = try std.io.getStdOut().write(std.mem.sliceTo(@as([*:0]u8, @ptrFromInt(auxmap[std.elf.AT_EXECFN])), 0));
    _ = try std.io.getStdOut().write("\n");

    _ = try std.io.getStdOut().write("Self dynamic symbols:\n");
    var idx: usize = 0;
    while (dyns[idx].d_tag == std.elf.DT_NULL) : (idx += 1) {
        try util.printNum(@bitCast(dyns[idx].d_tag));
        _ = try std.io.getStdOut().write(" ");
        try util.printNumHex(@bitCast(dyns[idx].d_val));
        _ = try std.io.getStdOut().write("\n");
    }

    // TODO: handle direct call, so PHDR == this phdr

    var page_size = auxmap[std.elf.AT_PAGESZ];
    if (page_size == 0) page_size = std.mem.page_size;

    const target_phdr_ptr: [*]std.elf.Elf64_Phdr = @ptrFromInt(auxmap[std.elf.AT_PHDR]);
    const target_phdr_num = auxmap[std.elf.AT_PHNUM];
    var target_phdr = target_phdr_ptr[0..target_phdr_num];

    var self_base = auxmap[std.elf.AT_BASE];
    if (self_base == 0) { // Directly invoked
        self_base = @intFromPtr(&__ehdr_start);
    }
    const self_phdr: [*]std.elf.Elf64_Phdr = @ptrFromInt(self_base + __ehdr_start.e_phoff);

    var target_load: usize = undefined;

    if (self_phdr == target_phdr_ptr) {
        _ = try std.io.getStdOut().write("Loading: ");
        _ = try std.io.getStdOut().write(std.mem.sliceTo(argv[1], 0));
        _ = try std.io.getStdOut().write("\n");
        const app = try load.elf_load(argv[1], auxmap[std.elf.AT_PAGESZ]);
        target_phdr = app.phdrs;
        target_load = @intFromPtr(app.base);
    } else {
        for (target_phdr) |phdr| {
            if (phdr.p_type == std.elf.PT_PHDR) {
                target_load = auxmap[std.elf.AT_PHDR] - phdr.p_vaddr;
                break;
            }
        }
    }

    // Second loop: look for PT_DYNAMIC and do dynamic linking
    for (target_phdr) |phdr| {
        if (phdr.p_type == std.elf.PT_DYNAMIC) {
            _ = try std.io.getStdOut().write("Handling dyn header\n");
            const dyn_section_ptr: [*]std.elf.Elf64_Dyn = @ptrFromInt(phdr.p_vaddr + target_load);
            const dyn_section_len = phdr.p_memsz;
            const dyn_section = dyn_section_ptr[0..(dyn_section_len / @sizeOf(std.elf.Elf64_Dyn))];

            // First loop, populate single-occurance informations
            var dyn_strtab: [*]u8 = undefined;
            for (dyn_section) |dyn| {
                switch (dyn.d_tag) {
                    std.elf.DT_STRTAB => {
                        dyn_strtab = @ptrFromInt(dyn.d_val + target_load);
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
                        _ = try load.elf_load(lib_name, page_size);
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

    exit(argc);
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
