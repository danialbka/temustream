#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
IPA="${1:-$ROOT_DIR/../artifacts/stremio_iOS-2.0.3-18.ipa}"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"

if [ ! -f "$IPA" ]; then
  echo "Usage: $0 /path/to/reference.ipa" >&2
  exit 1
fi

KS_BYTES="$(unzip -l "$IPA" | awk '$4 ~ /Frameworks\/KSPlayer.framework\/KSPlayer$/ {print $1}')"
VLC_BYTES="$(unzip -l "$IPA" | awk '$4 ~ /Frameworks\/MobileVLCKit.framework\/MobileVLCKit$/ {print $1}')"
APP_BYTES="$(stat -f '%z' "$BUILD_ROOT/device/StremioSkeleton.app/StremioSkeleton" 2>/dev/null || echo 0)"
APP_DIR="$BUILD_ROOT/device/StremioSkeleton.app"
APP_BUNDLE_BYTES="$(du -sk "$APP_DIR" 2>/dev/null | awk '{print $1 * 1024}' || echo 0)"
REFERENCE_PLAYER_BYTES="$((${KS_BYTES:-0} + ${VLC_BYTES:-0}))"
UNWANTED_FRAMEWORKS="$(find "$APP_DIR/Frameworks" -maxdepth 1 -type d \
  \( -name 'KSPlayer.framework' -o -name 'MobileVLCKit.framework' \
     -o -name 'Libav*.framework' -o -name 'libav*.framework' \) \
  -print 2>/dev/null || true)"

echo "Player footprint benchmark"
echo "Skeleton app bundle bytes: $APP_BUNDLE_BYTES"
echo "Skeleton app executable bytes (Rust Bunny core + Apple media APIs): $APP_BYTES"
echo "KSPlayer reference framework bytes: ${KS_BYTES:-unavailable}"
echo "MobileVLCKit reference framework bytes: ${VLC_BYTES:-unavailable}"
echo "Reference KSPlayer + MobileVLCKit bytes: $REFERENCE_PLAYER_BYTES"
if [ -n "$UNWANTED_FRAMEWORKS" ]; then
  echo "Disallowed player frameworks found in Bunny build:" >&2
  echo "$UNWANTED_FRAMEWORKS" >&2
  exit 1
fi
echo "Disallowed player frameworks: none"
