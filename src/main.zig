const std = @import("std");
const cli = @import("cli.zig");
const scanner = @import("scanner.zig");

const version = "0.1.0";

const mem = std.mem;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const user_args = if (args.len > 1) args[1..] else &.{};

    const parsed = cli.parse(init.arena.allocator(), user_args) catch |err| switch (err) {
        error.InvalidArgument, error.UnknownFlag, error.MissingValue => {
            try printErr(io, "error: invalid arguments\n{s}", .{cli.usage});
            std.process.exit(2);
        },
        else => return err,
    };
    const c = parsed[0];

    switch (parsed[1]) {
        .help => return printOut(io, "{s}", .{cli.usage}),
        .version => return printOut(io, "zig-clean-all {s}\n", .{version}),
        .neither => {},
    }

    const cwd = std.Io.Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, init.arena.allocator());
    const skip_abs = try scanner.resolveSkipPaths(
        io,
        cwd_path,
        c.skip_paths,
        init.arena.allocator(),
    );

    const root_dir = try cwd.openDir(io, c.root_dir, .{ .iterate = true });
    defer root_dir.close(io);
    const root_base = try init.arena.allocator().dupe(u8, c.root_dir);

    var projects: std.ArrayList(scanner.Project) = .empty;
    try scanner.findProjects(
        io,
        root_dir,
        root_base,
        skip_abs,
        init.arena.allocator(),
        &projects,
    );

    try printOut(
        io,
        "root={s} projects={d}\n",
        .{ c.root_dir, projects.items.len },
    );
    for (projects.items) |p| {
        try printOut(io, "  project: {s}\n", .{p.path});
    }
}

fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
