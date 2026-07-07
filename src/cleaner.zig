//! Remove the artifact directories that the selection has flagged for
//! cleanup. Supports a `--keep-empty` mode that empties each artifact
//! directory in place rather than removing the directory itself.

const std = @import("std");
const path = std.fs.path;
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

/// Delete every artifact directory listed in `selections`. Returns a summary
/// the caller can use to print a final report. Failures on individual
/// artifacts are accumulated and returned instead of aborting the run.
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
            for (ARTIFACT_NAMES) |name| try failures.append(arena, .{
                .project_path = project,
                .artifact_name = name,
                .err = err,
            });
            continue;
        };
        defer project_dir.close(io);

        for (ARTIFACT_NAMES) |name| {
            const sub = project_dir.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => {
                    try failures.append(arena, .{
                        .project_path = project,
                        .artifact_name = name,
                        .err = err,
                    });
                    continue;
                },
            };
            sub.close(io);
            if (keep_empty) {
                emptyDir(io, project_dir, name) catch |err| {
                    try failures.append(arena, .{
                        .project_path = project,
                        .artifact_name = name,
                        .err = err,
                    });
                    continue;
                };
                emptied += 1;
            } else {
                project_dir.deleteTree(io, name) catch |err| {
                    try failures.append(arena, .{
                        .project_path = project,
                        .artifact_name = name,
                        .err = err,
                    });
                    continue;
                };
                removed += 1;
            }
        }
    }
    return .{
        .removed = removed,
        .emptied = emptied,
        .failed = try failures.toOwnedSlice(arena),
    };
}

/// Remove every child of `parent/name` while keeping `parent/name` itself
/// in place. Walks the subtree via a manual stack to avoid pulling in a
/// per-delete allocation.
fn emptyDir(io: Io, parent: Dir, name: []const u8) anyerror!void {
    const StackItem = struct {
        dir: Dir,
        iter: Dir.Iterator,
    };

    var stack_buffer: [16]StackItem = undefined;
    var stack = std.ArrayList(StackItem).initBuffer(&stack_buffer);
    defer {
        for (stack.items) |*item| item.dir.close(io);
    }

    const initial = parent.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    errdefer initial.close(io);
    stack.appendAssumeCapacity(.{ .dir = initial, .iter = initial.iterateAssumeFirstIteration() });

    while (stack.items.len > 0) {
        var top = &stack.items[stack.items.len - 1];
        const maybe_entry = top.iter.next(io) catch |err| {
            top.dir.close(io);
            stack.items.len -= 1;
            return err;
        };
        const entry = maybe_entry orelse {
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
                    // Out of local stack - fall back to deleteTree which uses
                    // its own stack buffer.
                    top.dir.deleteTree(io, entry.name) catch continue;
                }
            },
            .file, .sym_link => {
                top.dir.deleteFile(io, entry.name) catch continue;
            },
            else => continue,
        }
    }
}

test "emptyDir removes file contents" {
    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    // Build a tiny fixture: /tmp/zca-empty-test/{.zig-cache/file.txt}
    const fixture_root = "/tmp/zca-empty-test";
    const artifact_rel = ".zig-cache";
    const file_rel = ".zig-cache/file.txt";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture_root) catch {};

    try cwd.makeDir(io, fixture_root);
    try cwd.makePath(io, fixture_root ++ "/" ++ artifact_rel);
    {
        const dir = try cwd.openDir(io, fixture_root, .{});
        defer dir.close(io);
        var file = try dir.openFile(io, file_rel, .{ .mode = .read_write });
        defer file.close(io);
        try file.writeStreamingAll(io, "hello");
    }

    {
        const dir = try cwd.openDir(io, fixture_root, .{});
        try emptyDir(io, dir, artifact_rel);
    }

    // Directory should still exist but be empty.
    const dir_after = try cwd.openDir(io, fixture_root, .{});
    defer dir_after.close(io);
    const sub = try dir_after.openDir(io, artifact_rel, .{ .iterate = true });
    defer sub.close(io);
    var iter = sub.iterate();
    const first = try iter.next(io);
    try std.testing.expect(first == null);

    cwd.deleteTree(io, fixture_root) catch {};
}
