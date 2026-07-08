//! Measures a project's build artifacts so the caller can decide whether
//! to wipe them.
//!
//! "Artifacts" for a Zig project are `.zig-cache`, `zig-out`, and `zig-pkg`.
//! The analyzer walks each one that exists, sums the bytes, and records the
//! most recent modification time found in any descendant. Symlinks are not
//! followed - they would invite both cycles and double-counting.

const std = @import("std");
const builtin = @import("builtin");
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

    const abs = try std.fs.path.join(arena, &.{ project_path, name });
    try found.append(arena, abs);
    try measureDir(io, sub, arena, out);
}

const Measure = struct {
    total_size: u64,
    latest_ns: i128,

    const zero: Measure = .{ .total_size = 0, .latest_ns = 0 };
};

/// Best-effort chmod used by fixture setup. `std.os.linux.chmod` returns a
/// raw syscall result, so wrap it and swallow any error so the test
/// continues even when the kernel refuses (for example in a sandbox).
fn chmodOrSkip(raw_path: []const u8, mode: u32) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z_path = std.fmt.bufPrintZ(&buf, "{s}", .{raw_path}) catch return;
    _ = std.os.linux.chmod(z_path, mode);
}

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
        const next_result = walker.next(io) catch break;
        const entry = next_result orelse break;
        if (entry.kind == .sym_link) continue;
        switch (entry.kind) {
            .file => {
                // `entry.dir` is the containing directory of each entry,
                // not the original root. Statting against the outer `dir`
                // would miss every nested file.
                const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
                out.total_size += stat.size;
                const ns: i128 = stat.mtime.nanoseconds;
                if (ns > out.latest_ns) out.latest_ns = ns;
            },
            .directory => walker.enter(io, entry) catch continue,
            else => continue,
        }
    }
}

test "analyze swallows unreadable sub-trees instead of aborting" {
    // Skip when running as root, because root bypasses mode bits.
    if (builtin.os.tag != .linux) return;
    if (std.os.linux.geteuid() == 0) return;

    var env = std.Io.Threaded.init(std.testing.allocator, .{});
    defer env.deinit();
    const io = env.io();

    const fixture_root = "/tmp/zca-analyzer-unreadable";
    const cwd = Dir.cwd();
    cwd.deleteTree(io, fixture_root) catch {};

    try cwd.createDir(io, fixture_root, .default_dir);
    try cwd.createDirPath(io, fixture_root ++ "/.zig-cache/locked");
    try cwd.createDirPath(io, fixture_root ++ "/.zig-cache/open");
    {
        const dir = try cwd.openDir(io, fixture_root ++ "/.zig-cache/open", .{});
        defer dir.close(io);
        var file = try dir.createFile(io, "ok.txt", .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "fine");
    }
    chmodOrSkip(fixture_root ++ "/.zig-cache/locked", 0o000);

    // Defers run in reverse: restore permissions first so the recursive
    // deleteTree below can actually traverse the locked sub-tree.
    defer cwd.deleteTree(io, fixture_root) catch {};
    defer chmodOrSkip(fixture_root ++ "/.zig-cache/locked", 0o755);

    var arena_buf: [65536]u8 = undefined;
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
