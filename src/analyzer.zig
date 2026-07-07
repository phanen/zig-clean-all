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

/// Open `project_path` and measure its build artifacts. The caller is
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

    var idx: usize = 0;
    while (idx < ARTIFACT_NAMES.len) : (idx += 1) {
        const name = ARTIFACT_NAMES[idx];
        // `openDir` swallows most errors via the vtable; missing dirs surface
        // as `FileNotFound` which we treat as "no artifact here".
        const sub = project_dir.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        var closed = false;
        defer if (!closed) sub.close(io);

        const abs = try path.join(arena, &.{ project_path, name });
        try found.append(arena, abs);

        var measure: Measure = .{ .total_size = 0, .latest_ns = 0 };
        try measureDir(io, sub, arena, &measure);
        sub.close(io);
        closed = true;

        total_size += measure.total_size;
        if (measure.latest_ns > latest_ns) latest_ns = measure.latest_ns;
    }

    return .{
        .artifact_paths = try found.toOwnedSlice(arena),
        .total_size_bytes = total_size,
        .last_modified_ns = latest_ns,
    };
}

const Measure = struct {
    total_size: u64,
    latest_ns: i128,
};

/// Recursive visitor that counts bytes and tracks the maximum mtime. The
/// walker deliberately stops at symlinks to avoid loops and double counting.
/// `arena` backs the walker's internal stack so callers don't need a
/// long-lived allocator for the duration of the measurement.
fn measureDir(io: Io, dir: Dir, arena: Allocator, out: *Measure) anyerror!void {
    var walker = try Dir.walkSelectively(dir, arena);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .sym_link) continue;
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(io, entry.basename, .{}) catch continue;
                out.total_size += stat.size;
                const ns: i128 = stat.mtime.nanoseconds;
                if (ns > out.latest_ns) out.latest_ns = ns;
            },
            .directory => try walker.enter(io, entry),
            else => continue,
        }
    }
}
