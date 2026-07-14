//! Path normalisation helpers for user-supplied paths.

const std = @import("std");
const assert = std.debug.assert;
const path = std.fs.path;
const Allocator = std.mem.Allocator;

pub fn resolvePaths(
    cwd_path: []const u8,
    raw_paths: []const []const u8,
    backing: Allocator,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (raw_paths) |raw| {
        try list.append(backing, try std.fs.path.resolve(backing, &.{ cwd_path, raw }));
    }
    return try list.toOwnedSlice(backing);
}

/// True when `p` equals or is nested inside one of `roots`. Both must be
/// non-empty and normalised (no trailing sep)
pub fn pathIsUnderAny(p: []const u8, roots: []const []const u8) bool {
    assert(p.len > 0);
    for (roots) |root| {
        assert(root.len > 0);
        assert(root[root.len - 1] != path.sep);
        if (p.len >= root.len and
            std.mem.eql(u8, p[0..root.len], root) and
            (p.len == root.len or p[root.len] == path.sep)) return true;
    }
    return false;
}

test "resolvePaths keeps absolute paths normalised" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const got = try resolvePaths("/test/cwd", &.{ "/abs/path", "/abs/trailing/" }, arena_alloc.allocator());
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/abs/path", got[0]);
    try std.testing.expectEqualStrings("/abs/trailing", got[1]);
}

test "resolvePaths joins relative paths with cwd" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const got = try resolvePaths("/test/cwd", &.{ "foo", "nested/bar" }, arena_alloc.allocator());
    try std.testing.expectEqualStrings("/test/cwd/foo", got[0]);
    try std.testing.expectEqualStrings("/test/cwd/nested/bar", got[1]);
}

test "resolvePaths collapses dot-dot and strips trailing separator" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const got = try resolvePaths("/test/cwd", &.{ "./foo/../bar/", "extra/" }, arena_alloc.allocator());
    try std.testing.expectEqualStrings("/test/cwd/bar", got[0]);
    try std.testing.expectEqualStrings("/test/cwd/extra", got[1]);
}

test "resolvePaths returns empty for empty input" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const got = try resolvePaths("/test/cwd", &.{}, arena_alloc.allocator());
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

test "pathIsUnderAny matches exact, nested, and rejects similar siblings" {
    const skip = &[_][]const u8{"/data/skip"};
    try std.testing.expect(pathIsUnderAny("/data/skip", skip));
    try std.testing.expect(pathIsUnderAny("/data/skip/sub", skip));
    try std.testing.expect(pathIsUnderAny("/data/skip/sub/inner", skip));
    try std.testing.expect(!pathIsUnderAny("/data/keep", skip));
    try std.testing.expect(!pathIsUnderAny("/data/skippy", skip));
}
