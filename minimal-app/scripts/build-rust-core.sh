#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/StremioPlaybackCore"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
TARGET_DIR="${SKELETON_RUST_TARGET_DIR:-$CACHE_ROOT/rust-target}"
OUTPUT_DIR="$ROOT_DIR/build/dependencies/StremioPlaybackCore.xcframework"
OUTPUT_STAMP="$ROOT_DIR/build/dependencies/StremioPlaybackCore.inputs.sha256"
BUILD_LOCK="${SKELETON_RUST_BUILD_LOCK:-$CACHE_ROOT/locks/rust.lock}"
RETENTION_TOOL="$ROOT_DIR/scripts/build-cache-retention.sh"
TEMP_OUTPUT="$ROOT_DIR/build/dependencies/.StremioPlaybackCore.tmp.$$.xcframework"
OLD_OUTPUT="$ROOT_DIR/build/dependencies/.StremioPlaybackCore.old.$$.xcframework"
RUST_CACHE_REGISTERED=0

. "$ROOT_DIR/scripts/build-support.sh"

cleanup() {
  status=$?
  trap - EXIT INT TERM
  rm -rf "$TEMP_OUTPUT"
  if [ -d "$OLD_OUTPUT" ]; then
    if [ ! -e "$OUTPUT_DIR" ]; then
      mv "$OLD_OUTPUT" "$OUTPUT_DIR" 2>/dev/null || true
    else
      rm -rf "$OLD_OUTPUT"
    fi
  fi
  if [ "$RUST_CACHE_REGISTERED" -eq 1 ]; then
    stremio_release_build_cache "$RETENTION_TOOL" "$TARGET_DIR"
  fi
  stremio_release_lock "$BUILD_LOCK"
  exit "$status"
}
trap cleanup EXIT INT TERM

rust_input_signature() {
  {
    printf '%s\n' "stremio-rust-xcframework-v2"
    cargo --version
    rustc --version --verbose
    shasum -a 256 "$ROOT_DIR/scripts/build-rust-core.sh"
    find "$CRATE_DIR" -type f ! -path '*/target/*' -print \
      | LC_ALL=C sort \
      | while IFS= read -r input_file; do
          [ -s "$input_file" ] || {
            echo "Zero-byte Rust input: $input_file" >&2
            exit 1
          }
          shasum -a 256 "$input_file"
        done
  } | shasum -a 256 | awk '{print $1}'
}

framework_is_complete() {
  [ -d "$OUTPUT_DIR" ] || return 1
  device_library="$OUTPUT_DIR/ios-arm64/libstremio_playback_core.a"
  simulator_library="$(find "$OUTPUT_DIR" -path '*simulator*/libstremio_playback_core.a' -type f -print -quit)"
  [ -s "$device_library" ] \
    && [ -n "$simulator_library" ] && [ -s "$simulator_library" ]
}

framework_matches_stamp() {
  [ -f "$OUTPUT_STAMP" ] || return 1
  stamped_input="$(sed -n '1p' "$OUTPUT_STAMP")"
  stamped_device="$(sed -n '2p' "$OUTPUT_STAMP")"
  stamped_simulator="$(sed -n '3p' "$OUTPUT_STAMP")"
  device_library="$OUTPUT_DIR/ios-arm64/libstremio_playback_core.a"
  simulator_library="$(find "$OUTPUT_DIR" -path '*simulator*/libstremio_playback_core.a' -type f -print -quit)"
  [ "$stamped_input" = "$INPUT_SIGNATURE" ] \
    && [ -n "$stamped_device" ] \
    && [ "$stamped_device" = "$(shasum -a 256 "$device_library" | awk '{print $1}')" ] \
    && [ -n "$stamped_simulator" ] \
    && [ "$stamped_simulator" = "$(shasum -a 256 "$simulator_library" | awk '{print $1}')" ]
}

stremio_acquire_lock "$BUILD_LOCK" "the Rust playback-core artifact" 300
stremio_register_build_cache "$RETENTION_TOOL" rust-target "$TARGET_DIR"
RUST_CACHE_REGISTERED=1
stremio_prune_build_caches "$RETENTION_TOOL" --protect "$TARGET_DIR"
INPUT_SIGNATURE="$(rust_input_signature)"
if framework_is_complete && framework_matches_stamp; then
  echo "Reused $OUTPUT_DIR (${INPUT_SIGNATURE%${INPUT_SIGNATURE#????????????}})"
  exit 0
fi

if ! rustup target list --installed | grep -qx 'aarch64-apple-ios'; then
  rustup target add aarch64-apple-ios
fi
if ! rustup target list --installed | grep -qx 'aarch64-apple-ios-sim'; then
  rustup target add aarch64-apple-ios-sim
fi
if ! rustup target list --installed | grep -qx 'x86_64-apple-ios'; then
  rustup target add x86_64-apple-ios
fi

# The verified scratch workspace preserves source mtimes. When an older source
# snapshot is restored over a newer Cargo cache, Cargo's mtime fingerprint can
# otherwise reuse an archive built from different bytes. The content stamp
# above already proved that the Rust inputs changed, so invalidate only this
# crate's release products and keep downloaded dependencies intact.
for rust_target in aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios; do
  CARGO_TARGET_DIR="$TARGET_DIR" cargo clean \
    --manifest-path "$CRATE_DIR/Cargo.toml" \
    --package stremio-playback-core \
    --release \
    --target "$rust_target" \
    --quiet
done

CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
  --manifest-path "$CRATE_DIR/Cargo.toml" \
  --release \
  --target aarch64-apple-ios
CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
  --manifest-path "$CRATE_DIR/Cargo.toml" \
  --release \
  --target aarch64-apple-ios-sim
CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
  --manifest-path "$CRATE_DIR/Cargo.toml" \
  --release \
  --target x86_64-apple-ios

SIMULATOR_DIR="$TARGET_DIR/ios-simulator-universal/release"
mkdir -p "$SIMULATOR_DIR"
xcrun lipo -create \
  "$TARGET_DIR/aarch64-apple-ios-sim/release/libstremio_playback_core.a" \
  "$TARGET_DIR/x86_64-apple-ios/release/libstremio_playback_core.a" \
  -output "$SIMULATOR_DIR/libstremio_playback_core.a"

mkdir -p "$(dirname "$OUTPUT_DIR")"
rm -rf "$TEMP_OUTPUT" "$OLD_OUTPUT"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libstremio_playback_core.a" \
  -headers "$CRATE_DIR/include" \
  -library "$SIMULATOR_DIR/libstremio_playback_core.a" \
  -headers "$CRATE_DIR/include" \
  -output "$TEMP_OUTPUT" >/dev/null

TEMP_DEVICE_LIBRARY="$TEMP_OUTPUT/ios-arm64/libstremio_playback_core.a"
TEMP_SIMULATOR_LIBRARY="$(find "$TEMP_OUTPUT" -path '*simulator*/libstremio_playback_core.a' -type f -print -quit)"
[ -s "$TEMP_DEVICE_LIBRARY" ] \
  && [ -n "$TEMP_SIMULATOR_LIBRARY" ] && [ -s "$TEMP_SIMULATOR_LIBRARY" ] || {
    echo "Generated Rust XCFramework is incomplete" >&2
    exit 1
  }

if [ -d "$OUTPUT_DIR" ]; then
  mv "$OUTPUT_DIR" "$OLD_OUTPUT"
fi
mv "$TEMP_OUTPUT" "$OUTPUT_DIR"
rm -rf "$OLD_OUTPUT"
OUTPUT_SIMULATOR_LIBRARY="$(find "$OUTPUT_DIR" -path '*simulator*/libstremio_playback_core.a' -type f -print -quit)"
{
  printf '%s\n' "$INPUT_SIGNATURE"
  shasum -a 256 "$OUTPUT_DIR/ios-arm64/libstremio_playback_core.a" | awk '{print $1}'
  shasum -a 256 "$OUTPUT_SIMULATOR_LIBRARY" | awk '{print $1}'
} > "$OUTPUT_STAMP.tmp.$$"
mv -f "$OUTPUT_STAMP.tmp.$$" "$OUTPUT_STAMP"

echo "Built $OUTPUT_DIR"
