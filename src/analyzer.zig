//! Measures a project's build artifacts so the caller can decide whether
//! to wipe them.
//!
//! "Artifacts" for a Zig project are `.zig-cache`, `zig-out`, and `zig-pkg`.
//! The analyzer walks each one that exists, sums the bytes, and records the
//! most recent modification time found in any descendant. Symlinks are not
//! followed - they would invite both cycles and double-counting.

const std = @import("std");
const fs = std.fs;
const path = fs.path;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

const ARTIFACT_NAMES: []const []const u8 = &.{ ".zig-cache", "zig-out", "zig-pkg" };

pub const Analysis = struct {
    /// Absolute paths of artifact directories that exist under the project.
    /// Allocated by `arena`. Order matches the order in `ARTIFACT_NAMES`.
    artifact_paths: []const []const u8,
    /// Sum of sizes of every regular file under every artifact directory.
    /// Zero if no artifact exists.
    total_size_bytes: u64,
    /// Latest `mtime.nanoseconds` observed in any descendant file. Zero if
    /// no artifact exists.
    last_modified_ns: i128,
};

/// Open `project_dir` and measure its build artifacts. The caller is
/// responsible for the project directory handle.
pub fn analyze(
    io: Io,
    project_dir: Dir,
    project_path: []const u8,
    arena: Allocator,
) anyerror!Analysis {
    var found: std.ArrayList([]const u8) = .empty;
    var total_size: u64 = 0;
    var latest_ns: i128 = 0;

    for (ARTIFACT_NAMES) |name| {
        var measure: Measure = .zero;
        try measureArtifact(io, project_dir, project_path, name, arena, &found, &measure);
        total_size += measure.total_size;
        if (measure.latest_ns > latest_ns) latest_ns = measure.latest_ns;
    }

    return .{
        .artifact_paths = try found.toOwnedSlice(arena),
        .total_size_bytes = total_size,
        .last_modified_ns = latest_ns,
    };
}

/// Open one artifact sub-directory, record its absolute path, and walk it to
/// tally size and mtime. Returns silently with `out` left at zero when the
/// artifact does not exist.
fn measureArtifact(
    io: Io,
    project_dir: Dir,
    project_path: []const u8,
    name: []const u8,
    arena: Allocator,
    found: *std.ArrayList([]const u8),
    out: *Measure,
) anyerror!void {
    const sub = project_dir.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer sub.close(io);

    const abs = try path.join(arena, &.{ project_path, name });
    try found.append(arena, abs);
    try measureDir(io, sub, arena, out);
}

const Measure = struct {
    total_size: u64,
    latest_ns: i128,

    const zero: Measure = .{ .total_size = 0, .latest_ns = 0 };
};

/// Recursive visitor that counts bytes and tracks the maximum mtime. The
/// walker deliberately stops at symlinks to avoid loops and double counting.
/// `arena` backs the walker's internal stack so callers don't need a
/// long-lived allocator for the duration of the measurement.
///
/// I/O errors that bubble up from `walker.next` (for example an
/// `AccessDenied` deep inside a sub-tree we cannot enter) are swallowed:
/// the partial measure collected so far is still useful, and a single
/// unreadable sub-tree should never abort the whole scan.
fn measureDir(io: Io, dir: Dir, arena: Allocator, out: *Measure) anyerror!void {
    var walker = Dir.walkSelectively(dir, arena) catch return;
    defer walker.deinit();

    while (true) {
        const entry = walker.next(io) catch return;
        const unwrapped = entry orelse break;
        if (unwrapped.kind == .sym_link) continue;
        switch (unwrapped.kind) {
            .file => {
                // `unwrapped.dir` is the containing directory of each entry,
                // not the original root. Statting against the outer `dir`
                // would miss every nested file.
                const stat = unwrapped.dir.statFile(io, unwrapped.basename, .{}) catch continue;
                out.total_size += stat.size;
                const ns: i128 = stat.mtime.nanoseconds;
                if (ns > out.latest_ns) out.latest_ns = ns;
            },
            .directory => walker.enter(io, unwrapped) catch continue,
            else => continue,
        }
    }
}

test "analyze swallows unreadable sub-trees instead of aborting" {
    // Skip when running as root, because root bypasses mode bits.
    if (std.posix.geteuid() == 0) return;

    var env: std.Io.Threaded = .init;
    defer env.deinit();
    const io = env.ioBasic();

    const fixture_root = "/tmp/zca-analyzer-unreadable";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture_root) catch {};

    try cwd.makeDir(io, fixture_root);
    try cwd.makePath(io, fixture_root ++ "/.zig-cache/locked");
    try cwd.makePath(io, fixture_root ++ "/.zig-cache/open");
    {
        const dir = try cwd.openDir(io, fixture_root ++ "/.zig-cache/open", .{});
        defer dir.close(io);
        var file = try dir.openFile(io, "ok.txt", .{ .mode = .read_write });
        defer file.close(io);
        try file.writeStreamingAll(io, "fine");
    }
    try std.posix.chmod(fixture_root ++ "/.zig-cache/locked", 0o000);

    defer std.posix.chmod(fixture_root ++ "/.zig-cache/locked", 0o755) catch {};
    defer cwd.deleteTree(io, fixture_root) catch {};

    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();

    const pdir = try cwd.openDir(io, fixture_root, .{ .iterate = true });
    defer pdir.close(io);

    // Must NOT error: the analyzer should report only what it could read
    // and silently skip the locked sub-tree.
    const analysis = try analyze(io, pdir, fixture_root, arena);
    try std.testing.expectEqual(@as(usize, 1), analysis.artifact_paths.len);
    try std.testing.expect(analysis.total_size_bytes > 0);
}
