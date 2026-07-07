const std = @import("std");
const cli = @import("cli.zig");

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

    try printOut(
        io,
        "root={s} yes={} keep_size={d} keep_days={d} dry_run={} ignore={d} skip={d}\n",
        .{
            c.root_dir,
            c.yes,
            c.keep_size_bytes,
            c.keep_days,
            c.dry_run,
            c.ignore_paths.len,
            c.skip_paths.len,
        },
    );
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
