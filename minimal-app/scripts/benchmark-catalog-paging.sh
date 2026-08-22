#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
MODULE_CACHE="$ROOT_DIR/build/ModuleCacheBenchmark"
SCRATCH="$ROOT_DIR/build/swiftpm-benchmark"
RESULT="$ROOT_DIR/build/catalog-paging-benchmark.txt"

mkdir -p "$MODULE_CACHE" "$SCRATCH" "$ROOT_DIR/build"
SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE" \
CLANG_MODULE_CACHE_PATH="$MODULE_CACHE" \
swift run --package-path "$ROOT_DIR" -c release --scratch-path "$SCRATCH" \
  CatalogPagingBenchmark >"$RESULT"
cat "$RESULT"

echo "Benchmark report: $RESULT"
