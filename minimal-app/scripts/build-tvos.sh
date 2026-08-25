#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"
BUILD_DIR="$BUILD_ROOT/tvos-simulator"
APP_DIR="$BUILD_DIR/TemuStreamTV.app"
ARCHIVE="$ROOT_DIR/build/TemuStreamTV-simulator.zip"
DERIVED_DATA="${SKELETON_DERIVED_DATA:-$CACHE_ROOT/DerivedData}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release-appletvsimulator/TemuStreamTV.app"
BUILD_LOG="$ROOT_DIR/build/build-tvos.log"
BUILD_LOCK="${SKELETON_BUILD_LOCK:-$CACHE_ROOT/locks/xcode.lock}"
RETENTION_TOOL="$ROOT_DIR/scripts/build-cache-retention.sh"
SOURCE_ID="${STREMIO_SOURCE_ID:-unverified}"
SIMULATOR_ARCH="${SIMULATOR_ARCH:-$(uname -m)}"
STAGED_APP="$BUILD_DIR/.TemuStreamTV.app.tmp.$$"
ARCHIVE_TEMP="$ROOT_DIR/build/.TemuStreamTV-simulator.zip.tmp.$$"
PRODUCT_CACHE_REGISTERED=0
DERIVED_CACHE_REGISTERED=0

. "$ROOT_DIR/scripts/build-support.sh"

typecheck() {
  cd "$ROOT_DIR"
  set -- $(rg --files Sources/StremioSkeletonCore tvOS/App | LC_ALL=C sort)
  set -- "$@" \
    iOS/App/AppModel.swift \
    iOS/App/SessionStore.swift \
    iOS/App/TorBoxPlaybackResolver.swift
  xcrun --sdk appletvsimulator swiftc \
    -typecheck \
    -target "$SIMULATOR_ARCH-apple-tvos18.0-simulator" \
    -sdk "$(xcrun --sdk appletvsimulator --show-sdk-path)" \
    -swift-version 6 \
    -module-name TemuStreamTV \
    "$@"
  echo "tvOS Swift 6 SDK type-check passed"
}

if [ "${1:-}" = "--typecheck" ]; then
  [ "$#" -eq 1 ] || {
    echo "Usage: $0 [--typecheck]" >&2
    exit 2
  }
  typecheck
  exit 0
fi
[ "$#" -eq 0 ] || {
  echo "Usage: $0 [--typecheck]" >&2
  exit 2
}

TVOS_SDK_VERSION="$(xcrun --sdk appletvsimulator --show-sdk-version)"
if ! xcrun simctl list runtimes \
  | rg -q "^tvOS $TVOS_SDK_VERSION .*com\.apple\.CoreSimulator\.SimRuntime\.tvOS-"; then
  echo "No tvOS Simulator runtime is installed." >&2
  echo "Install tvOS in Xcode > Settings > Components, then rerun this command." >&2
  echo "Source validation remains available with: $0 --typecheck" >&2
  exit 2
fi

cleanup() {
  status=$?
  trap - EXIT INT TERM
  rm -rf "$STAGED_APP"
  rm -f "$ARCHIVE_TEMP"
  if [ "$DERIVED_CACHE_REGISTERED" -eq 1 ]; then
    stremio_release_build_cache "$RETENTION_TOOL" "$DERIVED_DATA"
  fi
  if [ "$PRODUCT_CACHE_REGISTERED" -eq 1 ]; then
    stremio_release_build_cache "$RETENTION_TOOL" "$BUILD_ROOT"
  fi
  stremio_release_lock "$BUILD_LOCK"
  exit "$status"
}
trap cleanup EXIT INT TERM

stremio_acquire_lock "$BUILD_LOCK" "the TemuStream Xcode build workspace" 900
stremio_register_build_cache "$RETENTION_TOOL" products "$BUILD_ROOT"
PRODUCT_CACHE_REGISTERED=1
stremio_register_build_cache "$RETENTION_TOOL" derived-data "$DERIVED_DATA"
DERIVED_CACHE_REGISTERED=1
stremio_prune_build_caches "$RETENTION_TOOL" \
  --protect "$BUILD_ROOT" --protect "$DERIVED_DATA"

rm -rf "$APP_DIR" "$STAGED_APP"
mkdir -p "$BUILD_DIR" "$ROOT_DIR/build"

cd "$ROOT_DIR"
xcodegen generate --spec project.yml >/dev/null
if ! xcodebuild \
  -project StremioSkeleton.xcodeproj \
  -scheme TemuStreamTV \
  -configuration Release \
  -sdk appletvsimulator \
  -destination 'generic/platform=tvOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="$SIMULATOR_ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  STREMIO_SOURCE_ID="$SOURCE_ID" \
  build >"$BUILD_LOG" 2>&1; then
  tail -n 100 "$BUILD_LOG" >&2
  exit 1
fi

test -s "$BUILT_APP/TemuStreamTV"
ditto "$BUILT_APP" "$STAGED_APP"
test -s "$STAGED_APP/TemuStreamTV"
test "$(plutil -extract StremioSourceIdentity raw -o - "$STAGED_APP/Info.plist")" = "$SOURCE_ID"
mv "$STAGED_APP" "$APP_DIR"

rm -f "$ARCHIVE_TEMP"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE_TEMP"
unzip -tq "$ARCHIVE_TEMP" >/dev/null
mv -f "$ARCHIVE_TEMP" "$ARCHIVE"

echo "Built $APP_DIR"
echo "Archived $ARCHIVE"
