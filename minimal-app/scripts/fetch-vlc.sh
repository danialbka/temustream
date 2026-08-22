#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEPENDENCY_DIR="$ROOT_DIR/build/dependencies"
FRAMEWORK_DIR="$DEPENDENCY_DIR/MobileVLCKit.xcframework"
CACHE_DIR="${SKELETON_VLC_CACHE_DIR:-/private/tmp/stremio-mobilevlckit-3.7.3}"
ARCHIVE="$CACHE_DIR/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
SOURCE_URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
EXPECTED_SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"

if [ -d "$FRAMEWORK_DIR" ]; then
  exit 0
fi

mkdir -p "$CACHE_DIR" "$DEPENDENCY_DIR"
if [ ! -f "$ARCHIVE" ]; then
  curl -fL --retry 3 --output "$ARCHIVE" "$SOURCE_URL"
fi

printf '%s  %s\n' "$EXPECTED_SHA256" "$ARCHIVE" | shasum -a 256 -c -

SOURCE_FRAMEWORK="$(find "$CACHE_DIR" -type d -name MobileVLCKit.xcframework -print -quit)"
if [ -z "$SOURCE_FRAMEWORK" ]; then
  EXTRACT_DIR="$CACHE_DIR/extracted"
  mkdir -p "$EXTRACT_DIR"
  tar -xJf "$ARCHIVE" -C "$EXTRACT_DIR"
  SOURCE_FRAMEWORK="$(find "$EXTRACT_DIR" -type d -name MobileVLCKit.xcframework -print -quit)"
fi
if [ -z "$SOURCE_FRAMEWORK" ]; then
  echo "MobileVLCKit.xcframework is missing from the verified archive" >&2
  exit 1
fi

ditto "$SOURCE_FRAMEWORK" "$FRAMEWORK_DIR"
echo "Fetched official MobileVLCKit 3.7.3 into $FRAMEWORK_DIR"
