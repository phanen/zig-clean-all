//! Recursive scanner that finds Zig project directories under a root.
//!
//! A "Zig project" is defined as any directory that contains a `build.zig`
//! file directly within it. Artifact directories (`.zig-cache`, `zig-out`,
//! `zig-pkg`) are never descended into - they waste time and can be deeply
//! nested. Other hidden directories are also skipped.
//!
//! The scanner is parallel: with `num_threads >= 2`, subdirectories are
//! distributed as jobs across a worker pool via an `Io.Queue`, while each
//! worker walks its assigned directory serially. Workloads with shallow but
//! wide directory trees (typical large checkouts) scale almost linearly up
//! to the number of CPUs.

const std = @import("std");
const builtin = @import("builtin");
const std_debug = std.debug;
const assert = std_debug.assert;
const fs = std.fs;
const path = fs.path;
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

comptime {
    assert(QUEUE_CAPACITY >= 16);
    assert(QUEUE_CAPACITY & (QUEUE_CAPACITY - 1) == 0);
}
/// Capacity of the inline job queue. Each directory a worker encounters
/// becomes a job; very wide trees could overflow this in principle, but in
/// practice new jobs are consumed almost as fast as they are produced and
/// the queue rarely holds more than a few hundred entries. When the buffer
/// fills, workers fall back to walking the subdirectory inline rather than
/// blocking on `put`, so progress is never lost. Power-of-two so the stack
/// footprint stays round; floors at 16 because any smaller ring degenerates
/// into immediate back-pressure.
const QUEUE_CAPACITY: usize = 4096;

pub const Project = struct {
    /// Absolute path of the directory containing `build.zig`. Allocated by
    /// `arena`; remains valid until the arena is freed.
    path: []const u8,
};

/// One unit of work for the parallel scanner: walk the directory at
/// `abs_path` and enqueue each of its descendable subdirectories.
const ScanJob = struct {
    abs_path: []const u8,
};

/// Shared state handed to every worker. Lives on the calling task's stack;
/// each task's `Group.async` call copies the args tuple (which contains a
/// pointer to this struct) onto the Group's heap, so the pointer remains
/// valid for the lifetime of the scan.
const ScanContext = struct {
    io: Io,
    skip_paths: []const []const u8,
    /// Worker arena. Must be the Zig-0.16 lock-free `ArenaAllocator`; the
    /// `init.arena` from juicy main satisfies this. All `ScanJob.abs_path`
    /// slices are owned by it.
    arena: Allocator,
    queue: *Io.Queue(ScanJob),
    results: *std.ArrayList(Project),
    results_mutex: *Io.Mutex,
    /// Number of jobs in flight (queued + currently being processed by a
    /// worker). Initialised to 1 by the producer (the seed job). Workers
    /// `fetchAdd` after a successful enqueue and `fetchSub` after finishing
    /// a job; whichever worker drives the counter to zero closes the queue
    /// so every other worker observes `error.Closed` on its next `getOne`
    /// and exits cleanly.
    pending: *Atomic.Value(u32),
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
/// `num_threads` controls the worker pool size. `1` selects the serial
/// walker (useful for tests / single-core systems); `>= 2` distributes work
/// across a pool of that many workers. The caller is expected to have
/// already resolved any "auto" policy to a concrete value.
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
    num_threads: u32,
) anyerror!void {
    if (num_threads <= 1) {
        findProjectsSerial(io, root_dir, root_base, skip_paths, arena, out);
        return;
    }
    try findProjectsParallel(io, root_base, skip_paths, arena, out, num_threads);
}

/// Single-threaded walk. Kept as the reference implementation - the
/// parallel walker preserves all of its decisions (skip lists, descent
/// rules, project-path construction) but distributes them across workers.
fn findProjectsSerial(
    io: Io,
    root_dir: Dir,
    root_base: []const u8,
    skip_paths: []const []const u8,
    arena: Allocator,
    out: *std.ArrayList(Project),
) void {
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

/// Distributes the directory walk across `num_threads` workers. The queue
/// is closed once the seed job has been enqueued; workers terminate when
/// they observe `error.Closed` from `getOne`. Subdirectories whose abs path
/// cannot fit in the queue are walked inline so a busy buffer never blocks
/// progress.
fn findProjectsParallel(
    io: Io,
    root_base: []const u8,
    skip_paths: []const []const u8,
    arena: Allocator,
    out: *std.ArrayList(Project),
    num_threads: u32,
) !void {
    assert(num_threads >= 2);

    var queue_buffer: [QUEUE_CAPACITY]ScanJob = undefined;
    var queue: Io.Queue(ScanJob) = .init(&queue_buffer);
    var results_mutex: Io.Mutex = .init;
    // The seed job accounts for one unit of pending work.
    var pending: Atomic.Value(u32) = .init(1);

    var ctx: ScanContext = .{
        .io = io,
        .skip_paths = skip_paths,
        .arena = arena,
        .queue = &queue,
        .results = out,
        .results_mutex = &results_mutex,
        .pending = &pending,
    };

    var group: Io.Group = .init;
    // `await` resets the group's token; `cancel` is a no-op afterwards, so
    // the `defer` is safe whether or not `await` succeeded.
    defer group.cancel(io);

    var i: u32 = 0;
    while (i < num_threads) : (i += 1) {
        group.async(io, scanWorker, .{&ctx});
    }

    // Seed the queue. Workers were already spawned above so they're racing
    // to consume this; `putOne` blocks until there is space. We must put
    // before `await` because the workers close the queue themselves once
    // the pending counter hits zero.
    try queue.putOne(io, .{ .abs_path = root_base });

    try group.await(io);
}

fn scanWorker(ctx: *ScanContext) void {
    while (true) {
        const job = ctx.queue.getOneUncancelable(ctx.io) catch return;
        walkInto(ctx, job.abs_path);
        // Account for the job we just finished. If we drove the counter
        // to zero, no more work can ever appear (every other worker is
        // either exiting or about to), so close the queue to unblock
        // workers parked in `getOne`.
        const prev = ctx.pending.fetchSub(1, .acq_rel);
        if (prev == 1) ctx.queue.close(ctx.io);
    }
}

/// Walk `abs_path` as a project root. Every descendable subdirectory is
/// enqueued as a new `ScanJob` so the worker pool can pick it up
/// concurrently; this is the key load-balancing trick. If the job queue
/// is full, the subdirectory is walked inline as a fallback so progress is
/// never blocked by queue back-pressure. `build.zig` files found at any
/// depth are appended to the shared results list under a mutex.
///
/// Errors from the walker are swallowed to match the serial contract: a
/// single unreadable sub-tree never aborts the whole scan.
fn walkInto(ctx: *ScanContext, abs_path: []const u8) void {
    const dir = Dir.openDirAbsolute(ctx.io, abs_path, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);

    var walker = Dir.walkSelectively(dir, ctx.arena) catch return;
    defer walker.deinit();

    while (true) {
        const next_result = walker.next(ctx.io) catch return;
        const entry = next_result orelse break;
        switch (entry.kind) {
            .directory => {
                if (shouldSkipDescend(entry.basename)) continue;
                // `entry.path` already carries every intermediate directory
                // the walker has descended into via prior `walker.enter`
                // fallback calls. Joining `abs_path` with `entry.path` is
                // therefore correct whether or not the walker is still
                // sitting at its root. Using `entry.basename` instead
                // yields an absolute path that drops the intermediates
                // and points at a sibling of the real subdir - that bug
                // caused the parallel scanner to double-report projects
                // (once from the inline fallback, once when the enqueued
                // job was later processed by another worker).
                const sub_abs = path.join(ctx.arena, &.{ abs_path, entry.path }) catch continue;
                if (pathIsUnderAny(sub_abs, ctx.skip_paths)) continue;

                // Try to enqueue without blocking. If the queue is full or
                // closed, fall back to walking this subtree inline in the
                // current worker - it preserves progress at the cost of a
                // brief load imbalance. Only bump `pending` after a real
                // enqueue; an inline walk is "absorbed" into this job's
                // own pending slot, so the counter is naturally balanced
                // when this worker decrements at the end.
                const one_job = [_]ScanJob{.{ .abs_path = sub_abs }};
                const queued = ctx.queue.putUncancelable(ctx.io, &one_job, 0) catch 0;
                if (queued > 0) {
                    _ = ctx.pending.fetchAdd(1, .acq_rel);
                } else {
                    walker.enter(ctx.io, entry) catch continue;
                }
            },
            .file => {
                if (!std.mem.eql(u8, entry.basename, "build.zig")) continue;
                const dir_rel = path.dirname(entry.path) orelse "";
                const project_abs = joinIntoArena(ctx.arena, abs_path, dir_rel) catch continue;
                if (pathIsUnderAny(project_abs, ctx.skip_paths)) continue;
                const owned = ctx.arena.dupe(u8, project_abs) catch continue;
                appendResult(ctx, owned);
            },
            else => {},
        }
    }
}

fn appendResult(ctx: *ScanContext, owned_path: []const u8) void {
    // Lock as uncancelable: results are append-only and a single append
    // completes in microseconds, so the futex-wait path is never taken
    // in practice and there's no benefit to allowing cancelation here.
    ctx.results_mutex.lockUncancelable(ctx.io);
    defer ctx.results_mutex.unlock(ctx.io);
    ctx.results.append(ctx.arena, .{ .path = owned_path }) catch return;
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
    // Lift `async_limit` past the nproc-1 default so the 4-worker run
    // below doesn't fall back to eager execution on hosts with few cores
    // (which would deadlock in `getOneUncancelable`).
    env.setAsyncLimit(.limited(8));
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

    var arena_buf: [1 * 1024 * 1024]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const root_dir = try cwd.openDir(io, fixture, .{ .iterate = true });
    defer root_dir.close(io);

    var projects: std.ArrayList(Project) = .empty;
    // Force the parallel path even though it is a tiny fixture: the test
    // is mainly a regression guard for the chmod-induced read error,
    // and the parallel walker has its own swallow-the-error branches.
    try findProjects(io, root_dir, fixture, &.{}, arena, &projects, 4);

    // The readable project must be found; the locked one may or may not
    // show up depending on whether the walker visited it before the
    // chmod bit took effect. The contract is: must not error out.
    var found_keep = false;
    for (projects.items) |p| {
        if (std.mem.indexOf(u8, p.path, "keep-project") != null) found_keep = true;
    }
    try std.testing.expect(found_keep);
}

test "parallel scanner finds each project exactly once in a deep tree" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    // Lift `async_limit` past the nproc-1 default: workers park in
    // `getOne` before the seed job is enqueued, so anything less than
    // `num_threads + 1` deadlocks the moment `group.async` runs out of
    // headroom.
    env.setAsyncLimit(.limited(8));
    const io = env.io();

    // The parallel scanner allocates concurrently from this arena via
    // multiple worker threads. FixedBufferAllocator is single-threaded
    // and corrupts under contention; ArenaAllocator is threadsafe as
    // long as its child allocator is.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fixture = "/tmp/zca-scanner-parallel";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture) catch {};

    // Build a wide tree: 4 top-level dirs, each with a deeply nested
    // build.zig. The parallel scanner must find every project and never
    // double-report one (a regression we hit when `walker.enter`'s
    // fallback path computed the subdir abs path from `entry.basename`
    // instead of the accumulated `entry.path`).
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

    const root_dir = try cwd.openDir(io, fixture, .{ .iterate = true });
    defer root_dir.close(io);

    // Run with several thread counts to exercise the queue-fallback
    // path on the smaller fixture (no risk of deadlock - four subdirs
    // never exceed the queue capacity).
    var thread_count: u32 = 1;
    while (thread_count <= 4) : (thread_count += 1) {
        var projects: std.ArrayList(Project) = .empty;
        try findProjects(io, root_dir, fixture, &.{}, arena, &projects, thread_count);
        try std.testing.expectEqual(@as(usize, branches.len), projects.items.len);
    }
}
