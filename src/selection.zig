//! Combine scanner output with analyzer output and the user's keep filters
//! into a flat list of project selections ready for printing or deletion.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");

const NS_PER_S: i128 = 1_000_000_000;
const SECS_PER_DAY: i128 = 86_400;

pub const Item = struct {
    project: scanner.Project,
    analysis: analyzer.Analysis,
};

pub const Selection = struct {
    item: Item,
    /// Set by `selectAll` based on the keep filters and the user's
    /// `--ignore` paths. `true` means the entry should be skipped.
    keep: bool,
    /// Set by the user (interactive mode) or defaults to `!keep`. After
    /// `selectAll` the field reflects the default-derived intent; an
    /// interactive prompt can flip it.
    selected: bool,
};

/// Pair every project with its analysis and decide whether the keep filters
/// apply. Sort the result by ascending total_size so the largest cleanups
/// land at the bottom of the print-out.
pub fn selectAll(
    io: Io,
    arena: Allocator,
    opts: cli.Cli,
    items: []const Item,
) ![]Selection {
    const now_ns: i128 = Io.Timestamp.now(io, .real).nanoseconds;
    const keep_threshold_ns: i128 = @as(i128, opts.keep_days) * SECS_PER_DAY * NS_PER_S;

    var out: std.ArrayList(Selection) = .empty;
    for (items) |item| {
        const ignored = scanner.pathIsUnderAny(item.project.path, opts.ignore_paths);
        const over_size = item.analysis.total_size_bytes > opts.keep_size_bytes;
        const over_age = if (keep_threshold_ns == 0)
            true
        else
            now_ns - item.analysis.last_modified_ns >= keep_threshold_ns;
        const has_artifacts = item.analysis.artifact_paths.len > 0;

        // A project is kept if any keep criterion trips: ignored, no
        // artifacts, too small, or recently compiled. Matches the
        // cargo-clean-all wiring.
        const keep = ignored or !has_artifacts or !over_size or !over_age;
        try out.append(arena, .{
            .item = item,
            .keep = keep,
            .selected = !keep,
        });
    }
    const sorted = try out.toOwnedSlice(arena);
    std.mem.sort(Selection, sorted, {}, lessThanSize);
    return sorted;
}

fn lessThanSize(_: void, a: Selection, b: Selection) bool {
    return a.item.analysis.total_size_bytes < b.item.analysis.total_size_bytes;
}

test "pathIsUnderAny detects nested and exact matches" {
    try std.testing.expect(scanner.pathIsUnderAny("/data/root", &.{"/data/root"}));
    try std.testing.expect(scanner.pathIsUnderAny("/data/root/sub", &.{"/data/root"}));
    try std.testing.expect(scanner.pathIsUnderAny("/data/root/sub/inner", &.{"/data/root"}));
    try std.testing.expect(!scanner.pathIsUnderAny("/data/other", &.{"/data/root"}));
    try std.testing.expect(!scanner.pathIsUnderAny("/data/rootx", &.{"/data/root"}));
}

test "selectAll defaults selected when no filters active" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const projects = [_]scanner.Project{
        .{ .path = "/p/a" },
        .{ .path = "/p/b" },
    };
    const analyses = [_]analyzer.Analysis{
        .{
            .artifact_paths = &.{"/p/a/.zig-cache"},
            .total_size_bytes = 100,
            .last_modified_ns = 1,
        },
        .{
            .artifact_paths = &.{},
            .total_size_bytes = 0,
            .last_modified_ns = 0,
        },
    };
    const items = [_]Item{
        .{ .project = projects[0], .analysis = analyses[0] },
        .{ .project = projects[1], .analysis = analyses[1] },
    };

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const opts: cli.Cli = .{};
    const out = try selectAll(io, arena, opts, &items);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expect(!out[0].keep);
    try std.testing.expect(out[1].keep);
}

test "selectAll respects keep_size" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const projects = [_]scanner.Project{.{ .path = "/p/a" }};
    const analyses = [_]analyzer.Analysis{
        .{
            .artifact_paths = &.{"/p/a/.zig-cache"},
            .total_size_bytes = 50,
            .last_modified_ns = 1,
        },
    };
    const items = [_]Item{
        .{ .project = projects[0], .analysis = analyses[0] },
    };

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const opts: cli.Cli = .{ .keep_size_bytes = 100 };
    const out = try selectAll(io, arena, opts, &items);
    try std.testing.expect(out[0].keep);
    try std.testing.expect(!out[0].selected);
}

test "selectAll respects ignore paths" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const projects = [_]scanner.Project{.{ .path = "/p/special/a" }};
    const analyses = [_]analyzer.Analysis{
        .{
            .artifact_paths = &.{"/p/special/a/.zig-cache"},
            .total_size_bytes = 1024,
            .last_modified_ns = 1,
        },
    };
    const items = [_]Item{
        .{ .project = projects[0], .analysis = analyses[0] },
    };

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const opts: cli.Cli = .{ .ignore_paths = &.{"/p/special"} };
    const out = try selectAll(io, arena, opts, &items);
    try std.testing.expect(out[0].keep);
    try std.testing.expect(!out[0].selected);
}

test "selectAll sorts results by ascending size" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const projects = [_]scanner.Project{
        .{ .path = "/p/big" },
        .{ .path = "/p/small" },
        .{ .path = "/p/mid" },
    };
    const analyses = [_]analyzer.Analysis{
        .{ .artifact_paths = &.{"/p/big"}, .total_size_bytes = 9000, .last_modified_ns = 1 },
        .{ .artifact_paths = &.{"/p/small"}, .total_size_bytes = 100, .last_modified_ns = 1 },
        .{ .artifact_paths = &.{"/p/mid"}, .total_size_bytes = 3000, .last_modified_ns = 1 },
    };
    const items = [_]Item{
        .{ .project = projects[0], .analysis = analyses[0] },
        .{ .project = projects[1], .analysis = analyses[1] },
        .{ .project = projects[2], .analysis = analyses[2] },
    };

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const opts: cli.Cli = .{};
    const out = try selectAll(io, arena, opts, &items);
    try std.testing.expectEqualStrings("/p/small", out[0].item.project.path);
    try std.testing.expectEqualStrings("/p/mid", out[1].item.project.path);
    try std.testing.expectEqualStrings("/p/big", out[2].item.project.path);
}
