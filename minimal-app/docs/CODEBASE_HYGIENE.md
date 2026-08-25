# Codebase hygiene

`scripts/repo-health.sh` is a read-only inventory guard for the app repository.
It reports clutter and risky files; it never removes, moves, rewrites, or stages
anything.

## Quick use

```sh
./scripts/repo-health.sh
./scripts/repo-health.sh --check
```

The default scan never hydrates cloud-placeholder files. For complete content
and hotspot checks after materializing the app source, point it at the verified
local workspace:

```sh
./scripts/dev-workflow.sh prepare
./scripts/repo-health.sh --content-root /private/tmp/stremio-dev-workflow/workspace
```

`CLOUD_CONTENT_SKIPPED` is an explicit coverage warning, not a source error.
The scan still inventories canonical paths, duplicates, and local debris from
the real checkout.

The default report mode always exits successfully after a completed scan so it
does not interrupt an interactive debugging or simulator session. Check mode is
for an explicit local or CI gate:

- `0`: no findings
- `1`: warnings only
- `2`: at least one error
- `64`: invalid command-line arguments
- `70`: the scan itself could not run

Use `--max-source-lines N` to tune the default 1,200-line hotspot threshold.
Use `--root PATH` to inspect an isolated fixture or another checkout with the
same project shape.

## What it reports

- missing canonical source, test, project, workflow, and documentation paths
- zero-byte first-party source files
- first-party source hotspots that are becoming difficult to navigate
- Finder-style duplicate copies such as `Info 2.plist` or a numbered Xcode
  project, including copies hidden by a global ignore rule
- Xcode user state and Finder metadata outside the canonical build folders
- packaged apps, archives, logs, videos, and screenshots that escaped the
  ignored build/output or approved resource directories
- credential-bearing filenames and high-confidence credential markers in
  tracked or visible untracked files; matched values are never printed

Generated output belongs under `build/`, SwiftPM output under `.build/`, Rust
output under a `target/` directory, and dependency output under `node_modules/`.
Those locations are intentionally pruned so the health report stays focused and
does not hydrate or traverse large generated trees.

Large temporary compiler caches are managed separately. All standard build and
test entry points reuse `/private/tmp/stremio-build-cache` unless
`STREMIO_BUILD_CACHE_ROOT` is explicitly set. To inspect storage decisions:

```sh
./scripts/dev-workflow.sh cache-report
```

The cache report is safe and read-only. Automatic pruning requires a valid
TemuStream ownership marker, respects live PID leases, retains the two newest
caches per kind, and gives inactive entries a 30-minute grace period. Unmarked
legacy `stremio-*` folders are reported but never automatically removed. See
`docs/BUILD_CACHE_RETENTION.md` for the full policy.

## How to use a finding

Treat the report as an inventory, not an automatic cleanup list. Confirm a
duplicate against the canonical file and Git history before moving or deleting
it. Split a hotspot only as part of a tested feature change; its line count is a
navigation signal, not proof of a bug. Rotate any real credential immediately,
then remove it from current files and repository history with an explicit,
reviewed procedure.

Keep validation evidence distinct when handing work off:

1. static or unit checks
2. simulator build and UI/runtime behavior
3. device artifact creation
4. verified installation and launch on the intended phone

A passing build is not evidence of a successful install, and a screenshot is
not by itself evidence that playback remained healthy over time.
