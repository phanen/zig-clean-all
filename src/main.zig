const std = @import("std");
const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");
const selection = @import("selection.zig");
const format = @import("format.zig");
const cleaner = @import("cleaner.zig");
const interactive_mod = @import("interactive.zig");

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const user_args = if (args.len > 1) args[1..] else &.{};

    var opts, const status = cli.parse(arena, user_args) catch |err| switch (err) {
        error.InvalidArgument, error.UnknownFlag, error.MissingValue => {
            try printErr(io, "error: invalid arguments\n{s}", .{cli.usage});
            std.process.exit(2);
        },
        else => return err,
    };

    switch (status) {
        .help => return printOut(io, "{s}", .{cli.usage}),
        .version => return printOut(io, "zig-clean-all {s}\n", .{version}),
        .neither => {},
    }

    const cwd = std.Io.Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, arena);

    opts.ignore_paths = try scanner.resolveSkipPaths(cwd_path, opts.ignore_paths, arena);
    const skip_abs = try scanner.resolveSkipPaths(cwd_path, opts.skip_paths, arena);

    const root_dir = try cwd.openDir(io, opts.root_dir, .{ .iterate = true });
    defer root_dir.close(io);
    const root_base = try arena.dupe(u8, opts.root_dir);

    var found: std.ArrayList(scanner.Project) = .empty;
    try scanner.findProjects(io, root_dir, root_base, skip_abs, arena, &found);
    if (found.items.len == 0) {
        try printOut(io, "No Zig projects found under {s}\n", .{opts.root_dir});
        return;
    }

    var items: std.ArrayList(selection.Item) = .empty;
    for (found.items) |p| {
        const pdir = cwd.openDir(io, p.path, .{ .iterate = true }) catch |err| {
            try printErr(io, "could not open {s}: {t}\n", .{ p.path, err });
            continue;
        };
        defer pdir.close(io);
        const a = analyzer.analyze(io, pdir, p.path, arena) catch |err| {
            try printErr(io, "could not analyze {s}: {t}\n", .{ p.path, err });
            continue;
        };
        try items.append(arena, .{ .project = p, .analysis = a });
    }

    const selections = try selection.selectAll(io, arena, opts, items.items);

    const bytes_selected: u64 = totalSelectedBytes(selections);
    const bytes_kept: u64 = totalKeptBytes(selections);
    const count_selected = countSelected(selections);
    if (opts.show_summary) {
        var freed_buf: [128]u8 = undefined;
        var kept_buf: [128]u8 = undefined;
        try printOut(
            io,
            "selected {d}/{d} projects; would free {s}; keeping {s}\n",
            .{
                count_selected,
                selections.len,
                freed_buf[0..format.formatBytes(&freed_buf, bytes_selected)],
                kept_buf[0..format.formatBytes(&kept_buf, bytes_kept)],
            },
        );
    }

    if (opts.dry_run) {
        try printOut(io, "dry-run: not deleting anything\n", .{});
        return;
    }
    if (count_selected == 0) {
        try printOut(io, "Nothing selected to clean.\n", .{});
        return;
    }

    const proceed = try decideProceed(io, opts, selections, init);
    if (!proceed) {
        try printOut(io, "Cleanup cancelled.\n", .{});
        return;
    }

    var selected_paths: std.ArrayList([]const u8) = .empty;
    for (selections) |s| {
        if (s.selected) try selected_paths.append(arena, s.item.project.path);
    }
    const cleanup = try cleaner.cleanAll(io, arena, selected_paths.items, opts.keep_empty);

    var cleaned_buf: [128]u8 = undefined;
    const cleaned_str = cleaned_buf[0..format.formatBytes(&cleaned_buf, bytes_selected)];
    if (cleanup.failed.len == 0) {
        try printOut(
            io,
            "\nCleanup complete. Reclaimed {s} ({d} artifacts removed).\n",
            .{ cleaned_str, cleanup.removed + cleanup.emptied },
        );
    } else {
        try printErr(
            io,
            "\nCleanup finished with {d} failures. Reclaimed {s}.\n",
            .{ cleanup.failed.len, cleaned_str },
        );
        for (cleanup.failed) |f| {
            try printErr(io, "  - {s}/{s}: {t}\n", .{ f.project_path, f.artifact_name, f.err });
        }
    }
}

/// Returns true if the user wants to proceed with cleanup. Honors `--yes`,
/// drives the interactive TUI when `--interactive` is set, and falls back to
/// a y/N prompt otherwise.
fn decideProceed(
    io: std.Io,
    opts: cli.Cli,
    selections: []selection.Selection,
    init: std.process.Init,
) !bool {
    if (opts.interactive) {
        const outcome = interactive_mod.run(io, init.environ_map, selections, init.gpa) catch {
            try printErr(io, "--interactive failed; falling back to y/N\n", .{});
            return confirmPrompt(io);
        };
        return outcome == .confirm;
    }
    if (opts.yes) return true;
    return confirmPrompt(io);
}

/// Read a single line from stdin and return true if it starts with 'y' or
/// 'Y'. Anything else (including EOF) returns false.
fn confirmPrompt(io: std.Io) !bool {
    try printOut(io, "Proceed with cleanup? [y/N] ", .{});
    var buf: [16]u8 = undefined;
    var stdin = std.Io.File.stdin();
    var reader = stdin.reader(io, &buf);
    const n = reader.interface.readSliceShort(&buf) catch return false;
    if (n == 0) return false;
    return buf[0] == 'y' or buf[0] == 'Y';
}

fn countSelected(s: []const selection.Selection) usize {
    var n: usize = 0;
    for (s) |x| {
        if (x.selected) n += 1;
    }
    return n;
}

fn totalSelectedBytes(s: []const selection.Selection) u64 {
    var total: u64 = 0;
    for (s) |x| {
        if (x.selected) total += x.item.analysis.total_size_bytes;
    }
    return total;
}

fn totalKeptBytes(s: []const selection.Selection) u64 {
    var total: u64 = 0;
    for (s) |x| {
        if (!x.selected) total += x.item.analysis.total_size_bytes;
    }
    return total;
}

const Stream = enum { stdout, stderr };

fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    return writeStream(io, .stdout, fmt, args);
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    return writeStream(io, .stderr, fmt, args);
}

fn writeStream(io: std.Io, stream: Stream, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const file = switch (stream) {
        .stdout => std.Io.File.stdout(),
        .stderr => std.Io.File.stderr(),
    };
    var w = file.writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
