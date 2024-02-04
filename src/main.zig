const std = @import("std");

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

fn printNum(n: usize) !void {
    if (n == 0) {
        _ = try std.io.getStdOut().write("0");
        return;
    }

    var divider: usize = 10;
    while (n > divider) {
        divider *= 10;
    }
    divider /= 10;

    var tmp = n;
    while (tmp > 0) {
        const digit: u8 = @intCast((tmp / divider) % 10);
        _ = try std.io.getStdOut().write(&[_]u8{'0' + digit});
        tmp = tmp % divider;
        divider /= 10;
    }
}

fn printNumHex(n: usize) !void {
    _ = try std.io.getStdOut().write("0x");
    for (0..16) |i| {
        const digit: u8 = @intCast((n >> @intCast(60 - i * 4)) & 0xF);
        if (digit < 10) {
            _ = try std.io.getStdOut().write(&[_]u8{'0' + digit});
        } else {
            _ = try std.io.getStdOut().write(&[_]u8{'A' - 10 + digit});
        }
    }
}

pub fn _dlstart(arg_page: [*]usize, dyns: [*]std.elf.Dyn) callconv(.C) noreturn {
    _dlstart_impl(arg_page, dyns) catch exit(1);
}

const AUX_WE_CARE = [_]usize{
    std.elf.AT_ENTRY,
    std.elf.AT_PHDR,
    std.elf.AT_EXECFN,
};

const AUX_BUF_SIZE: usize = std.mem.max(usize, &AUX_WE_CARE) + 1;

pub fn _dlstart_impl(arg_page: [*]usize, dyns: [*]std.elf.Dyn) !noreturn {
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
        _ = try std.io.getStdOut().write("[E] ");
        _ = try std.io.getStdOut().write(std.mem.sliceTo(envp[envidx].?, 0));
        _ = try std.io.getStdOut().write("\n");
    }

    const auxp: [*]usize = @ptrCast(envp + envidx + 1);
    var auxidx: usize = 0;
    var auxbuf: [AUX_BUF_SIZE]usize = .{};
    while (auxp[auxidx] != 0) : (auxidx += 2) {
        _ = try std.io.getStdOut().write("[A] ");
        try printNum(auxp[auxidx]);
        _ = try std.io.getStdOut().write(" = ");
        try printNumHex(auxp[auxidx + 1]);
        _ = try std.io.getStdOut().write("\n");

        if (auxp[auxidx] < AUX_BUF_SIZE) auxbuf[auxp[auxidx]] = auxp[auxidx + 1];
    }

    _ = try std.io.getStdOut().write("Program: ");
    _ = try std.io.getStdOut().write(std.mem.sliceTo(@as([*:0]u8, @ptrFromInt(auxbuf[std.elf.AT_EXECFN])), 0));
    _ = try std.io.getStdOut().write("\n");

    var idx: usize = 0;
    while (dyns[idx].d_tag == std.elf.DT_NULL) : (idx += 1) {
        try printNum(@bitCast(dyns[idx].d_tag));
        _ = try std.io.getStdOut().write(" ");
        try printNumHex(@bitCast(dyns[idx].d_val));
        _ = try std.io.getStdOut().write("\n");
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
