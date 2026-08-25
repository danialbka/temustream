#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
SWIFTPM_CACHE="${SKELETON_SWIFTPM_CACHE:-$CACHE_ROOT/swiftpm}"
MODULE_CACHE="$SWIFTPM_CACHE/module-cache"
SCRATCH="$SWIFTPM_CACHE/scratch"
RUST_TARGET="${CARGO_TARGET_DIR:-$CACHE_ROOT/rust-target}"
RETENTION_TOOL="$ROOT_DIR/scripts/build-cache-retention.sh"
SWIFTPM_CACHE_REGISTERED=0
RUST_CACHE_REGISTERED=0

. "$ROOT_DIR/scripts/build-support.sh"

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ "$SWIFTPM_CACHE_REGISTERED" -eq 1 ]; then
    stremio_release_build_cache "$RETENTION_TOOL" "$SWIFTPM_CACHE"
  fi
  if [ "$RUST_CACHE_REGISTERED" -eq 1 ]; then
    stremio_release_build_cache "$RETENTION_TOOL" "$RUST_TARGET"
  fi
  exit "$status"
}
trap cleanup EXIT INT TERM

mkdir -p "$MODULE_CACHE" "$SCRATCH"
stremio_register_build_cache "$RETENTION_TOOL" swiftpm "$SWIFTPM_CACHE"
SWIFTPM_CACHE_REGISTERED=1
stremio_register_build_cache "$RETENTION_TOOL" rust-target "$RUST_TARGET"
RUST_CACHE_REGISTERED=1
stremio_prune_build_caches "$RETENTION_TOOL" \
  --protect "$SWIFTPM_CACHE" --protect "$RUST_TARGET"
CARGO_TARGET_DIR="$RUST_TARGET" \
  cargo test --manifest-path "$ROOT_DIR/rust/StremioPlaybackCore/Cargo.toml"
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swift test --package-path "$ROOT_DIR" --scratch-path "$SCRATCH"
