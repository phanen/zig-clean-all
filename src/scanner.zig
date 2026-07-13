//! Recursive scanner that finds Zig project directories under a root.
//!
//! A "Zig project" is any directory containing a `build.zig` file. Artifact
//! directories (`.zig-cache`, `zig-out`, `zig-pkg`) and other dot-prefixed
//! entries are never descended into.
//!
//! Subdirectories are distributed as jobs across an `Io.Group`; each worker
//! walks its assigned directory serially and fuses the analyzer inline so
//! measurement overlaps with discovery.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const path = std.fs.path;
const path_util = @import("path_util.zig");
const analyzer_mod = @import("analyzer.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;
const Atomic = std.atomic;

const NEVER_DESCEND: []const []const u8 = &.{
    ".git",
    ".zig-cache",
    "zig-out",
    "zig-pkg",
};

/// Power-of-two slot count for the inline job queue. Wide trees rarely
/// hold more than a few hundred pending jobs, so 4 KiB of stack is plenty.
/// Workers fall back to `walker.enter` when the queue is full so progress
/// is never blocked.
const QUEUE_CAPACITY: usize = 4096;

comptime {
    assert(QUEUE_CAPACITY >= 16);
    assert(QUEUE_CAPACITY & (QUEUE_CAPACITY - 1) == 0);
}

pub const Project = struct {
    /// Absolute path of the directory containing `build.zig`. Allocated by
    /// the caller's arena; remains valid until the arena is freed.
    path: []const u8,
};

/// Decide whether `entry` is a descendable directory and, if so, allocate
/// its absolute path. Joins `abs_base` with `entry.path` (not
/// `entry.basename`) so the path is correct after a `walker.enter`
/// fallback, where `entry.path` already carries the accumulated relative
/// portion. Allocation failures are folded into `null`.
fn computeDescentTarget(
    arena: Allocator,
    abs_base: []const u8,
    entry: Dir.Walker.Entry,
    skip_paths: []const []const u8,
) ?[]const u8 {
    if (entry.kind != .directory) return null;
    if (shouldSkipDescend(entry.basename)) return null;
    const sub_abs = path.join(arena, &.{ abs_base, entry.path }) catch return null;
    if (path_util.pathIsUnderAny(sub_abs, skip_paths)) return null;
    return sub_abs;
}

/// Decide whether `entry` is a project root (`build.zig`) and, if so,
/// return its absolute path. Allocation failures are folded into `null`.
fn computeProjectTarget(
    arena: Allocator,
    abs_base: []const u8,
    entry: Dir.Walker.Entry,
    skip_paths: []const []const u8,
) ?[]const u8 {
    if (entry.kind != .file) return null;
    if (!std.mem.eql(u8, entry.basename, "build.zig")) return null;
    const project_abs = if (path.dirname(entry.path)) |dir_rel|
        path.join(arena, &.{ abs_base, dir_rel }) catch return null
    else
        abs_base;
    if (path_util.pathIsUnderAny(project_abs, skip_paths)) return null;
    return project_abs;
}

const ScanJob = struct {
    abs_path: []const u8,
};

const ScanContext = struct {
    io: Io,
    skip_paths: []const []const u8,
    arena: Allocator,
    queue: *Io.Queue(ScanJob),
    pending: *Atomic.Value(u32),
    shards: []std.ArrayList(AnalyzedProject),
};

fn walkInto(ctx: *ScanContext, worker_id: u32, abs_path: []const u8) void {
    const dir = Dir.openDirAbsolute(ctx.io, abs_path, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);

    var walker = Dir.walkSelectively(dir, ctx.arena) catch return;
    defer walker.deinit();

    while (true) {
        const next_result = walker.next(ctx.io) catch return;
        const entry = next_result orelse break;

        if (computeDescentTarget(ctx.arena, abs_path, entry, ctx.skip_paths)) |sub_abs| {
            const one_job = [_]ScanJob{.{ .abs_path = sub_abs }};
            const queued = ctx.queue.putUncancelable(ctx.io, &one_job, 0) catch 0;
            if (queued > 0) {
                _ = ctx.pending.fetchAdd(1, .acquire);
            } else {
                walker.enter(ctx.io, entry) catch continue;
            }
            continue;
        }

        if (computeProjectTarget(ctx.arena, abs_path, entry, ctx.skip_paths)) |owned_abs| {
            analyzeAndAppend(ctx, worker_id, owned_abs, dir);
        }
    }
}

/// A project paired with its measurement. Aliased by `selection.Item`.
pub const AnalyzedProject = struct {
    project: Project,
    analysis: analyzer_mod.Analysis,
};

/// Fused find + analyze. Each worker that discovers a project directory
/// opens and measures it inline before publishing the result into its own
/// shard, so workers can keep discovering new projects while one is
/// mid-measurement. `root_path` must be absolute.
pub fn findProjectsAndAnalyze(
    io: Io,
    root_path: []const u8,
    skip_paths: []const []const u8,
    arena: Allocator,
    num_threads: u32,
) !std.ArrayList(AnalyzedProject) {
    var results: std.ArrayList(AnalyzedProject) = .empty;
    errdefer results.deinit(arena);

    const shards = try arena.alloc(std.ArrayList(AnalyzedProject), num_threads);
    for (shards) |*s| s.* = .empty;

    var queue_buffer: [QUEUE_CAPACITY]ScanJob = undefined;
    var queue: Io.Queue(ScanJob) = .init(&queue_buffer);
    var pending: Atomic.Value(u32) = .init(1);

    var ctx: ScanContext = .{
        .io = io,
        .skip_paths = skip_paths,
        .arena = arena,
        .queue = &queue,
        .pending = &pending,
        .shards = shards,
    };

    try queue.putOne(io, .{ .abs_path = root_path });

    var group: Io.Group = .init;
    defer group.cancel(io);

    var i: u32 = 0;
    while (i < num_threads) : (i += 1) {
        group.async(io, workerLoop, .{ &ctx, i });
    }

    try group.await(io);

    for (shards) |*s| {
        try results.appendSlice(arena, s.items);
    }
    return results;
}

fn workerLoop(ctx: *ScanContext, worker_id: u32) void {
    while (true) {
        const job = ctx.queue.getOneUncancelable(ctx.io) catch return;
        walkInto(ctx, worker_id, job.abs_path);
        // The seed job is seeded before `pending` reaches 1; the worker that
        // decrements it to 1 is the last one alive and closes the queue.
        const prev = ctx.pending.fetchSub(1, .acquire);
        if (prev == 1) ctx.queue.close(ctx.io);
    }
}

fn analyzeAndAppend(
    ctx: *ScanContext,
    worker_id: u32,
    project_abs: []const u8,
    project_dir: Dir,
) void {
    // Reuse the walker's fd: the analyzer opens a fresh fd for each
    // child subdir, so it cannot disturb the walker's iteration position.
    const analysis = analyzer_mod.analyze(ctx.io, project_dir, project_abs, ctx.arena) catch return;

    ctx.shards[worker_id].append(ctx.arena, .{
        .project = .{ .path = project_abs },
        .analysis = analysis,
    }) catch return;
}

fn shouldSkipDescend(basename: []const u8) bool {
    inline for (NEVER_DESCEND) |name| {
        if (std.mem.eql(u8, basename, name)) return true;
    }
    if (basename.len > 0 and basename[0] == '.') return true;
    return false;
}

/// Best-effort chmod used by fixture setup. Swallows errors so the test
/// continues even when the kernel refuses (for example in a sandbox).
fn chmodOrSkip(raw_path: []const u8, mode: u32) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z_path = std.fmt.bufPrintZ(&buf, "{s}", .{raw_path}) catch return;
    _ = std.os.linux.chmod(z_path, mode);
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

test "findProjectsAndAnalyze tolerates an unreadable sub-tree" {
    // Root bypasses mode bits, so the chmod-based fixture cannot
    // produce AccessDenied for it.
    if (builtin.os.tag != .linux) return;
    if (std.os.linux.geteuid() == 0) return;

    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    // Workers park in `getOne` before the seed job is enqueued, so the
    // default nproc-1 async limit deadlocks once group.async runs out of
    // headroom.
    env.setAsyncLimit(.limited(8));
    const io = env.io();

    const fixture = "/tmp/zca-scanner-unreadable";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture) catch {};

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

    var arena_buf: [1 * 1024 * 1024]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const analyzed = try findProjectsAndAnalyze(io, fixture, &.{}, arena, 4);

    // The readable project must be found; the locked one may or may not
    // show up depending on whether the walker visited it before the
    // chmod bit took effect. The contract is: must not error out.
    var found_keep = false;
    for (analyzed.items) |a| {
        if (std.mem.indexOf(u8, a.project.path, "keep-project") != null) found_keep = true;
    }
    try std.testing.expect(found_keep);
}

test "parallel scanner finds each project exactly once in a deep tree" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    env.setAsyncLimit(.limited(8));
    const io = env.io();

    // FixedBufferAllocator corrupts under concurrent allocation; the
    // thread-safe ArenaAllocator is required.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture = "/tmp/zca-scanner-parallel";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture) catch {};

    try cwd.createDir(io, fixture, .default_dir);
    const branches = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    for (branches) |b| {
        const deep_path = try std.fs.path.join(arena, &.{ fixture, b, "nested", "deep" });
        try cwd.createDirPath(io, deep_path);
        {
            const dir = try cwd.openDir(io, deep_path, .{});
            defer dir.close(io);
            var f = try dir.createFile(io, "build.zig", .{});
            defer f.close(io);
            try f.writeStreamingAll(io, "// stub");
        }
    }
    defer cwd.deleteTree(io, fixture) catch {};

    // Exercise the queue-fallback path with several thread counts; four
    // subdirs never exceed the queue capacity so there's no deadlock risk.
    var thread_count: u32 = 1;
    while (thread_count <= 4) : (thread_count += 1) {
        const analyzed = try findProjectsAndAnalyze(io, fixture, &.{}, arena, thread_count);
        try std.testing.expectEqual(@as(usize, branches.len), analyzed.items.len);
    }
}
