//! Inline TUI built on libvaxis's Tty (raw mode) and Loop (event queue).
//!
//! vaxis's full-screen render is bypassed: we own the cursor position and
//! repaint the frame from the top of our allocated block on every key press.
//! On exit we move the cursor back to the top of the frame and erase, so
//! the caller's earlier output above stays visible.

const std = @import("std");
const vaxis = @import("vaxis");
const Selection = @import("selection.zig").Selection;
const format = @import("format.zig");

const AppEvent = union(enum) {
    winsize: vaxis.Winsize,
    key_press: vaxis.Key,
    key_release: vaxis.Key,
};

pub const Outcome = enum { confirm, cancel };

pub fn run(
    io: std.Io,
    env_map: *const std.process.Environ.Map,
    selections_const: []const Selection,
    gpa: std.mem.Allocator,
) !Outcome {
    if (selections_const.len == 0) return .confirm;

    const selections: []Selection = @constCast(selections_const);

    var tty_buf: [4096]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &tty_buf);

    var vx = try vaxis.Vaxis.init(io, gpa, @constCast(env_map), .{});

    var loop: vaxis.Loop(AppEvent) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    const frame_height: u16 = @intCast(selections.len + 1);

    // Reserve rows for the frame so it has its own block below the caller's
    // summary line, then save the cursor (DECSC) at the top of the frame
    // so renderFrame can restore it via DECRC and never touch any output
    // above.
    {
        const w = tty.writer();
        var i: u16 = 0;
        while (i < frame_height) : (i += 1) {
            w.writeAll("\r\n") catch {};
        }
        // Move cursor back to the top of the reserved block and save it.
        w.print("\x1b[{d}A" ++ "\x1b7", .{frame_height}) catch {};
        w.flush() catch {};
    }

    var cursor: usize = 0;
    var outcome: Outcome = .cancel;
    var running: bool = true;

    while (running) {
        renderFrame(tty.writer(), selections, cursor) catch return .cancel;

        const event = loop.nextEvent() catch break;
        switch (event) {
            .key_press => |k| running = handleKey(k, selections, &cursor, &outcome),
            else => {},
        }
    }

    // Erase the frame and return the cursor to the row above it.
    tty.writer().writeAll("\x1b8") catch {}; // DECRC -> top of frame
    tty.writer().writeAll(vaxis.ctlseqs.erase_below_cursor) catch {};
    tty.writer().flush() catch {};

    vx.screen.deinit(gpa);
    vx.screen_last.deinit(gpa);
    if (vx.screen.cursor_secondary.len > 0)
        gpa.free(vx.screen.cursor_secondary);
    if (vx.state.prev_cursor_secondary.len > 0)
        gpa.free(vx.state.prev_cursor_secondary);

    tty.deinit();
    return outcome;
}

fn handleKey(
    k: vaxis.Key,
    selections: []Selection,
    cursor: *usize,
    outcome: *Outcome,
) bool {
    switch (k.codepoint) {
        vaxis.Key.up => {
            if (cursor.* > 0) cursor.* -= 1;
        },
        vaxis.Key.down => {
            if (cursor.* + 1 < selections.len) cursor.* += 1;
        },
        vaxis.Key.space => {
            const s: *Selection = &selections[cursor.*];
            s.selected = !s.selected;
        },
        vaxis.Key.enter => {
            outcome.* = .confirm;
            return false;
        },
        vaxis.Key.escape => {
            outcome.* = .cancel;
            return false;
        },
        'a' => {
            for (selections) |*s| s.selected = true;
        },
        'n' => {
            for (selections) |*s| s.selected = false;
        },
        'q' => {
            outcome.* = .cancel;
            return false;
        },
        else => {},
    }
    return true;
}

fn renderFrame(
    w: *std.Io.Writer,
    selections: []Selection,
    cursor: usize,
) !void {
    // DECRC restores the cursor to the position captured by DECSC in `run`,
    // which is the top of the frame. From there we erase everything below
    // and paint the rows in place. This anchors the frame so it can never
    // drift onto the caller's earlier output.
    try w.writeAll("\x1b8"); // DECRC
    try w.writeAll(vaxis.ctlseqs.erase_below_cursor);
    try w.writeAll(vaxis.ctlseqs.hide_cursor);

    for (selections, 0..) |s, i| {
        const marker: []const u8 = if (s.selected) "[CLEAN]" else "[KEEP] ";
        var size_buf: [32]u8 = undefined;
        const size_str = size_buf[0..format.formatBytes(&size_buf, s.analysis.total_size_bytes)];
        if (i == cursor) try w.writeAll(vaxis.ctlseqs.reverse_set);
        try w.print(" {s} {s}  {s}\r\n", .{ marker, s.project.path, size_str });
        if (i == cursor) try w.writeAll(vaxis.ctlseqs.sgr_reset);
    }

    try w.print(" [space] toggle  [a] all  [n] none  [\u{2191}\u{2193}] move  [enter] confirm  [q] cancel", .{});
    try w.writeAll(vaxis.ctlseqs.show_cursor);
    try w.flush();
}
