//! CLI argument parsing for zig-clean-all.
//!
//! Owns no allocations of its own: the caller supplies an arena that backs
//! the slices in `Cli` (notably `ignore_paths` and `skip_paths`). Parsing is
//! total and returns `error.InvalidArgument` (or friends) on failure.

const std = @import("std");
const mem = std.mem;

const Allocator = mem.Allocator;

pub const Cli = struct {
    root_dir: []const u8 = ".",
    yes: bool = false,
    keep_size_bytes: u64 = 0,
    keep_days: u32 = 0,
    dry_run: bool = false,
    ignore_paths: []const []const u8 = &.{},
    skip_paths: []const []const u8 = &.{},
    keep_empty: bool = false,
    show_summary: bool = true,
    interactive: bool = false,
    /// Number of worker threads to use for the parallel scanner. `0` means
    /// auto-select based on CPU count.
    threads: u32 = 0,
};

pub const ParseError = error{
    InvalidArgument,
    UnknownFlag,
    MissingValue,
    OutOfMemory,
};

pub const HelpOrVersion = enum { neither, help, version };

const Suffix = struct {
    text: []const u8,
    multiplier: u64,
};

const SIZE_SUFFIXES: []const Suffix = &.{
    .{ .text = "B", .multiplier = 1 },
    .{ .text = "kB", .multiplier = 1_000 },
    .{ .text = "MB", .multiplier = 1_000_000 },
    .{ .text = "GB", .multiplier = 1_000_000_000 },
    .{ .text = "TB", .multiplier = 1_000_000_000_000 },
    .{ .text = "KiB", .multiplier = 1024 },
    .{ .text = "MiB", .multiplier = 1024 * 1024 },
    .{ .text = "GiB", .multiplier = 1024 * 1024 * 1024 },
    .{ .text = "TiB", .multiplier = 1024 * 1024 * 1024 * 1024 },
};

/// Parse argv (without the program name). Returns the populated `Cli` plus
/// a `HelpOrVersion` if `--help`/`-h`/`--version` was seen.
pub fn parse(
    arena: Allocator,
    argv: []const []const u8,
) ParseError!struct { Cli, HelpOrVersion } {
    var cli: Cli = .{};
    var ignore_list: std.ArrayList([]const u8) = .empty;
    var skip_list: std.ArrayList([]const u8) = .empty;
    var help_version: HelpOrVersion = .neither;

    var i: usize = 0;
    var stop_flags = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (stop_flags) {
            cli.root_dir = arg;
            break;
        }
        if (mem.eql(u8, arg, "--")) {
            stop_flags = true;
            continue;
        }

        if (mem.startsWith(u8, arg, "--")) {
            const stripped = arg[2..];
            if (mem.eql(u8, stripped, "yes")) {
                cli.yes = true;
            } else if (mem.eql(u8, stripped, "dry-run")) {
                cli.dry_run = true;
            } else if (mem.eql(u8, stripped, "keep-empty")) {
                cli.keep_empty = true;
            } else if (mem.eql(u8, stripped, "no-summary")) {
                cli.show_summary = false;
            } else if (mem.eql(u8, stripped, "interactive")) {
                cli.interactive = true;
            } else if (mem.eql(u8, stripped, "help")) {
                help_version = .help;
            } else if (mem.eql(u8, stripped, "version")) {
                help_version = .version;
            } else if (mem.eql(u8, stripped, "ignore")) {
                try ignore_list.append(arena, try consumeValue(argv, &i));
            } else if (mem.eql(u8, stripped, "skip")) {
                try skip_list.append(arena, try consumeValue(argv, &i));
            } else if (mem.startsWith(u8, stripped, "keep-size=")) {
                cli.keep_size_bytes = try parseBytes(stripped["keep-size=".len..]);
            } else if (mem.eql(u8, stripped, "keep-size")) {
                cli.keep_size_bytes = try parseBytes(try consumeValue(argv, &i));
            } else if (mem.startsWith(u8, stripped, "keep-days=")) {
                cli.keep_days = try parseU32(stripped["keep-days=".len..]);
            } else if (mem.eql(u8, stripped, "keep-days")) {
                cli.keep_days = try parseU32(try consumeValue(argv, &i));
            } else if (mem.startsWith(u8, stripped, "threads=")) {
                cli.threads = try parseU32(stripped["threads=".len..]);
            } else if (mem.eql(u8, stripped, "threads")) {
                cli.threads = try parseU32(try consumeValue(argv, &i));
            } else {
                return ParseError.UnknownFlag;
            }
            continue;
        }

        if (arg.len > 1 and arg[0] == '-') {
            const flag = arg[1..];
            if (mem.eql(u8, flag, "y")) {
                cli.yes = true;
            } else if (mem.eql(u8, flag, "s")) {
                cli.keep_size_bytes = try parseBytes(try consumeValue(argv, &i));
            } else if (mem.eql(u8, flag, "d")) {
                cli.keep_days = try parseU32(try consumeValue(argv, &i));
            } else if (mem.eql(u8, flag, "i")) {
                cli.interactive = true;
            } else if (mem.eql(u8, flag, "h")) {
                help_version = .help;
            } else if (mem.eql(u8, flag, "t")) {
                cli.threads = try parseU32(try consumeValue(argv, &i));
            } else {
                return ParseError.UnknownFlag;
            }
            continue;
        }

        // Positional argument: directory.
        cli.root_dir = arg;
        break;
    }

    cli.ignore_paths = try ignore_list.toOwnedSlice(arena);
    cli.skip_paths = try skip_list.toOwnedSlice(arena);

    return .{ cli, help_version };
}

/// Read the next argv slot, advancing `i` past it. Caller is responsible for
/// the trailing `: (i += 1)` of the parse loop, so this leaves `i` pointing
/// at the consumed value.
fn consumeValue(argv: []const []const u8, i: *usize) ParseError![]const u8 {
    if (i.* + 1 >= argv.len) return ParseError.MissingValue;
    i.* += 1;
    return argv[i.*];
}

/// Parse a byte size like "10MB", "1GiB", "1024", "2.5GB" into a u64.
/// Decimal SI prefixes (`kB`, `MB`, ...) use 1000; binary prefixes (`KiB`,
/// `MiB`, ...) use 1024. Suffixes are case-sensitive for the binary form.
pub fn parseBytes(text: []const u8) ParseError!u64 {
    if (text.len == 0) return ParseError.InvalidArgument;

    var split: usize = 0;
    while (split < text.len and (std.ascii.isDigit(text[split]) or text[split] == '.')) {
        split += 1;
    }
    if (split == 0) return ParseError.InvalidArgument;
    const number_text = text[0..split];
    const suffix_text = text[split..];

    const multiplier: u64 = blk: {
        for (SIZE_SUFFIXES) |s| {
            if (mem.eql(u8, suffix_text, s.text)) break :blk s.multiplier;
        }
        if (suffix_text.len == 0) break :blk 1;
        return ParseError.InvalidArgument;
    };

    const value_f = std.fmt.parseFloat(f64, number_text) catch return ParseError.InvalidArgument;
    if (value_f < 0) return ParseError.InvalidArgument;

    const result_f = value_f * @as(f64, @floatFromInt(multiplier));
    if (result_f > @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
        return ParseError.InvalidArgument;
    }
    return @intFromFloat(result_f);
}

fn parseU32(text: []const u8) ParseError!u32 {
    if (text.len == 0) return ParseError.InvalidArgument;
    return std.fmt.parseInt(u32, text, 10) catch return ParseError.InvalidArgument;
}

pub const usage =
    \\Usage: zig-clean-all [OPTIONS] [DIR]
    \\
    \\Recursively delete Zig build artifacts (.zig-cache, zig-out, zig-pkg)
    \\under DIR. Defaults to ".".
    \\
    \\Arguments:
    \\  [DIR]                  Root directory [default: .]
    \\
    \\Options:
    \\  -y, --yes              Skip confirmation before cleaning
    \\  -i, --interactive      Inline multi-select TUI to toggle projects
    \\                         (falls back to y/N if not running in a TTY)
    \\  -s, --keep-size <SIZE> Skip projects with artifact size below SIZE
    \\                         (e.g. "10MB", "1GiB"). SI prefixes use 1000,
    \\                         binary prefixes (KiB, MiB, ...) use 1024.
    \\  -d, --keep-days <DAYS> Skip projects compiled within the last DAYS
    \\  --dry-run              Report but do not delete
    \\  --ignore <PATH>        Mark projects under PATH as kept
    \\  --skip <PATH>          Do not descend into PATH at all
    \\  --keep-empty           Remove artifact contents but keep the dir
    \\  --no-summary           Skip the final summary line
    \\  -t, --threads <N>      Worker threads for the parallel scanner
    \\                         (0 = auto, default 0)
    \\  -h, --help             Show this help
    \\  --version              Show version
    \\
;

test "parse defaults" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const out = try parse(arena, &.{});
    try std.testing.expectEqualStrings(".", out[0].root_dir);
    try std.testing.expect(!out[0].yes);
    try std.testing.expect(!out[0].dry_run);
    try std.testing.expectEqual(@as(u64, 0), out[0].keep_size_bytes);
    try std.testing.expectEqual(@as(u32, 0), out[0].keep_days);
    try std.testing.expect(out[0].show_summary);
    try std.testing.expect(!out[0].interactive);
    try std.testing.expectEqual(@as(HelpOrVersion, .neither), out[1]);
}

test "interactive flag activates" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const long_argv = [_][]const u8{"--interactive"};
    const out_long = try parse(arena, &long_argv);
    try std.testing.expect(out_long[0].interactive);

    const short_argv = [_][]const u8{"-i"};
    const out_short = try parse(arena, &short_argv);
    try std.testing.expect(out_short[0].interactive);
}

test "parse directory and flags" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{ "--yes", "--keep-days", "7", "-s", "10MB", "/tmp" };
    const out = try parse(arena, &argv);
    try std.testing.expectEqualStrings("/tmp", out[0].root_dir);
    try std.testing.expect(out[0].yes);
    try std.testing.expectEqual(@as(u32, 7), out[0].keep_days);
    try std.testing.expectEqual(@as(u64, 10_000_000), out[0].keep_size_bytes);
}

test "parse size suffixes" {
    try std.testing.expectEqual(@as(u64, 0), try parseBytes("0"));
    try std.testing.expectEqual(@as(u64, 1024), try parseBytes("1KiB"));
    try std.testing.expectEqual(@as(u64, 1024 * 1024), try parseBytes("1MiB"));
    try std.testing.expectEqual(@as(u64, 10_000_000), try parseBytes("10MB"));
    try std.testing.expectEqual(@as(u64, 1_500_000_000), try parseBytes("1.5GB"));
}

test "parse rejects garbage" {
    try std.testing.expectError(ParseError.InvalidArgument, parseBytes(""));
    try std.testing.expectError(ParseError.InvalidArgument, parseBytes("abc"));
    try std.testing.expectError(ParseError.InvalidArgument, parseBytes("10XB"));
}

test "unknown flag is rejected" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{"--no-such-flag"};
    try std.testing.expectError(ParseError.UnknownFlag, parse(arena, &argv));
}

test "missing value is rejected" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{"--keep-size"};
    try std.testing.expectError(ParseError.MissingValue, parse(arena, &argv));
}

test "ignore and skip accumulate" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{
        "--ignore", "a",
        "--ignore", "b",
        "--skip",   "c",
        ".",
    };
    const out = try parse(arena, &argv);
    try std.testing.expectEqual(@as(usize, 2), out[0].ignore_paths.len);
    try std.testing.expectEqual(@as(usize, 1), out[0].skip_paths.len);
    try std.testing.expectEqualStrings("a", out[0].ignore_paths[0]);
    try std.testing.expectEqualStrings(".", out[0].root_dir);
}

test "--help is detected" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{"--help"};
    const out = try parse(arena, &argv);
    try std.testing.expectEqual(@as(HelpOrVersion, .help), out[1]);
}

test "--version is detected" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{"--version"};
    const out = try parse(arena, &argv);
    try std.testing.expectEqual(@as(HelpOrVersion, .version), out[1]);
}

test "double dash stops flag parsing" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{ "--yes", "--", "--not-a-flag" };
    const out = try parse(arena, &argv);
    try std.testing.expect(out[0].yes);
    try std.testing.expectEqualStrings("--not-a-flag", out[0].root_dir);
}

test "keep-size and keep-days inline form" {
    var arena_buf: [4096]u8 = undefined;
    var arena_alloc = std.heap.FixedBufferAllocator.init(&arena_buf);
    const arena = arena_alloc.allocator();
    const argv = [_][]const u8{ "--keep-size=2MiB", "--keep-days=3", "." };
    const out = try parse(arena, &argv);
    try std.testing.expectEqual(@as(u64, 2 * 1024 * 1024), out[0].keep_size_bytes);
    try std.testing.expectEqual(@as(u32, 3), out[0].keep_days);
    try std.testing.expectEqualStrings(".", out[0].root_dir);
}
