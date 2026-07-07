//! Multi-select TUI built on libvaxis. Mirrors cargo-clean-all's `-i`
//! behaviour: the user starts with the keep-filter preselection, can
//! toggle each project with Space, navigate with arrow keys, and
//! confirms with Enter. Pressing q or Esc cancels without running the
//! cleanup.

const std = @import("std");
const vaxis = @import("vaxis");
const Segment = vaxis.Segment;

const selection = @import("selection.zig");
const format = @import("format.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Key = vaxis.Key;

const AppEvent = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
};

pub const Result = struct {
    confirmed: bool,
};

/// Run the interactive multi-select screen. Mutates
/// `selections[i].selected` in place based on the user's toggles.
/// Returns whether the user confirmed or cancelled.
pub fn run(
    io: Io,
    env_map: *const std.process.Environ.Map,
    selections: []selection.Selection,
    gpa: Allocator,
) !Result {
    var buffer: [4096]u8 = undefined;
    var tty: vaxis.Tty = try .init(io, &buffer);
    defer tty.deinit();

    var vx = try vaxis.init(io, gpa, @constCast(env_map), .{});
    defer vx.deinit(gpa, tty.writer());

    var loop: vaxis.Loop(AppEvent) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));
    try vx.queryColor(tty.writer(), .fg);
    try vx.queryColor(tty.writer(), .bg);

    // Block until we have a window size - the screen render depends on it.
    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .winsize => |ws| {
                try vx.resize(gpa, tty.writer(), ws);
                break;
            },
            .key_press => {},
        }
    }

    // Strings allocated for a single frame must outlive the matching
    // vx.render call: the renderer compares screen_last[i].char.grapheme
    // (a pointer into last frame's text) against the current cell. If
    // we free the allocations immediately after printSegment, the
    // pointer dangles by the time render touches it. Hold every
    // per-frame allocation in this list and free them at the bottom of
    // the frame, just before the next iteration reuses the capacity.
    var frame_allocs: std.ArrayList([]u8) = .empty;
    defer {
        for (frame_allocs.items) |s| gpa.free(s);
        frame_allocs.deinit(gpa);
    }

    var cursor: usize = 0;
    var view_top: usize = 0;

    main: while (true) {
        // Drain pending events.
        while (try loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| {
                    if (key.matches('q', .{}) or
                        key.matchExact('c', .{ .ctrl = true }) or
                        key.matches(0x1b, .{}))
                    {
                        try vx.exitAltScreen(tty.writer());
                        return .{ .confirmed = false };
                    }
                    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
                        if (cursor + 1 < selections.len) cursor += 1;
                    } else if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
                        if (cursor > 0) cursor -= 1;
                    } else if (key.matches(' ', .{})) {
                        if (selections.len > 0) {
                            selections[cursor].selected = !selections[cursor].selected;
                        }
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        break :main;
                    }
                },
                .winsize => |ws| try vx.resize(gpa, tty.writer(), ws),
            }
        }

        // Drop previous frame's strings; the new frame will reuse the
        // list's capacity.
        for (frame_allocs.items) |s| gpa.free(s);
        frame_allocs.clearRetainingCapacity();

        const win = vx.window();
        win.clear();

        const win_height = win.height;
        const win_width = win.width;
        // Reserve 2 rows: header at top, footer at bottom.
        const list_rows: u16 = if (win_height > 2) win_height - 2 else 0;

        // Header.
        var sel_count: usize = 0;
        var will_free: u64 = 0;
        for (selections) |s| {
            if (s.selected) {
                sel_count += 1;
                will_free += s.analysis.total_size_bytes;
            }
        }
        var size_buf: [64]u8 = undefined;
        const size_str = size_buf[0..format.formatBytes(&size_buf, will_free)];

        const header = try std.fmt.allocPrint(
            gpa,
            "zig-clean-all  {d}/{d} selected  will free {s}",
            .{ sel_count, selections.len, size_str },
        );
        try frame_allocs.append(gpa, header);
        _ = win.printSegment(.{ .text = header }, .{ .row_offset = 0, .col_offset = 0, .wrap = .none });

        // Visible rows slice.
        if (cursor >= view_top + list_rows) view_top = cursor + 1 - list_rows;
        if (cursor < view_top) view_top = cursor;

        // Each row is rendered as a single Segment with wrap = .none.
        // The path is pre-truncated so the size column never wraps onto a
        // second visual row, and the truncation respects UTF-8 boundaries
        // so vaxis's grapheme iterator never sees a half-formed codepoint.
        var row: u16 = 1;
        var idx: usize = view_top;
        while (idx < selections.len and row - 1 < list_rows) : (idx += 1) {
            const is_cursor = idx == cursor;
            const s = selections[idx];
            const cursor_marker: u8 = if (is_cursor) '>' else ' ';
            const check: u8 = if (s.selected) 'x' else ' ';

            var size_buf2: [64]u8 = undefined;
            const size_text = size_buf2[0..format.formatBytes(&size_buf2, s.analysis.total_size_bytes)];

            const prefix = std.fmt.allocPrint(gpa, "{c} [{c}] ", .{ cursor_marker, check }) catch continue;
            try frame_allocs.append(gpa, prefix);

            // Reserve space for prefix + "  " + size_text + 1 char slack.
            const overhead: u16 = @intCast(prefix.len + 2 + size_text.len + 1);
            const path_budget: usize = if (win_width > overhead) win_width - overhead else 0;
            const path_display = truncatePath(gpa, s.project.path, path_budget) catch continue;
            try frame_allocs.append(gpa, path_display);

            const line = std.fmt.allocPrint(
                gpa,
                "{s}{s}  {s}",
                .{ prefix, path_display, size_text },
            ) catch continue;
            try frame_allocs.append(gpa, line);

            const seg: Segment = .{
                .text = line,
                .style = .{ .bold = is_cursor, .reverse = is_cursor },
            };
            _ = win.printSegment(seg, .{
                .row_offset = row,
                .col_offset = 0,
                .wrap = .none,
            });
            row += 1;
        }

        // Footer is a literal, no allocation needed.
        const footer = "[Space] toggle  [Enter] confirm  [j/k or arrows] move  [q] cancel";
        _ = win.printSegment(.{ .text = footer, .style = .{ .dim = true } }, .{
            .row_offset = if (win_height > 0) win_height - 1 else 0,
            .col_offset = 0,
            .wrap = .none,
        });

        try vx.render(tty.writer());
    }

    try vx.exitAltScreen(tty.writer());
    return .{ .confirmed = true };
}

/// Truncate `path` to fit within `budget` bytes. If the path is short
/// enough, it is returned unchanged (copied). Otherwise the tail is
/// replaced with "...". The truncation respects UTF-8 character
/// boundaries so vaxis's grapheme iterator never sees a partial
/// multi-byte sequence.
fn truncatePath(gpa: Allocator, path: []const u8, budget: usize) ![]u8 {
    if (path.len <= budget) return gpa.dupe(u8, path);
    if (budget < 3) return gpa.dupe(u8, "...");
    var keep = budget - 3;
    // Walk back over any UTF-8 continuation bytes (10xxxxxx) so we
    // don't slice in the middle of a multi-byte codepoint.
    while (keep > 0 and (path[keep] & 0xC0) == 0x80) : (keep -= 1) {}
    return std.fmt.allocPrint(gpa, "{s}...", .{path[0..keep]});
}
