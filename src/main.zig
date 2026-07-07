const std = @import("std");
const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");
const selection = @import("selection.zig");
const format = @import("format.zig");

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
    if (analyses.items.len != project_list.items.len) {
        var trimmed: std.ArrayList(scanner.Project) = .empty;
        for (project_list.items[0..analyses.items.len]) |p| try trimmed.append(arena, p);
        project_list = trimmed;
    }

    const selections = try selection.selectAll(io, arena, c, project_list.items, analyses.items);

    const now_ns: i128 = std.Io.Timestamp.now(io, .real).nanoseconds;
    try printSelections(io, selections, now_ns);

    const will_free: u64 = totalSelected(selections);
    const kept_size: u64 = totalKept(selections);
    if (c.show_summary) {
        var buf: [128]u8 = undefined;
        const freed_str = buf[0..format.formatBytes(&buf, will_free)];
        var buf2: [128]u8 = undefined;
        const kept_str = buf2[0..format.formatBytes(&buf2, kept_size)];
        try printOut(
            io,
            "\nselected {d}/{d} projects; would free {s}; keeping {s}\n",
            .{ countSelected(selections), selections.len, freed_str, kept_str },
        );
    }

    if (c.dry_run) {
        try printOut(io, "dry-run: not deleting anything\n", .{});
        return;
    }
    if (countSelected(selections) == 0) {
        try printOut(io, "Nothing selected to clean.\n", .{});
        return;
    }
}

fn printSelections(io: std.Io, sel: []const selection.Selection, now_ns: i128) !void {
    var buf_a: [64]u8 = undefined;
    var buf_b: [64]u8 = undefined;
    for (sel) |s| {
        const size_str = buf_a[0..format.formatBytes(&buf_a, s.analysis.total_size_bytes)];
        if (s.selected) {
            try printOut(io, "[CLEAN] {s}  {s}\n", .{ s.project.path, size_str });
        } else {
            const reason = keepReason(s, now_ns, &buf_b);
            try printOut(io, "[KEEP ] {s}  {s}  ({s})\n", .{ s.project.path, size_str, reason });
        }
    }
}

fn keepReason(s: selection.Selection, now_ns: i128, buf: []u8) []const u8 {
    if (s.analysis.artifact_paths.len == 0) {
        const written = std.fmt.bufPrint(buf, "no artifacts", .{}) catch return "";
        return written;
    }
    var local: [64]u8 = undefined;
    const age_ns: i128 = if (now_ns > s.analysis.last_modified_ns)
        now_ns - s.analysis.last_modified_ns
    else
        0;
    const age = local[0..format.formatAge(&local, age_ns)];
    const written = std.fmt.bufPrint(buf, "last build {s} ago", .{age}) catch return "";
    return written;
}

fn countSelected(s: []const selection.Selection) usize {
    var n: usize = 0;
    for (s) |x| {
        if (x.selected) n += 1;
    }
    return n;
}

fn totalSelected(s: []const selection.Selection) u64 {
    var total: u64 = 0;
    for (s) |x| {
        if (x.selected) total += x.analysis.total_size_bytes;
    }
    return total;
}

fn totalKept(s: []const selection.Selection) u64 {
    var total: u64 = 0;
    for (s) |x| {
        if (!x.selected) total += x.analysis.total_size_bytes;
    }
    return total;
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
