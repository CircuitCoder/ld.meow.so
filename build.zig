const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "ld.meow.so",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.pie = true;
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const dump_cmd = b.addSystemCommand(&[_][]const u8{ "objdump", "-S", b.getInstallPath(.bin, exe.out_filename) });
    dump_cmd.step.dependOn(b.getInstallStep());
    const dump_step = b.step("dump", "Dump assembly");
    dump_step.dependOn(&dump_cmd.step);
}
