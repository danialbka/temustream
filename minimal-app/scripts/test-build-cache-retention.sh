#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
tool="$script_dir/build-cache-retention.sh"
fixture_root="$(mktemp -d /private/tmp/temustream-cache-retention-test.XXXXXX)"

cleanup() {
  rm -rf -- "$fixture_root"
}
trap cleanup EXIT INT TERM

export STREMIO_CACHE_SCAN_ROOT="$fixture_root"

register_inactive() {
  local kind="$1" cache_path="$2" epoch="$3"
  STREMIO_CACHE_NOW_EPOCH="$epoch" \
    "$tool" register --kind "$kind" --path "$cache_path" --pid "$$" >/dev/null
  STREMIO_CACHE_NOW_EPOCH="$epoch" \
    "$tool" release --path "$cache_path" --pid "$$"
}

register_inactive derived-data "$fixture_root/derived-old" 100
register_inactive derived-data "$fixture_root/derived-middle" 200
register_inactive derived-data "$fixture_root/derived-new" 300
mkdir -p "$fixture_root/unmarked-user-data"
print -r -- "keep" > "$fixture_root/unmarked-user-data/proof.txt"

STREMIO_CACHE_NOW_EPOCH=1000 \
  "$tool" prune --apply --max-per-kind 2 --grace-seconds 0 >/dev/null
[[ ! -e "$fixture_root/derived-old" ]]
[[ -d "$fixture_root/derived-middle" ]]
[[ -d "$fixture_root/derived-new" ]]
[[ -f "$fixture_root/unmarked-user-data/proof.txt" ]]

STREMIO_CACHE_NOW_EPOCH=400 \
  "$tool" register --kind derived-data \
    --path "$fixture_root/derived-active" --pid "$$" >/dev/null
STREMIO_CACHE_NOW_EPOCH=1000 \
  "$tool" prune --apply --max-per-kind 1 --grace-seconds 0 >/dev/null
[[ -d "$fixture_root/derived-active" ]]
[[ -f "$fixture_root/derived-active/.temustream-build-cache-active" ]]

STREMIO_CACHE_NOW_EPOCH=1000 \
  "$tool" release --path "$fixture_root/derived-active" --pid "$$"
register_inactive transient "$fixture_root/interrupted-ota" 50
STREMIO_CACHE_NOW_EPOCH=1000 \
  "$tool" prune --apply --max-per-kind 1 --grace-seconds 0 >/dev/null
[[ ! -e "$fixture_root/interrupted-ota" ]]

register_inactive products "$fixture_root/protected-products" 25
register_inactive products "$fixture_root/new-products" 30
STREMIO_CACHE_NOW_EPOCH=1000 \
  "$tool" prune --apply --max-per-kind 0 --grace-seconds 0 \
    --protect "$fixture_root/protected-products" >/dev/null
[[ -d "$fixture_root/protected-products" ]]
[[ ! -e "$fixture_root/new-products" ]]

print -r -- "build-cache retention tests passed"
