const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("src/main.zig"),
        .imports = &.{
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
        },
    });

    const exe = b.addExecutable(.{
        .name = "zig-clean-all",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run zig-clean-all");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .root_source_file = b.path("src/main.zig"),
            .imports = &.{
                .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
            },
        }),
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}