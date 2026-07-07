# zig-clean-all

Recursively delete Zig build artifacts (`.zig-cache`, `zig-out`, `zig-pkg`)
across a directory tree, with size and last-modified filters, an interactive
selection, and a dry-run mode.

Mirrors the ergonomics of `cargo-clean-all` for the Zig toolchain.

## Why

Zig's per-project cache (`.zig-cache`) and output directory (`zig-out`) can
quickly accumulate to tens of gigabytes across a filesystem. This tool finds
every Zig project (any directory containing a `build.zig`) under a given root
and reports - then optionally deletes - those build artifacts.

## Usage

```sh
# Scan current directory, list reclaimable space, ask before cleaning.
zig-clean-all

# Scan ~/src, scan any depth, ignore recently compiled projects.
zig-clean-all --keep-days 7 ~/src

# Interactive selection: pre-check projects older than 1 day, then let the user toggle.
zig-clean-all -i --keep-days 1

# Dry run: report only.
zig-clean-all --dry-run ~

# Skip filesystem trees entirely.
zig-clean-all --skip ~/src/foreign --skip ~/.cache ~
```

## Flags

```
Usage: zig-clean-all [OPTIONS] [DIR]

Arguments:
  [DIR]  Root directory to scan [default: .]

Options:
  -y, --yes                Skip confirmation prompt before cleaning
  -s, --keep-size <SIZE>   Keep projects whose artifact size is below SIZE
                           (e.g. "10MB", "1GiB"). [default: 0]
  -d, --keep-days <DAYS>   Keep projects compiled within the last DAYS days
                           [default: 0]
      --dry-run            Report but do not delete
      --ignore <PATH>      Mark projects under PATH as kept (still scanned)
      --skip <PATH>        Do not even descend into PATH
      --keep-empty         Remove artifact contents but leave the empty
                           directory in place
      --no-summary         Skip the final summary line
  -h, --help               Print this help
      --version            Print version
```

## Targets

`.zig-cache`, `zig-out`, and `zig-pkg` are all considered artifact
directories. A project is selected for cleanup when at least one of these
exists and its accumulated size + last-modified time fail to satisfy the
keep filters.

## Exit codes

- `0` - success (selection cleaned, or nothing to do)
- `1` - I/O error during scan or delete
- `2` - invalid CLI arguments

## License

MIT
