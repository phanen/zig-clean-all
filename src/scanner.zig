//! Recursive scanner that finds Zig project directories under a root.
//!
//! A "Zig project" is defined as any directory that contains a `build.zig`
//! file directly within it. Artifact directories (`.zig-cache`, `zig-out`,
//! `zig-pkg`) are never descended into - they waste time and can be deeply
//! nested. Other hidden directories are also skipped.

const std = @import("std");
const fs = std.fs;
const path = fs.path;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

const NEVER_DESCEND: []const []const u8 = &.{
    ".git",
    ".zig-cache",
    "zig-out",
    "zig-pkg",
};

pub const Project = struct {
    /// Absolute path of the directory containing `build.zig`. Allocated by
    /// `arena`; remains valid until the arena is freed.
    path: []const u8,
};

/// Recursively scan `root_dir` for directories that contain a `build.zig`.
/// Each detected project is appended to `out`. The walker deliberately skips
/// artifact directories and any sub-tree rooted under a path in `skip_paths`
/// (matched as a path prefix).
///
/// `root_base` is the path that `root_dir` was opened with - it becomes the
/// prefix for every project `path` written to `out`. `root_base` itself must
/// already be absolute (resolve it via `process.currentPathAlloc` first).
///
/// `skip_paths` must also already be absolute and have any trailing
/// separator stripped - the matcher does plain string comparison, so
/// resolution is the caller's responsibility. Use `resolveSkipPaths` below
/// to do that consistently with the workdir used at startup.
///
/// All allocations come from `arena`; callers should normally pass a process
/// arena and drop the results together.
pub fn findProjects(
    io: Io,
    root_dir: Dir,
    root_base: []const u8,
    skip_paths: []const []const u8,
    arena: Allocator,
    out: *std.ArrayList(Project),
) anyerror!void {
    var walker = try Dir.walkSelectively(root_dir, arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (shouldSkipDescend(entry.basename)) continue;
            const abs = try joinIntoArena(arena, root_base, entry.path);
            if (matchesAnySkipPath(abs, skip_paths)) continue;
            try walker.enter(io, entry);
            continue;
        }

        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "build.zig")) continue;

        const dir_rel = path.dirname(entry.path) orelse "";
        const project_abs = try joinIntoArena(arena, root_base, dir_rel);
        if (matchesAnySkipPath(project_abs, skip_paths)) continue;
        const owned = try arena.dupe(u8, project_abs);
        try out.append(arena, .{ .path = owned });
    }
}

fn joinIntoArena(arena: Allocator, base: []const u8, rel: []const u8) ![]const u8 {
    if (rel.len == 0) return base;
    return path.join(arena, &.{ base, rel });
}

/// Resolve each skip path against the current working directory so that
/// string-based path comparison inside `findProjects` is correct. Absolute
/// paths are kept verbatim; relative paths are joined with the cwd.
pub fn resolveSkipPaths(
    io: Io,
    cwd_path: []const u8,
    skip_paths: []const []const u8,
    arena: Allocator,
) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (skip_paths) |raw| {
        const resolved = if (path.isAbsolute(raw)) raw else try path.join(arena, &.{ cwd_path, raw });
        // Strip any trailing path separator so prefix matching is consistent.
        const trimmed = if (resolved.len > 1 and resolved[resolved.len - 1] == path.sep)
            resolved[0 .. resolved.len - 1]
        else
            resolved;
        try list.append(arena, trimmed);
    }
    _ = io;
    return try list.toOwnedSlice(arena);
}

fn shouldSkipDescend(basename: []const u8) bool {
    for (NEVER_DESCEND) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    if (basename.len > 0 and basename[0] == '.') return true;
    return false;
}

/// Returns true when `entry_path` equals or is nested inside one of the
/// user-supplied skip roots. Compared as path strings; the caller is
/// expected to have resolved and normalised each skip path.
fn matchesAnySkipPath(
    entry_path: []const u8,
    skip_paths: []const []const u8,
) bool {
    for (skip_paths) |skip| {
        if (std.mem.eql(u8, entry_path, skip)) return true;
        if (entry_path.len > skip.len and
            std.mem.eql(u8, entry_path[0..skip.len], skip) and
            entry_path[skip.len] == path.sep)
            return true;
    }
    return false;
}

test "matchesAnySkipPath excludes nested dirs" {
    const skips = [_][]const u8{"/data/skip"};
    try std.testing.expect(matchesAnySkipPath("/data/skip", &skips));
    try std.testing.expect(matchesAnySkipPath("/data/skip/sub", &skips));
    try std.testing.expect(matchesAnySkipPath("/data/skip/sub/inner", &skips));
    try std.testing.expect(!matchesAnySkipPath("/data/keep", &skips));
    try std.testing.expect(!matchesAnySkipPath("/data/skippy", &skips));
}

test "shouldSkipDescend matches known artifact dirs" {
    try std.testing.expect(shouldSkipDescend(".git"));
    try std.testing.expect(shouldSkipDescend(".zig-cache"));
    try std.testing.expect(shouldSkipDescend("zig-out"));
    try std.testing.expect(shouldSkipDescend("zig-pkg"));
    try std.testing.expect(shouldSkipDescend(".hidden"));
    try std.testing.expect(!shouldSkipDescend("src"));
    try std.testing.expect(!shouldSkipDescend(""));
}
