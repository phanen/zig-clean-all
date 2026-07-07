//! Inline multi-select prompt.
//!
//! Mirrors cargo-clean-all's -i ergonomics without an alt-screen TUI:
//! after the standard "[CLEAN]/[KEEP]" listing prints, the user is
//! dropped into a small command loop in the same terminal buffer.
//! They can flip individual rows by number, toggle ranges, flip
//! everything, or confirm with a blank line. Pressing `q` cancels.
//!
//! The frame is rewritten in place after each command via
//! `\x1b[<n>A` (cursor up) + `\x1b[J` (clear to bottom of screen),
//! so the prompt stays anchored at the bottom of the terminal and
//! the user can scroll back through their earlier scan output.

const std = @import("std");

const selection = @import("selection.zig");
const format = @import("format.zig");

const Io = std.Io;

pub const Result = struct {
    confirmed: bool,
};

const PROMPT =
    \\toggle (e.g. "1 3 5", "1-3", "a"/"n"; ENTER ok, q cancel):
;

/// Run the inline multi-select loop. Mutates `selections[i].selected`
/// in place. Returns whether the user confirmed or cancelled.
pub fn run(io: Io, selections: []selection.Selection) !Result {
    var buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(io, &buf);

    // Frame height = one line per project + a blank separator + the
    // prompt line. We add one more line for the trailing newline
    // that `\n` writes after the prompt so the cursor lands at the
    // bottom of the frame when the user types.
    const frame_height: u16 = @intCast(selections.len + 3);

    try drawFrame(&out_w.interface, selections);
    try out_w.interface.flush();

    while (true) {
        var stdin = std.Io.File.stdin();
        var in_r = stdin.reader(io, &buf);
        const n = in_r.interface.readSliceShort(&buf) catch return .{ .confirmed = false };
        if (n == 0) return .{ .confirmed = true };
        const raw = buf[0..n];
        const line = std.mem.trim(u8, raw, " \t\r\n");

        if (line.len == 0) return .{ .confirmed = true };
        if (std.ascii.eqlIgnoreCase(line, "q")) return .{ .confirmed = false };
        if (std.ascii.eqlIgnoreCase(line, "a")) {
            for (selections) |*s| s.selected = true;
        } else if (std.ascii.eqlIgnoreCase(line, "n")) {
            for (selections) |*s| s.selected = false;
        } else {
            applyToggle(selections, line);
        }

        // Move cursor back to the top of the frame and erase
        // everything from there to the bottom of the screen, then
        // redraw with the updated toggles.
        try out_w.interface.print("\x1b[{d}A\x1b[J", .{frame_height});
        try drawFrame(&out_w.interface, selections);
        try out_w.interface.flush();
    }
}

fn drawFrame(w: anytype, selections: []const selection.Selection) !void {
    for (selections, 1..) |s, idx| {
        const marker: u8 = if (s.selected) 'x' else ' ';
        var size_buf: [64]u8 = undefined;
        const size_text = size_buf[0..format.formatBytes(&size_buf, s.analysis.total_size_bytes)];
        try w.print("  [{c}] {d:2}. {s}  {s}\n", .{
            marker,
            idx,
            s.project.path,
            size_text,
        });
    }
    try w.writeAll("\n");
    try w.writeAll(PROMPT);
}

/// Parse a command like "1 3 5" or "1-3 7" and toggle the matching
/// 1-based indices in `selections`. Tokens that don't parse as
/// positive integers (or as `<n>-<m>` ranges) are silently ignored,
/// so a stray typo doesn't kill the session.
fn applyToggle(selections: []selection.Selection, line: []const u8) void {
    var it = std.mem.tokenizeAny(u8, line, " \t,");
    while (it.next()) |tok| {
        if (std.mem.indexOfScalar(u8, tok, '-')) |dash| {
            const a = std.fmt.parseInt(usize, tok[0..dash], 10) catch continue;
            const b = std.fmt.parseInt(usize, tok[dash + 1 ..], 10) catch continue;
            const lo = @min(a, b);
            const hi = @max(a, b);
            var k: usize = lo;
            while (k <= hi) : (k += 1) {
                if (k >= 1 and k <= selections.len) {
                    selections[k - 1].selected = !selections[k - 1].selected;
                }
            }
        } else {
            const n = std.fmt.parseInt(usize, tok, 10) catch continue;
            if (n >= 1 and n <= selections.len) {
                selections[n - 1].selected = !selections[n - 1].selected;
            }
        }
    }
}

test "applyToggle flips individual indices" {
    var sel: [3]selection.Selection = .{
        .{ .project = .{ .path = "/a" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
        .{ .project = .{ .path = "/b" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
        .{ .project = .{ .path = "/c" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
    };
    applyToggle(&sel, "1 3");
    try std.testing.expect(sel[0].selected);
    try std.testing.expect(!sel[1].selected);
    try std.testing.expect(sel[2].selected);
}

test "applyToggle flips ranges" {
    var sel: [4]selection.Selection = .{
        .{ .project = .{ .path = "/a" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
        .{ .project = .{ .path = "/b" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
        .{ .project = .{ .path = "/c" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
        .{ .project = .{ .path = "/d" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
    };
    applyToggle(&sel, "1-3");
    try std.testing.expect(sel[0].selected);
    try std.testing.expect(sel[1].selected);
    try std.testing.expect(sel[2].selected);
    try std.testing.expect(!sel[3].selected);
}

test "applyToggle ignores out-of-range and unparseable tokens" {
    var sel: [2]selection.Selection = .{
        .{ .project = .{ .path = "/a" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
        .{ .project = .{ .path = "/b" }, .analysis = .{ .artifact_paths = &.{}, .total_size_bytes = 0, .last_modified_ns = 0 }, .keep = false, .selected = false },
    };
    applyToggle(&sel, "99 abc 0");
    try std.testing.expect(!sel[0].selected);
    try std.testing.expect(!sel[1].selected);
}
