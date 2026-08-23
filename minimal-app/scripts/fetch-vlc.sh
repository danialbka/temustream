#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
DEPENDENCY_DIR="$ROOT_DIR/build/dependencies"
FRAMEWORK_DIR="$DEPENDENCY_DIR/MobileVLCKit.xcframework"
CACHE_DIR="${SKELETON_VLC_CACHE_DIR:-/private/tmp/stremio-mobilevlckit-3.7.3}"
ARCHIVE="$CACHE_DIR/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
SOURCE_URL="https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.7.3-319ed2c0-79128878.tar.xz"
EXPECTED_SHA256="0d04059906962ddc9a7bd1ebaa12e1f9ae85eb2466116a97a2f46886dd27a0a9"
EXPECTED_FRAMEWORK_SHA256="bd4bf0517e94b20002b3d6c60623e979ff3882191b93a12fc4cce6bea18d87bc"

framework_sha256() {
  framework_path="$1"
  [ -d "$framework_path" ] || return 1
  [ -z "$(find "$framework_path" -type l ! -path '*/dSYMs/*' -print -quit)" ] || return 1
  (
    cd "$framework_path"
    find . -type f ! -path '*/dSYMs/*' -print \
      | LC_ALL=C sort \
      | while IFS= read -r file; do
          shasum -a 256 "$file"
        done
  ) | shasum -a 256 | awk '{print $1}'
}

if [ -d "$FRAMEWORK_DIR" ]; then
  CURRENT_FRAMEWORK_SHA256="$(framework_sha256 "$FRAMEWORK_DIR" || true)"
  if [ "$CURRENT_FRAMEWORK_SHA256" = "$EXPECTED_FRAMEWORK_SHA256" ]; then
    exit 0
  fi
  echo "Cached MobileVLCKit failed integrity verification; restoring it from the verified archive" >&2
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

SOURCE_FRAMEWORK_SHA256="$(framework_sha256 "$SOURCE_FRAMEWORK" || true)"
if [ "$SOURCE_FRAMEWORK_SHA256" != "$EXPECTED_FRAMEWORK_SHA256" ]; then
  echo "MobileVLCKit.xcframework content does not match the pinned release" >&2
  exit 1
fi

STAGED_FRAMEWORK="$DEPENDENCY_DIR/.MobileVLCKit.xcframework.tmp.$$"
rm -rf "$STAGED_FRAMEWORK"
ditto "$SOURCE_FRAMEWORK" "$STAGED_FRAMEWORK"
STAGED_FRAMEWORK_SHA256="$(framework_sha256 "$STAGED_FRAMEWORK" || true)"
if [ "$STAGED_FRAMEWORK_SHA256" != "$EXPECTED_FRAMEWORK_SHA256" ]; then
  rm -rf "$STAGED_FRAMEWORK"
  echo "Copied MobileVLCKit.xcframework failed integrity verification" >&2
  exit 1
fi
rm -rf "$FRAMEWORK_DIR"
mv "$STAGED_FRAMEWORK" "$FRAMEWORK_DIR"
echo "Fetched official MobileVLCKit 3.7.3 into $FRAMEWORK_DIR"
