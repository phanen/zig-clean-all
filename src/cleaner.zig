//! Remove the artifact directories that the selection has flagged for
//! cleanup. With `--keep-empty` the artifact directory is emptied in place
//! rather than removed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

const ARTIFACT_NAMES: []const []const u8 = &.{ ".zig-cache", "zig-out", "zig-pkg" };

pub const Failure = struct {
    project_path: []const u8,
    artifact_name: []const u8,
    err: anyerror,
};

pub const Summary = struct {
    removed: usize,
    emptied: usize,
    failed: []Failure,
};

const Outcome = enum { removed, emptied, skipped };

/// Delete every artifact directory under `project_paths`. Per-artifact
/// failures are accumulated in `Summary.failed` so a partial failure never
/// aborts the rest of the run.
pub fn cleanAll(
    io: Io,
    arena: Allocator,
    project_paths: []const []const u8,
    keep_empty: bool,
) anyerror!Summary {
    var failures: std.ArrayList(Failure) = .empty;
    var removed: usize = 0;
    var emptied: usize = 0;
    const cwd = Dir.cwd();

    for (project_paths) |project| {
        const project_dir = cwd.openDir(io, project, .{ .iterate = true }) catch |err| {
            try recordFailure(arena, &failures, project, "<project>", err);
            continue;
        };
        defer project_dir.close(io);

        for (ARTIFACT_NAMES) |name| {
            switch (try cleanOne(io, project_dir, project, name, keep_empty, arena, &failures)) {
                .removed => removed += 1,
                .emptied => emptied += 1,
                .skipped => {},
            }
        }
    }

    return .{
        .removed = removed,
        .emptied = emptied,
        .failed = try failures.toOwnedSlice(arena),
    };
}

fn cleanOne(
    io: Io,
    project_dir: Dir,
    project_path: []const u8,
    name: []const u8,
    keep_empty: bool,
    arena: Allocator,
    failures: *std.ArrayList(Failure),
) anyerror!Outcome {
    const sub = project_dir.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .skipped,
        else => {
            try recordFailure(arena, failures, project_path, name, err);
            return .skipped;
        },
    };
    sub.close(io);

    if (keep_empty) {
        emptyDir(io, project_dir, name) catch |err| {
            try recordFailure(arena, failures, project_path, name, err);
            return .skipped;
        };
        return .emptied;
    }

    project_dir.deleteTree(io, name) catch |err| {
        try recordFailure(arena, failures, project_path, name, err);
        return .skipped;
    };
    return .removed;
}

fn recordFailure(
    arena: Allocator,
    failures: *std.ArrayList(Failure),
    project_path: []const u8,
    artifact_name: []const u8,
    err: anyerror,
) !void {
    try failures.append(arena, .{
        .project_path = project_path,
        .artifact_name = artifact_name,
        .err = err,
    });
}

/// Remove every child of `parent/name` while keeping `parent/name` itself.
/// Walks via a small inline stack so most directories need no allocation.
/// When the local stack runs out, fall back to `deleteTree` which uses its
/// own stack buffer.
fn emptyDir(io: Io, parent: Dir, name: []const u8) anyerror!void {
    const StackItem = struct {
        dir: Dir,
        iter: Dir.Iterator,
    };

    const initial = parent.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    errdefer initial.close(io);

    var stack_buffer: [16]StackItem = undefined;
    var stack = std.ArrayList(StackItem).initBuffer(&stack_buffer);
    defer for (stack.items) |*item| item.dir.close(io);

    stack.appendAssumeCapacity(.{ .dir = initial, .iter = initial.iterateAssumeFirstIteration() });

    while (stack.items.len > 0) {
        var top = &stack.items[stack.items.len - 1];
        const next_entry = top.iter.next(io) catch |err| {
            top.dir.close(io);
            stack.items.len -= 1;
            return err;
        };
        const entry = next_entry orelse {
            top.dir.close(io);
            stack.items.len -= 1;
            continue;
        };
        const stat = top.dir.statFile(io, entry.name, .{}) catch continue;
        switch (stat.kind) {
            .directory => {
                if (stack.unusedCapacitySlice().len > 0) {
                    const sub = top.dir.openDir(io, entry.name, .{
                        .iterate = true,
                        .follow_symlinks = false,
                    }) catch continue;
                    stack.appendAssumeCapacity(.{ .dir = sub, .iter = sub.iterateAssumeFirstIteration() });
                } else {
                    top.dir.deleteTree(io, entry.name) catch continue;
                }
            },
            .file, .sym_link => top.dir.deleteFile(io, entry.name) catch continue,
            else => continue,
        }
    }
}

test "cleanAll no-op on missing artifact directories" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    const io = env.io();

    const fake_root = "/tmp/zca-cleaner-missing";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fake_root) catch {};
    try cwd.createDir(io, fake_root, .default_dir);

    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const paths = [_][]const u8{fake_root};
    const summary = try cleanAll(io, arena, &paths, false);
    try std.testing.expectEqual(@as(usize, 0), summary.removed);
    try std.testing.expectEqual(@as(usize, 0), summary.failed.len);

    cwd.deleteTree(io, fake_root) catch {};
}

test "emptyDir removes file contents" {
    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    const io = env.io();

    const fixture_root = "/tmp/zca-empty-test";
    const artifact_rel = ".zig-cache";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture_root) catch {};

    try cwd.createDir(io, fixture_root, .default_dir);
    try cwd.createDirPath(io, fixture_root ++ "/" ++ artifact_rel);
    {
        const dir = try cwd.openDir(io, fixture_root, .{});
        defer dir.close(io);
        var file = try dir.createFile(io, ".zig-cache/file.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "hello");
    }

    {
        const dir = try cwd.openDir(io, fixture_root, .{});
        try emptyDir(io, dir, artifact_rel);
    }

    const dir_after = try cwd.openDir(io, fixture_root, .{});
    defer dir_after.close(io);
    const sub = try dir_after.openDir(io, artifact_rel, .{ .iterate = true });
    defer sub.close(io);
    var iter = sub.iterate();
    try std.testing.expect(try iter.next(io) == null);

    cwd.deleteTree(io, fixture_root) catch {};
}
