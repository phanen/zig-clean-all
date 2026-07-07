//! Combine scanner output with analyzer output and the user's keep filters
//! into a flat list of project selections ready for printing or deletion.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const path = std.fs.path;

const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const analyzer = @import("analyzer.zig");

pub const Selection = struct {
    project: scanner.Project,
    analysis: analyzer.Analysis,
    /// Set by `selectAll` based on the keep filters and the user's
    /// --ignore paths. `true` means the entry should be skipped.
    keep: bool,
    /// Set by the user (interactive mode) or defaults to `!keep`. After
    /// `selectAll` the field reflects the default-derived intent; an
    /// interactive prompt can flip it.
    selected: bool,
};

/// Pair every project with its analysis and decide whether the keep
/// filters apply. Sort the result by ascending total_size so the largest
/// cleanups land at the bottom of the print-out.
pub fn selectAll(
    io: Io,
    arena: Allocator,
    c: cli.Cli,
    projects: []scanner.Project,
    analyses: []analyzer.Analysis,
) ![]Selection {
    const now_ns: i128 = Io.Timestamp.now(io, .real).nanoseconds;
    const keep_threshold_ns: i128 = @as(i128, c.keep_days) * 24 * 60 * 60 * 1_000_000_000;

    var out: std.ArrayList(Selection) = .empty;
    for (projects, analyses) |proj, anal| {
        const ignored = pathIsUnderAny(proj.path, c.ignore_paths);
        const over_size = anal.total_size_bytes > c.keep_size_bytes;
        const over_age = if (keep_threshold_ns == 0)
            true
        else
            now_ns - anal.last_modified_ns >= keep_threshold_ns;
        const has_artifacts = anal.artifact_paths.len > 0;
        // Keep the project if any keep criterion trips: ignored, no artifacts,
        // too small, or recently compiled. Matches cargo-clean-all's wiring.
        const keep = ignored or !has_artifacts or !over_size or !over_age;
        try out.append(arena, .{
            .project = proj,
            .analysis = anal,
            .keep = keep,
            .selected = !keep,
        });
    }
    const items = try out.toOwnedSlice(arena);
    std.mem.sort(Selection, items, {}, lessThanSize);
    return items;
}

fn lessThanSize(_: void, a: Selection, b: Selection) bool {
    return a.analysis.total_size_bytes < b.analysis.total_size_bytes;
}

fn pathIsUnderAny(p: []const u8, roots: []const []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, p, root)) return true;
        if (p.len > root.len and
            std.mem.eql(u8, p[0..root.len], root) and
            p[root.len] == path.sep) return true;
    }
    return false;
}

test "pathIsUnderAny detects nested and exact matches" {
    try std.testing.expect(pathIsUnderAny("/data/root", &.{"/data/root"}));
    try std.testing.expect(pathIsUnderAny("/data/root/sub", &.{"/data/root"}));
    try std.testing.expect(pathIsUnderAny("/data/root/sub/inner", &.{"/data/root"}));
    try std.testing.expect(!pathIsUnderAny("/data/other", &.{"/data/root"}));
    try std.testing.expect(!pathIsUnderAny("/data/rootx", &.{"/data/root"}));
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

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const c: cli.Cli = .{};
    const out = try selectAll(io, arena, c, &projects, &analyses);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expect(!out[0].keep); // a has artifacts, selected by default
    try std.testing.expect(out[1].keep); // b has no artifacts, kept
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

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const c: cli.Cli = .{ .keep_size_bytes = 100 };
    const out = try selectAll(io, arena, c, &projects, &analyses);
    try std.testing.expect(out[0].keep); // smaller than threshold, kept
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

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const c: cli.Cli = .{ .ignore_paths = &.{"/p/special"} };
    const out = try selectAll(io, arena, c, &projects, &analyses);
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

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const c: cli.Cli = .{};
    const out = try selectAll(io, arena, c, &projects, &analyses);
    try std.testing.expectEqualStrings("/p/small", out[0].project.path);
    try std.testing.expectEqualStrings("/p/mid", out[1].project.path);
    try std.testing.expectEqualStrings("/p/big", out[2].project.path);
}
