# Bunny build-cache retention

Bunny uses one warm local cache root by default:

```text
/private/tmp/stremio-build-cache/
  DerivedData/       Xcode products, indexes, and Swift Package checkouts
  products/          current Simulator/device applications and harnesses
  rust-target/       Cargo build and test output
  swiftpm/           Swift package scratch and module cache
  locks/             Xcode and Rust serialization locks
```

This replaces task-named DerivedData and scratch paths. Reusing one cache keeps
warm builds fast without duplicating LiveKit, Rust target data, and SwiftPM
checkouts for every test or feature.

## Safety model

`scripts/build-cache-retention.sh` can remove a directory only when all of the
following are true:

1. The directory resolves below `/private/tmp`.
2. It contains an exact `.temustream-build-cache` ownership marker.
3. Its cache kind is one of `derived-data`, `products`, `rust-target`,
   `swiftpm`, or `transient`.
4. It has no live PID lease and does not overlap an explicitly protected path.
5. It exceeds the configured retention count and the grace period has elapsed.

The default policy keeps the two most recently used roots per cache kind.
Inactive excess entries receive a 30-minute grace period. Transient OTA and
Sideloadly workspaces are removed after the grace period if a prior process was
force-terminated before its normal cleanup trap ran.

Unmarked legacy folders are never automatically deleted, even when their names
match `stremio-*-derived`, `stremio-*-build`, or an OTA temporary prefix. They
appear as `LEGACY report-only` entries for explicit human review.

## Commands

```sh
# Read-only inventory and decisions, including legacy candidates.
./scripts/dev-workflow.sh cache-report

# Apply the bounded policy to marker-owned caches only.
./scripts/dev-workflow.sh prune-cache

# Exercise the retention engine entirely inside an isolated temporary fixture.
./scripts/test-build-cache-retention.sh
```

Advanced callers may relocate the shared root without creating several
task-specific cache directories:

```sh
STREMIO_BUILD_CACHE_ROOT=/private/tmp/temustream-cache \
  ./scripts/dev-workflow.sh build-simulator
```

`STREMIO_CACHE_KEEP_PER_KIND` and `STREMIO_CACHE_GRACE_SECONDS` tune retention.
Build scripts register the active paths and pass explicit protections, so a
concurrent or interrupted build cannot be mistaken for stale output.

## What remains outside the shared cache

Release artifacts, screenshots, logs, and source-provenance files remain under
the app's ignored `build/` directory. Their names are stable and normal build
scripts replace them atomically. Source materialization remains under
`/private/tmp/stremio-dev-workflow`; abandoned `stage.*` directories older than
one hour are pruned only while the materializer lock is held.

Do not use this cache policy to remove Simulator device data, Sideloadly's
active IPA record, signing material, source workspaces, arbitrary `/private/tmp`
content, or unrelated Xcode DerivedData.
