//! Combine scanner output with the user's keep filters into a flat list of
//! project selections ready for printing or deletion.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const scanner = @import("scanner.zig");
const path_util = @import("path_util.zig");

const NS_PER_S: i128 = 1_000_000_000;
const SECS_PER_DAY: i128 = 86_400;

/// Input to `selectAll`: a project paired with its measurement. Aliased
/// to `scanner.AnalyzedProject` because the scanner already fuses both
/// pieces and the selection phase just consumes them.
pub const Item = scanner.AnalyzedProject;

pub const Selection = struct {
    item: Item,
    /// `true` means the entry should be skipped: matches a keep filter or
    /// an `--ignore` root. Set by `selectAll`.
    keep: bool,
    /// User intent after the interactive prompt, or `!keep` by default.
    /// Flipped by the TUI when the user toggles a row.
    selected: bool,
};

/// Apply the keep filters to every project and sort the survivors by
/// ascending total_size so the largest cleanups land at the bottom.
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
        const ignored = path_util.pathIsUnderAny(item.project.path, opts.ignore_paths);
        const over_size = item.analysis.total_size_bytes > opts.keep_size_bytes;
        const over_age = if (keep_threshold_ns == 0)
            true
        else
            now_ns - item.analysis.last_modified_ns >= keep_threshold_ns;
        const has_artifacts = item.analysis.artifact_paths.len > 0;

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

test "selectAll defaults selected when no filters active" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);

    const items = [_]Item{
        .{
            .project = .{ .path = "/p/a" },
            .analysis = .{
                .artifact_paths = &.{"/p/a/.zig-cache"},
                .total_size_bytes = 100,
                .last_modified_ns = 1,
            },
        },
        .{
            .project = .{ .path = "/p/b" },
            .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 },
        },
    };

    const out = try selectAll(env.io(), arena_alloc.allocator(), .{}, &items);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expect(out[0].keep);
    try std.testing.expect(!out[1].keep);
}

test "selectAll respects keep_size" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);

    const items = [_]Item{
        .{
            .project = .{ .path = "/p/a" },
            .analysis = .{
                .artifact_paths = &.{"/p/a/.zig-cache"},
                .total_size_bytes = 50,
                .last_modified_ns = 1,
            },
        },
    };

    const out = try selectAll(env.io(), arena_alloc.allocator(), .{ .keep_size_bytes = 100 }, &items);
    try std.testing.expect(out[0].keep);
    try std.testing.expect(!out[0].selected);
}

test "selectAll respects ignore paths" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);

    const items = [_]Item{
        .{
            .project = .{ .path = "/p/special/a" },
            .analysis = .{
                .artifact_paths = &.{"/p/special/a/.zig-cache"},
                .total_size_bytes = 1024,
                .last_modified_ns = 1,
            },
        },
    };

    const out = try selectAll(env.io(), arena_alloc.allocator(), .{ .ignore_paths = &.{"/p/special"} }, &items);
    try std.testing.expect(out[0].keep);
    try std.testing.expect(!out[0].selected);
}

test "selectAll sorts results by ascending size" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);

    const items = [_]Item{
        .{ .project = .{ .path = "/p/big" }, .analysis = .{ .artifact_paths = &.{"/p/big"}, .total_size_bytes = 9000, .last_modified_ns = 1 } },
        .{ .project = .{ .path = "/p/small" }, .analysis = .{ .artifact_paths = &.{"/p/small"}, .total_size_bytes = 100, .last_modified_ns = 1 } },
        .{ .project = .{ .path = "/p/mid" }, .analysis = .{ .artifact_paths = &.{"/p/mid"}, .total_size_bytes = 3000, .last_modified_ns = 1 } },
    };

    const out = try selectAll(env.io(), arena_alloc.allocator(), .{}, &items);
    try std.testing.expectEqualStrings("/p/small", out[0].item.project.path);
    try std.testing.expectEqualStrings("/p/mid", out[1].item.project.path);
    try std.testing.expectEqualStrings("/p/big", out[2].item.project.path);
}
