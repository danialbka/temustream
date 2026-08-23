#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/StremioPlaybackCore"
TARGET_DIR="${SKELETON_RUST_TARGET_DIR:-/private/tmp/stremio-playback-rust-target}"
OUTPUT_DIR="$ROOT_DIR/build/dependencies/StremioPlaybackCore.xcframework"

if ! rustup target list --installed | grep -qx 'aarch64-apple-ios'; then
  rustup target add aarch64-apple-ios
fi
if ! rustup target list --installed | grep -qx 'aarch64-apple-ios-sim'; then
  rustup target add aarch64-apple-ios-sim
fi
if ! rustup target list --installed | grep -qx 'x86_64-apple-ios'; then
  rustup target add x86_64-apple-ios
fi

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

rm -rf "$OUTPUT_DIR"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libstremio_playback_core.a" \
  -headers "$CRATE_DIR/include" \
  -library "$SIMULATOR_DIR/libstremio_playback_core.a" \
  -headers "$CRATE_DIR/include" \
  -output "$OUTPUT_DIR" >/dev/null

echo "Built $OUTPUT_DIR"
