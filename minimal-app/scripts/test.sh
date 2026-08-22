#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MODULE_CACHE="$ROOT_DIR/build/ModuleCacheTests"
SCRATCH="$ROOT_DIR/build/swiftpm"

mkdir -p "$MODULE_CACHE" "$SCRATCH"
cargo test --manifest-path "$ROOT_DIR/rust/StremioPlaybackCore/Cargo.toml"
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swift test --scratch-path "$SCRATCH"
