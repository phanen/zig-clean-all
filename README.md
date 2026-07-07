# zig-clean-all

Recursively delete Zig build artifacts (`.zig-cache`, `zig-out`, `zig-pkg`)
under a given root, with size and last-modified filters, dry-run mode, and
an interactive y/N confirmation.

## How it works

A walk starting from `DIR` (default `.`) finds every directory that contains
a `build.zig`; that is the unit of selection. The walker never descends
into `.zig-cache`, `zig-out`, `zig-pkg`, or any dot-prefixed entry, and
honours `--skip <path>` by treating the path as a literal prefix match
against absolute walker output. For each project, an analyzer sums the
bytes and tracks the latest mtime across the three artifact names. A
project is then kept (and skipped during cleanup) if any of these holds:

- its path is under a `--ignore` root
- it has none of the three artifact directories
- its total artifact size is `<= --keep-size`
- its last-modified time is within `--keep-days` of "now"

Otherwise the project is selected. After an optional confirmation prompt,
the selected projects' artifact directories are removed (`--keep-empty`
empties them in place instead). Failures on individual artifacts are
collected and printed at the end so a partial cleanup never aborts the
rest of the run.

```bash
zig-clean-all                              # scan ".", ask before cleanup
zig-clean-all ~/src --keep-days 7          # ignore projects compiled this week
zig-clean-all ~/src --keep-size 10MiB      # only clean projects >= 10 MiB
zig-clean-all --dry-run ~                  # report only
zig-clean-all --ignore ~/src/important ~   # mark a subtree as kept
zig-clean-all --skip ~/.cache --skip ~/src/foreign ~
zig-clean-all --keep-empty --yes ~/src     # empty dirs instead of removing
```

Sizes accept B, kB, MB, GB, TB (SI, 1000-based) and KiB, MiB, GiB, TiB
(binary, 1024-based).

## credits

* https://github.com/dnlmlr/cargo-clean-all
