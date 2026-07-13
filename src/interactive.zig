//! Inline TUI built on libvaxis. vaxis's full-screen renderer is bypassed:
//! we own the cursor and repaint the frame from the top of our allocated
//! block on every key press, then erase on exit so the caller's output
//! above stays visible.
//!
//! Long lists page: only `visible_rows` entries are drawn at a time and
//! `view_top` shifts to keep the cursor on screen.

const std = @import("std");
const vaxis = @import("vaxis");
const Selection = @import("selection.zig").Selection;
const format = @import("format.zig");

const HELP_LINES: u16 = 1;
const DEFAULT_SCREEN_ROWS: u16 = 24;

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

    var winsize: vaxis.Winsize = tty.getWinsize() catch .{
        .rows = DEFAULT_SCREEN_ROWS,
        .cols = 80,
        .x_pixel = 0,
        .y_pixel = 0,
    };

    const total: usize = selections.len;
    const visible_rows = computeVisibleRows(winsize.rows, total);
    const frame_height: u16 = @intCast(visible_rows + HELP_LINES);

    reserveFrame(tty.writer(), frame_height);

    var view_top: usize = 0;
    var cursor: usize = 0;
    var outcome: Outcome = .cancel;
    var running: bool = true;

    while (running) {
        renderFrame(tty.writer(), selections, view_top, visible_rows, cursor, total) catch return .cancel;

        const event = loop.nextEvent() catch break;
        switch (event) {
            .winsize => |ws| winsize = ws,
            .key_press => |k| running = handleKey(
                k,
                selections,
                total,
                visible_rows,
                &view_top,
                &cursor,
                &outcome,
            ),
            else => {},
        }
    }

    eraseFrame(tty.writer());

    vx.screen.deinit(gpa);
    vx.screen_last.deinit(gpa);
    if (vx.screen.cursor_secondary.len > 0)
        gpa.free(vx.screen.cursor_secondary);
    if (vx.state.prev_cursor_secondary.len > 0)
        gpa.free(vx.state.prev_cursor_secondary);

    // Stop the input thread before closing the tty. vaxis's Loop.stop
    // writes a DSR query and awaits the thread; both need a live fd.
    // Letting `loop.stop` run via the deferred `tty.deinit` order can
    // stall the shell's prompt-redraw window.
    loop.stop();

    tty.deinit();
    return outcome;
}

/// Number of entry rows that fit under the screen-height cap (one third
/// of the terminal, minus the help line). Floors at one so a tiny
/// terminal still shows something.
fn computeVisibleRows(screen_rows: u16, total: usize) usize {
    const raw_cap: usize = if (screen_rows >= 3)
        @as(usize, screen_rows) / 3
    else
        @as(usize, 2);
    const max_visible: usize = if (raw_cap > HELP_LINES) raw_cap - HELP_LINES else 1;
    return @max(@as(usize, 1), @min(total, max_visible));
}

/// Reserve `frame_height` rows for the TUI block, then save the cursor
/// (DECSC) at the top of the block so `renderFrame` can return via DECRC.
fn reserveFrame(w: *std.Io.Writer, frame_height: u16) void {
    var i: u16 = 0;
    while (i < frame_height) : (i += 1) {
        w.writeAll("\r\n") catch {};
    }
    w.print("\x1b[{d}A" ++ "\x1b7", .{frame_height}) catch {};
    w.flush() catch {};
}

/// Restore the frame anchor, erase below it, and reset terminal modes.
/// Best-effort: a closed pipe or detached tty may have lost its write end.
fn eraseFrame(w: *std.Io.Writer) void {
    w.writeAll("\x1b8") catch {}; // DECRC -> top of frame
    w.writeAll("\x1b[?7l") catch {}; // disable wrap (fzf pattern)
    w.writeAll(vaxis.ctlseqs.erase_below_cursor) catch {};
    w.writeAll(vaxis.ctlseqs.show_cursor) catch {};
    w.writeAll(vaxis.ctlseqs.sgr_reset) catch {};
    w.writeAll(vaxis.ctlseqs.bp_reset) catch {};
    w.writeAll("\x1b[?7h") catch {}; // re-enable wrap
    w.flush() catch {};
}

fn handleKey(
    k: vaxis.Key,
    selections: []Selection,
    total: usize,
    visible_rows: usize,
    view_top: *usize,
    cursor: *usize,
    outcome: *Outcome,
) bool {
    switch (k.codepoint) {
        vaxis.Key.up => {
            if (cursor.* > 0) cursor.* -= 1;
        },
        vaxis.Key.down => {
            if (cursor.* + 1 < total) cursor.* += 1;
        },
        vaxis.Key.page_up => pageUp(view_top, cursor, visible_rows),
        vaxis.Key.page_down => pageDown(view_top, cursor, visible_rows, total),
        vaxis.Key.home => {
            view_top.* = 0;
            cursor.* = 0;
        },
        vaxis.Key.end => {
            cursor.* = total - 1;
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
    adjustView(view_top, cursor.*, visible_rows, total);
    return true;
}

/// Scroll one screen forward and anchor the cursor at the top of the new
/// view; on the final page jump it to the last entry. No-op when the view
/// is already at the end.
fn pageDown(view_top: *usize, cursor: *usize, visible_rows: usize, total: usize) void {
    const max_top = if (total > visible_rows) total - visible_rows else 0;
    const new_top = @min(view_top.* + visible_rows, max_top);
    view_top.* = new_top;
    cursor.* = if (new_top + visible_rows >= total) total - 1 else new_top;
}

/// Scroll one screen backward and anchor the cursor at the top of the new
/// view; on the first page jump it to the first entry. No-op when the view
/// is already at the top.
fn pageUp(view_top: *usize, cursor: *usize, visible_rows: usize) void {
    const new_top = if (view_top.* >= visible_rows) view_top.* - visible_rows else 0;
    view_top.* = new_top;
    cursor.* = if (new_top == 0) 0 else new_top;
}

/// Slide the view so the cursor stays inside `[view_top, view_top+visible)`.
/// Call after every operation that moves the cursor.
fn adjustView(view_top: *usize, cursor: usize, visible_rows: usize, total: usize) void {
    const max_top = if (total > visible_rows) total - visible_rows else 0;
    if (cursor < view_top.*) {
        view_top.* = cursor;
    } else if (cursor >= view_top.* + visible_rows) {
        view_top.* = cursor + 1 - visible_rows;
    }
    if (view_top.* > max_top) view_top.* = max_top;
}

fn renderFrame(
    w: *std.Io.Writer,
    selections: []Selection,
    view_top: usize,
    visible_rows: usize,
    cursor: usize,
    total: usize,
) !void {
    // DECRC returns to the position captured by DECSC in `run` (the top
    // of the frame), so the frame never drifts onto the caller's output.
    try w.writeAll("\x1b8");
    try w.writeAll(vaxis.ctlseqs.erase_below_cursor);
    try w.writeAll(vaxis.ctlseqs.hide_cursor);

    var i: usize = 0;
    while (i < visible_rows and view_top + i < total) : (i += 1) {
        const idx = view_top + i;
        const s = selections[idx];
        const marker: []const u8 = if (s.selected) "[CLEAN]" else "[KEEP] ";
        var size_buf: [32]u8 = undefined;
        const size_str = size_buf[0..format.formatBytes(&size_buf, s.item.analysis.total_size_bytes)];
        if (idx == cursor) try w.writeAll(vaxis.ctlseqs.reverse_set);
        try w.print(" {s} {s}  {s}\r\n", .{ marker, s.item.project.path, size_str });
        if (idx == cursor) try w.writeAll(vaxis.ctlseqs.sgr_reset);
    }

    if (total > visible_rows) {
        try w.print(
            " [space] toggle  [a] all  [n] none  [up/down] move  [pgup/pgdn] page  [enter] confirm  [q] cancel  ({d}/{d})",
            .{ cursor + 1, total },
        );
    } else {
        try w.print(
            " [space] toggle  [a] all  [n] none  [up/down] move  [enter] confirm  [q] cancel",
            .{},
        );
    }
    try w.writeAll(vaxis.ctlseqs.show_cursor);
    try w.flush();
}

test "computeVisibleRows caps at one third of screen height" {
    try std.testing.expectEqual(@as(usize, 1), computeVisibleRows(6, 100));
    try std.testing.expectEqual(@as(usize, 1), computeVisibleRows(2, 100));
    try std.testing.expectEqual(@as(usize, 1), computeVisibleRows(1, 100));
    try std.testing.expectEqual(@as(usize, 1), computeVisibleRows(0, 100));
    try std.testing.expectEqual(@as(usize, 2), computeVisibleRows(10, 100));
    try std.testing.expectEqual(@as(usize, 2), computeVisibleRows(10, 3));
    try std.testing.expectEqual(@as(usize, 2), computeVisibleRows(10, 2));
    try std.testing.expectEqual(@as(usize, 7), computeVisibleRows(24, 100));
    try std.testing.expectEqual(@as(usize, 5), computeVisibleRows(24, 5));
    try std.testing.expectEqual(@as(usize, 1), computeVisibleRows(24, 1));
}

test "adjustView keeps cursor in the visible window" {
    var view_top: usize = 0;
    adjustView(&view_top, 0, 5, 20);
    try std.testing.expectEqual(@as(usize, 0), view_top);

    adjustView(&view_top, 10, 5, 20);
    try std.testing.expectEqual(@as(usize, 6), view_top);

    adjustView(&view_top, 6, 5, 20);
    try std.testing.expectEqual(@as(usize, 6), view_top);

    adjustView(&view_top, 2, 5, 20);
    try std.testing.expectEqual(@as(usize, 2), view_top);

    // Cursor at end: view should clamp so cursor is visible.
    adjustView(&view_top, 19, 5, 20);
    try std.testing.expectEqual(@as(usize, 15), view_top);
}

test "pageDown advances by one visible page" {
    var view_top: usize = 0;
    var cursor: usize = 0;
    pageDown(&view_top, &cursor, 5, 20);
    try std.testing.expectEqual(@as(usize, 5), view_top);
    try std.testing.expectEqual(@as(usize, 5), cursor);

    pageDown(&view_top, &cursor, 5, 20);
    try std.testing.expectEqual(@as(usize, 10), view_top);
    try std.testing.expectEqual(@as(usize, 10), cursor);

    // Past the end clamps to the last entry / last page.
    pageDown(&view_top, &cursor, 5, 20);
    try std.testing.expectEqual(@as(usize, 15), view_top);
    try std.testing.expectEqual(@as(usize, 19), cursor);

    pageDown(&view_top, &cursor, 5, 20);
    try std.testing.expectEqual(@as(usize, 15), view_top);
    try std.testing.expectEqual(@as(usize, 19), cursor);
}

test "pageUp retreats by one visible page" {
    var view_top: usize = 15;
    var cursor: usize = 19;
    pageUp(&view_top, &cursor, 5);
    try std.testing.expectEqual(@as(usize, 10), view_top);
    try std.testing.expectEqual(@as(usize, 10), cursor);

    pageUp(&view_top, &cursor, 5);
    try std.testing.expectEqual(@as(usize, 5), view_top);
    try std.testing.expectEqual(@as(usize, 5), cursor);

    pageUp(&view_top, &cursor, 5);
    try std.testing.expectEqual(@as(usize, 0), view_top);
    try std.testing.expectEqual(@as(usize, 0), cursor);

    pageUp(&view_top, &cursor, 5);
    try std.testing.expectEqual(@as(usize, 0), view_top);
    try std.testing.expectEqual(@as(usize, 0), cursor);
}

test "paging is a no-op when everything fits" {
    var view_top: usize = 0;
    var cursor: usize = 0;
    pageDown(&view_top, &cursor, 5, 3);
    try std.testing.expectEqual(@as(usize, 0), view_top);
    try std.testing.expectEqual(@as(usize, 2), cursor);

    pageUp(&view_top, &cursor, 5);
    try std.testing.expectEqual(@as(usize, 0), view_top);
    try std.testing.expectEqual(@as(usize, 0), cursor);
}
