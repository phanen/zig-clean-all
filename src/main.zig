const std = @import("std");
const path = std.fs.path;
const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const selection = @import("selection.zig");
const format = @import("format.zig");
const cleaner = @import("cleaner.zig");
const interactive_mod = @import("interactive.zig");
const path_util = @import("path_util.zig");

const version = "0.1.0";

const ANSI_GREEN: []const u8 = "\x1b[32m";
const ANSI_RESET: []const u8 = "\x1b[0m";

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

    const cwd_path = try std.process.currentPathAlloc(io, arena);

    opts.ignore_paths = try path_util.resolvePaths(cwd_path, opts.ignore_paths, arena);
    const skip_abs = try path_util.resolvePaths(cwd_path, opts.skip_paths, arena);

    // Resolved once so every worker sees the same absolute path.
    const root_path = try path.resolve(arena, &.{ cwd_path, opts.root_dir });

    // `getCpuCount` returns usize; clamp to u32 so the same field can carry
    // both the default and the user-supplied value.
    const num_threads: u32 = if (opts.threads == 0)
        std.math.cast(u32, std.Thread.getCpuCount() catch 1) orelse std.math.maxInt(u32)
    else
        opts.threads;

    // Threaded defaults async_limit to nproc-1. Workers that exceed it run
    // eagerly on the caller thread, which deadlocks when a worker parks in
    // `getOne` before the seed job is enqueued. Lift past num_threads to
    // cover the main thread and any unrelated async work.
    configureThreadedAsyncLimit(io, num_threads + 1);

    const analyzed = try scanner.findProjectsAndAnalyze(io, root_path, skip_abs, arena, num_threads);
    if (analyzed.items.len == 0) {
        try printOut(io, "No Zig projects found under {s}\n", .{opts.root_dir});
        return;
    }

    const selections = try selection.selectAll(io, arena, opts, analyzed.items);

    var bytes_selected: u64 = 0;
    var bytes_kept: u64 = 0;
    var count_selected: usize = 0;
    for (selections) |s| {
        if (s.selected) {
            bytes_selected += s.item.analysis.total_size_bytes;
            count_selected += 1;
        } else {
            bytes_kept += s.item.analysis.total_size_bytes;
        }
    }
    if (opts.show_summary) {
        var freed_buf: [128]u8 = undefined;
        var kept_buf: [128]u8 = undefined;
        try printOut(
            io,
            "Selected {d}/{d} projects, cleaning will free: {s}. Keeping: {s}.\n",
            .{
                count_selected,
                selections.len,
                freed_buf[0..format.formatBytes(&freed_buf, bytes_selected)],
                kept_buf[0..format.formatBytes(&kept_buf, bytes_kept)],
            },
        );
    }

    // Non-interactive mode skips the TUI listing, so echo the selection
    // here so the user can sanity-check before answering y/N.
    if (count_selected > 0 and !opts.interactive) {
        try printSelectionList(io, selections);
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

/// Decide whether the user wants to proceed. Honors `--yes`, drives the
/// interactive TUI when `--interactive` is set, and falls back to y/N.
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

/// Read a single byte from stdin and return true if it is `y` or `Y`.
/// Anything else, including EOF, returns false.
fn confirmPrompt(io: std.Io) !bool {
    try printOut(io, "Clean the project directories shown above? [y/n] ", .{});
    var buf: [16]u8 = undefined;
    var stdin = std.Io.File.stdin();
    var reader = stdin.reader(io, &buf);
    const n = reader.interface.readSliceShort(&buf) catch return false;
    if (n == 0) return false;
    return buf[0] == 'y' or buf[0] == 'Y';
}

/// Echo the selected projects so the user can sanity-check before the
/// confirmation prompt. Buffer through one writer so a long list doesn't
/// trigger a flush per entry.
fn printSelectionList(
    io: std.Io,
    selections: []const selection.Selection,
) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    try w.interface.writeAll("Selected the following project directories for cleaning:\n");
    for (selections) |s| {
        if (!s.selected) continue;
        var size_buf: [32]u8 = undefined;
        var date_buf: [32]u8 = undefined;
        const size_str = size_buf[0..format.formatBytes(&size_buf, s.item.analysis.total_size_bytes)];
        const date_str = date_buf[0..format.formatTimestamp(&date_buf, s.item.analysis.last_modified_ns)];
        const basename = std.fs.path.basename(s.item.project.path);
        const display_name = if (basename.len == 0) s.item.project.path else basename;
        try w.interface.print(ANSI_GREEN ++ "{s}" ++ ANSI_RESET ++ ": {s} ({s}), {s}\n", .{
            display_name,
            size_str,
            date_str,
            s.item.project.path,
        });
    }
    try w.interface.writeAll("\n");
    try w.interface.flush();
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

fn configureThreadedAsyncLimit(io: std.Io, limit: u32) void {
    const threaded: *std.Io.Threaded = @ptrCast(@alignCast(io.userdata));
    threaded.setAsyncLimit(.limited(limit));
}
