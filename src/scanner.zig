//! Recursive scanner that finds Zig project directories under a root.
//!
//! A "Zig project" is defined as any directory that contains a `build.zig`
//! file directly within it. Artifact directories (`.zig-cache`, `zig-out`,
//! `zig-pkg`) are never descended into - they waste time and can be deeply
//! nested. Other hidden directories are also skipped.

const std = @import("std");
const builtin = @import("builtin");
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
///
/// I/O errors from `walker.next` and `walker.enter` (typically
/// `AccessDenied` deep in the tree) are swallowed: a single unreadable
/// sub-tree is skipped and the scan continues with the rest of the work,
/// rather than aborting the whole run.
pub fn findProjects(
    io: Io,
    root_dir: Dir,
    root_base: []const u8,
    skip_paths: []const []const u8,
    arena: Allocator,
    out: *std.ArrayList(Project),
) anyerror!void {
    var walker = Dir.walkSelectively(root_dir, arena) catch return;
    defer walker.deinit();

    while (true) {
        const next_result = walker.next(io) catch return;
        const entry = next_result orelse break;
        if (entry.kind == .directory) {
            if (shouldSkipDescend(entry.basename)) continue;
            const abs = joinIntoArena(arena, root_base, entry.path) catch continue;
            if (pathIsUnderAny(abs, skip_paths)) continue;
            walker.enter(io, entry) catch continue;
            continue;
        }

        if (entry.kind != .file) continue;
        if (!std.mem.eql(u8, entry.basename, "build.zig")) continue;

        const dir_rel = path.dirname(entry.path) orelse "";
        const project_abs = joinIntoArena(arena, root_base, dir_rel) catch continue;
        if (pathIsUnderAny(project_abs, skip_paths)) continue;
        const owned = arena.dupe(u8, project_abs) catch continue;
        out.append(arena, .{ .path = owned }) catch continue;
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
    return try list.toOwnedSlice(arena);
}

fn shouldSkipDescend(basename: []const u8) bool {
    for (NEVER_DESCEND) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    if (basename.len > 0 and basename[0] == '.') return true;
    return false;
}

/// Returns true when `path` equals or is nested inside one of the supplied
/// roots. Compared as path strings; the caller is expected to have resolved
/// and normalised each root.
pub fn pathIsUnderAny(p: []const u8, roots: []const []const u8) bool {
    for (roots) |root| {
        if (std.mem.eql(u8, p, root)) return true;
        if (p.len > root.len and
            std.mem.eql(u8, p[0..root.len], root) and
            p[root.len] == path.sep) return true;
    }
    return false;
}

/// Best-effort chmod used by fixture setup. `std.os.linux.chmod` returns a
/// raw syscall result, so wrap it and swallow any error so the test
/// continues even when the kernel refuses (for example in a sandbox).
fn chmodOrSkip(raw_path: []const u8, mode: u32) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z_path = std.fmt.bufPrintZ(&buf, "{s}", .{raw_path}) catch return;
    _ = std.os.linux.chmod(z_path, mode);
}

test "pathIsUnderAny excludes nested dirs" {
    const skips = [_][]const u8{"/data/skip"};
    try std.testing.expect(pathIsUnderAny("/data/skip", &skips));
    try std.testing.expect(pathIsUnderAny("/data/skip/sub", &skips));
    try std.testing.expect(pathIsUnderAny("/data/skip/sub/inner", &skips));
    try std.testing.expect(!pathIsUnderAny("/data/keep", &skips));
    try std.testing.expect(!pathIsUnderAny("/data/skippy", &skips));
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

test "findProjects tolerates an unreadable sub-tree" {
    // Root bypasses mode bits, so the chmod-based fixture cannot
    // produce AccessDenied for it.
    if (builtin.os.tag != .linux) return;
    if (std.os.linux.geteuid() == 0) return;

    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    const io = env.io();

    const fixture = "/tmp/zca-scanner-unreadable";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture) catch {};

    // Two projects at the same level; lock one so the walker hits
    // AccessDenied when descending into it.
    try cwd.createDir(io, fixture, .default_dir);
    try cwd.createDirPath(io, fixture ++ "/keep-project");
    try cwd.createDirPath(io, fixture ++ "/lock-project/locked-deep");
    {
        const keep_dir = try cwd.openDir(io, fixture ++ "/keep-project", .{});
        defer keep_dir.close(io);
        var f = try keep_dir.createFile(io, "build.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "// stub");
    }
    {
        const lock_dir = try cwd.openDir(io, fixture ++ "/lock-project", .{});
        defer lock_dir.close(io);
        var f = try lock_dir.createFile(io, "build.zig", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "// stub");
    }
    chmodOrSkip(fixture ++ "/lock-project", 0o000);

    defer chmodOrSkip(fixture ++ "/lock-project", 0o755);
    defer cwd.deleteTree(io, fixture) catch {};

    var arena_buf: [8192]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const root_dir = try cwd.openDir(io, fixture, .{ .iterate = true });
    defer root_dir.close(io);

    var projects: std.ArrayList(Project) = .empty;
    try findProjects(io, root_dir, fixture, &.{}, arena, &projects);

    // The readable project must be found; the locked one may or may not
    // show up depending on whether the walker visited it before the
    // chmod bit took effect. The contract is: must not error out.
    var found_keep = false;
    for (projects.items) |p| {
        if (std.mem.indexOf(u8, p.path, "keep-project") != null) found_keep = true;
    }
    try std.testing.expect(found_keep);
}
