const std = @import("std");
const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");
const selection = @import("selection.zig");

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
    var c = parsed[0];

    switch (parsed[1]) {
        .help => return printOut(io, "{s}", .{cli.usage}),
        .version => return printOut(io, "zig-clean-all {s}\n", .{version}),
        .neither => {},
    }

    const arena = init.arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, arena);
    const skip_abs = try scanner.resolveSkipPaths(io, cwd_path, c.skip_paths, arena);
    const ignore_abs = try scanner.resolveSkipPaths(io, cwd_path, c.ignore_paths, arena);
    c.ignore_paths = ignore_abs;

    const root_dir = try cwd.openDir(io, c.root_dir, .{ .iterate = true });
    defer root_dir.close(io);
    const root_base = try arena.dupe(u8, c.root_dir);

    var project_list: std.ArrayList(scanner.Project) = .empty;
    try scanner.findProjects(
        io,
        root_dir,
        root_base,
        skip_abs,
        arena,
        &project_list,
    );
    if (project_list.items.len == 0) {
        try printOut(io, "No Zig projects found under {s}\n", .{c.root_dir});
        return;
    }

    var analyses: std.ArrayList(analyzer.Analysis) = .empty;
    for (project_list.items) |p| {
        const pdir = cwd.openDir(io, p.path, .{ .iterate = true }) catch |err| {
            try printErr(io, "could not open {s}: {t}\n", .{ p.path, err });
            continue;
        };
        defer pdir.close(io);
        const a = try analyzer.analyze(io, pdir, p.path, arena);
        try analyses.append(arena, a);
    }

    // Trim `project_list` to entries that produced an analysis.
    if (analyses.items.len != project_list.items.len) {
        var trimmed: std.ArrayList(scanner.Project) = .empty;
        for (project_list.items[0..analyses.items.len]) |p| try trimmed.append(arena, p);
        project_list = trimmed;
    }

    const selections = try selection.selectAll(io, arena, c, project_list.items, analyses.items);

    var will_free: u64 = 0;
    var kept_size: u64 = 0;
    for (selections) |s| {
        if (s.selected) {
            will_free += s.analysis.total_size_bytes;
            try printOut(io, "[clean ] {s} ({d} bytes)\n", .{ s.project.path, s.analysis.total_size_bytes });
        } else {
            kept_size += s.analysis.total_size_bytes;
            try printOut(io, "[keep  ] {s} ({d} bytes)\n", .{ s.project.path, s.analysis.total_size_bytes });
        }
    }
    try printOut(io, "\nselected={d} kept={d} will_free={d} kept_size={d}\n", .{
        countSelected(selections),
        selections.len - countSelected(selections),
        will_free,
        kept_size,
    });
}

fn countSelected(s: []const selection.Selection) usize {
    var n: usize = 0;
    for (s) |x| {
        if (x.selected) n += 1;
    }
    return n;
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
