//! Human-readable formatting for byte sizes and unix nanosecond timestamps.
//! Functions write into caller-provided buffers to keep allocation patterns
//! predictable.

const std = @import("std");

const NS_PER_S: i128 = 1_000_000_000;
const SECS_PER_MIN: i128 = 60;
const SECS_PER_HOUR: i128 = 3600;
const SECS_PER_DAY: i128 = 86_400;
const DAYS_PER_ERA: i128 = 146_097;
const DAYS_PER_4Y: i128 = 1460;
const DAYS_PER_100Y: i128 = 36_524;
const DAYS_PER_400Y: i128 = 146_096;

/// Render `bytes` as a short decimal string like "1.5 GB" or "938 B".
/// SI (1000-based) units. Returns the number of bytes written.
pub fn formatBytes(buf: []u8, bytes: u64) usize {
    if (bytes < 1000) {
        return (std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch return 0).len;
    }
    const value_f: f64 = @floatFromInt(bytes);
    if (value_f < 1_000_000) {
        return (std.fmt.bufPrint(buf, "{d:.1} kB", .{value_f / 1000}) catch return 0).len;
    }
    if (value_f < 1_000_000_000) {
        return (std.fmt.bufPrint(buf, "{d:.1} MB", .{value_f / 1_000_000}) catch return 0).len;
    }
    if (value_f < 1_000_000_000_000) {
        return (std.fmt.bufPrint(buf, "{d:.2} GB", .{value_f / 1_000_000_000}) catch return 0).len;
    }
    return (std.fmt.bufPrint(buf, "{d:.2} TB", .{value_f / 1_000_000_000_000}) catch return 0).len;
}

/// Render Unix-epoch nanoseconds as "YYYY-MM-DD HH:MM" in UTC. Returns
/// bytes written; 0 on overflow.
pub fn formatTimestamp(buf: []u8, nanoseconds: i128) usize {
    if (nanoseconds <= 0) return (std.fmt.bufPrint(buf, "never", .{}) catch return 0).len;

    var secs: i128 = @divTrunc(nanoseconds, NS_PER_S);
    if (secs < 0) secs = 0;

    // Howard Hinnant's days_from_civil; the offset translates the Unix
    // epoch into the civil-from-days epoch (0000-03-01) the algorithm
    // expects.
    const CIVIL_EPOCH_OFFSET: i128 = 719_468;
    const z: i128 = @divTrunc(secs, SECS_PER_DAY) + CIVIL_EPOCH_OFFSET;
    const secs_of_day: i128 = @mod(secs, SECS_PER_DAY);
    const era: i128 = if (z >= 0) @divFloor(z, DAYS_PER_ERA) else @divFloor(z - DAYS_PER_400Y, DAYS_PER_ERA);
    const doe: i128 = z - era * DAYS_PER_ERA;
    const yoe: i128 = @divFloor(doe - @divFloor(doe, DAYS_PER_4Y) + @divFloor(doe, DAYS_PER_100Y) - @divFloor(doe, DAYS_PER_400Y), 365);
    const y: i128 = yoe + era * 400;
    const doy: i128 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i128 = @divFloor(5 * doy + 2, 153);
    const d: i128 = doy - @divFloor(153 * mp + 2, 5) + 1;
    const m: i128 = if (mp < 10) mp + 3 else mp - 9;
    const year: i128 = if (m <= 2) y + 1 else y;
    const hour: i128 = @divFloor(secs_of_day, SECS_PER_HOUR);
    const min: i128 = @divFloor(@mod(secs_of_day, SECS_PER_HOUR), SECS_PER_MIN);

    return (std.fmt.bufPrint(
        buf,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}",
        .{
            @as(u64, @intCast(year)),
            @as(u64, @intCast(m)),
            @as(u64, @intCast(d)),
            @as(u64, @intCast(hour)),
            @as(u64, @intCast(min)),
        },
    ) catch return 0).len;
}

test "formatBytes uses sensible units" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", buf[0..formatBytes(&buf, 0)]);
    try std.testing.expectEqualStrings("938 B", buf[0..formatBytes(&buf, 938)]);
    try std.testing.expectEqualStrings("1.0 kB", buf[0..formatBytes(&buf, 1000)]);
    try std.testing.expectEqualStrings("10.0 MB", buf[0..formatBytes(&buf, 10_000_000)]);
    try std.testing.expectEqualStrings("1.50 GB", buf[0..formatBytes(&buf, 1_500_000_000)]);
}

test "formatTimestamp renders a known epoch" {
    var buf: [32]u8 = undefined;
    const rendered = buf[0..formatTimestamp(&buf, 1704067200 * NS_PER_S)];
    try std.testing.expectEqualStrings("2024-01-01 00:00", rendered);
}
