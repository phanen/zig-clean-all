//! Multi-select TUI built on libvaxis. Mirrors cargo-clean-all's `-i`
//! behaviour: the user starts with the keep-filter preselection, can
//! toggle each project with Space, navigate with arrow keys, and
//! confirms with Enter. Pressing q or Esc cancels without running the
//! cleanup.

const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const Segment = vaxis.Segment;
const Style = vaxis.Style;

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
    /// null = user cancelled (q or Esc).
    confirmed: bool,
};

/// Run the interactive multi-select screen. Mutates `selections[i].selected`
/// in place based on the user's toggles. Returns whether the user
/// confirmed or cancelled.
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

        // Draw.
        const win = vx.window();
        win.clear();

        const win_height = win.height;
        // Reserve 2 rows: header + footer.
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

        const header = std.fmt.allocPrint(gpa, "zig-clean-all  {d}/{d} selected  will free {s}", .{
            sel_count,
            selections.len,
            size_str,
        }) catch "zig-clean-all";
        defer if (!std.mem.eql(u8, header, "zig-clean-all")) gpa.free(header);

        _ = win.printSegment(.{ .text = header }, .{ .row_offset = 0, .col_offset = 0, .wrap = .grapheme });

        // Visible rows slice.
        if (cursor >= view_top + list_rows) view_top = cursor + 1 - list_rows;
        if (cursor < view_top) view_top = cursor;

        var row: u16 = 1;
        var idx: usize = view_top;
        while (idx < selections.len and row - 1 < list_rows) : (idx += 1) {
            const is_cursor = idx == cursor;
            const s = selections[idx];
            const marker: u8 = if (s.selected) 'x' else ' ';
            const cursor_marker: u8 = if (is_cursor) '>' else ' ';

            var size_buf2: [64]u8 = undefined;
            const size_text = size_buf2[0..format.formatBytes(&size_buf2, s.analysis.total_size_bytes)];

            const line = std.fmt.allocPrint(gpa, "{c} [{c}] {s}  {s}", .{
                cursor_marker,
                marker,
                s.project.path,
                size_text,
            }) catch return error.OutOfMemory;
            defer gpa.free(line);

            const seg: Segment = .{
                .text = line,
                .style = .{ .bold = is_cursor, .reverse = is_cursor },
            };
            _ = win.printSegment(seg, .{ .row_offset = row, .col_offset = 0, .wrap = .grapheme });
            row += 1;
        }

        // Footer.
        const footer = "[Space] toggle  [Enter] confirm  [j/k or arrows] move  [q] cancel";
        _ = win.printSegment(.{ .text = footer, .style = .{ .dim = true } }, .{
            .row_offset = win_height -| 1,
            .col_offset = 0,
            .wrap = .grapheme,
        });

        try vx.render(tty.writer());
    }

    try vx.exitAltScreen(tty.writer());
    return .{ .confirmed = true };
}