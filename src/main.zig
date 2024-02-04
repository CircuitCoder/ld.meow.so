const std = @import("std");

pub fn _start() callconv(.Naked) noreturn {
    asm volatile (
        \\ xorq %%rbp, %%rbp
        \\ movq %%rsp, %%rdi
        \\ andq $-16, %%rsp
        \\ callq %[_dlstart:P]
        :
        : [_dlstart] "X" (_dlstart),
    );
}

pub fn _dlstart(arg_page: [*]usize) callconv(.C) noreturn {
    const argc = arg_page[0];
    const argv: [*][*:0]u8 = @ptrCast(arg_page + 1);
    const argv0 = std.mem.sliceTo(argv[0], 0);
    _ = std.io.getStdOut().write(argv0) catch exit(1);
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
