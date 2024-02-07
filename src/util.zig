const std = @import("std");

pub fn printNum(n: usize) !void {
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

pub fn printNumHex(n: usize) !void {
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
