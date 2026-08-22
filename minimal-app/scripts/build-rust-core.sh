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

CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
  --manifest-path "$CRATE_DIR/Cargo.toml" \
  --release \
  --target aarch64-apple-ios
CARGO_TARGET_DIR="$TARGET_DIR" cargo build \
  --manifest-path "$CRATE_DIR/Cargo.toml" \
  --release \
  --target aarch64-apple-ios-sim

rm -rf "$OUTPUT_DIR"
xcodebuild -create-xcframework \
  -library "$TARGET_DIR/aarch64-apple-ios/release/libstremio_playback_core.a" \
  -headers "$CRATE_DIR/include" \
  -library "$TARGET_DIR/aarch64-apple-ios-sim/release/libstremio_playback_core.a" \
  -headers "$CRATE_DIR/include" \
  -output "$OUTPUT_DIR" >/dev/null

echo "Built $OUTPUT_DIR"
