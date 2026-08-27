#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"
BUILD_DIR="$BUILD_ROOT/watchos-simulator"
APP_DIR="$BUILD_DIR/TemuStremioWatch.app"
ARCHIVE="$ROOT_DIR/build/TemuStremioWatch-simulator.zip"
DERIVED_DATA="${SKELETON_DERIVED_DATA:-$CACHE_ROOT/DerivedData}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release-watchsimulator/TemuStremioWatch.app"
BUILD_LOG="$ROOT_DIR/build/build-watchos.log"
BUILD_LOCK="${SKELETON_BUILD_LOCK:-$CACHE_ROOT/locks/xcode.lock}"
RETENTION_TOOL="$ROOT_DIR/scripts/build-cache-retention.sh"
SIMULATOR_ARCH="${SIMULATOR_ARCH:-$(uname -m)}"
STAGED_APP="$BUILD_DIR/.TemuStremioWatch.app.tmp.$$"
ARCHIVE_TEMP="$ROOT_DIR/build/.TemuStremioWatch-simulator.zip.tmp.$$"
PRODUCT_CACHE_REGISTERED=0
DERIVED_CACHE_REGISTERED=0

. "$ROOT_DIR/scripts/build-support.sh"

typecheck() {
  cd "$ROOT_DIR"
  set -- \
    Sources/StremioSkeletonCore/Models.swift \
    Sources/StremioSkeletonCore/IntroSkipPolicy.swift \
    Sources/StremioSkeletonCore/AddonEndpoint.swift \
    Sources/StremioSkeletonCore/AddonClient.swift \
    Sources/StremioSkeletonCore/TorrentStreamingClient.swift \
    Sources/StremioSkeletonCore/StremioAccountClient.swift \
    Sources/StremioSkeletonCore/LibraryStore.swift \
    Sources/StremioSkeletonCore/PlaybackProgressStore.swift \
    Sources/StremioSkeletonCore/PlaybackCompletionStore.swift \
    Sources/StremioSkeletonCore/ViewingProfiles.swift \
    Sources/StremioSkeletonCore/DiscoveryPresentation.swift \
    Sources/StremioSkeletonCore/CatalogPaging.swift \
    Sources/StremioSkeletonCore/LocalRecommendations.swift \
    Sources/StremioSkeletonCore/EpisodeResumeSelection.swift \
    Sources/StremioSkeletonCore/PlaybackPreferences.swift \
    Sources/StremioSkeletonCore/LastSuccessfulPlayback.swift \
    Sources/StremioSkeletonCore/TitleTrivia.swift \
    Sources/StremioSkeletonCore/WikipediaTrivia.swift \
    Sources/StremioSkeletonCore/MediaContainerSniffer.swift \
    Sources/StremioSkeletonCore/TorBoxStreamSelection.swift \
    Sources/StremioSkeletonCore/WatchStreamCompatibility.swift \
    Sources/StremioSkeletonCore/WatchPlaybackFallback.swift \
    iOS/App/TorBoxPlaybackResolver.swift
  set -- "$@" $(rg --files watchOS/App | LC_ALL=C sort)
  xcrun --sdk watchsimulator swiftc \
    -typecheck \
    -parse-as-library \
    -target "$SIMULATOR_ARCH-apple-watchos10.0-simulator" \
    -sdk "$(xcrun --sdk watchsimulator --show-sdk-path)" \
    -swift-version 6 \
    -module-name TemuStremioWatch \
    "$@"
  echo "watchOS Swift 6 SDK type-check passed"
}

assert_plist_boolean_true() {
  key="$1"
  plist="$2"
  value="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
  if [ "$value" != "true" ]; then
    echo "Built watch app is missing required Info.plist value $key = true." >&2
    exit 1
  fi
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

WATCHOS_SDK_VERSION="$(xcrun --sdk watchsimulator --show-sdk-version)"
if ! xcrun simctl list runtimes \
  | rg -q "^watchOS $WATCHOS_SDK_VERSION .*com\.apple\.CoreSimulator\.SimRuntime\.watchOS-"; then
  echo "No watchOS Simulator runtime is installed." >&2
  echo "Install watchOS in Xcode > Settings > Components, then rerun this command." >&2
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

stremio_acquire_lock "$BUILD_LOCK" "the TemuStremio watchOS build workspace" 900
stremio_register_build_cache "$RETENTION_TOOL" products "$BUILD_ROOT"
PRODUCT_CACHE_REGISTERED=1
stremio_register_build_cache "$RETENTION_TOOL" derived-data "$DERIVED_DATA"
DERIVED_CACHE_REGISTERED=1
stremio_prune_build_caches "$RETENTION_TOOL" \
  --protect "$BUILD_ROOT" --protect "$DERIVED_DATA"

# Keep dependency caches, but never package files left in an older app bundle.
rm -rf "$APP_DIR" "$STAGED_APP" "$BUILT_APP" "$BUILT_APP.dSYM"
mkdir -p "$BUILD_DIR" "$ROOT_DIR/build"

cd "$ROOT_DIR"
xcodegen generate --spec project.yml >/dev/null
if ! xcodebuild \
  -project StremioSkeleton.xcodeproj \
  -scheme TemuStremioWatch \
  -configuration Release \
  -sdk watchsimulator \
  -destination 'generic/platform=watchOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  -disableAutomaticPackageResolution \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="$SIMULATOR_ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  build >"$BUILD_LOG" 2>&1; then
  tail -n 100 "$BUILD_LOG" >&2
  exit 1
fi

test -s "$BUILT_APP/TemuStremioWatch"
test -s "$BUILT_APP/PrivacyInfo.xcprivacy"
assert_plist_boolean_true WKApplication "$BUILT_APP/Info.plist"
assert_plist_boolean_true WKWatchOnly "$BUILT_APP/Info.plist"
ditto "$BUILT_APP" "$STAGED_APP"
test -s "$STAGED_APP/TemuStremioWatch"
mv "$STAGED_APP" "$APP_DIR"

rm -f "$ARCHIVE_TEMP"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE_TEMP"
unzip -tq "$ARCHIVE_TEMP" >/dev/null
mv -f "$ARCHIVE_TEMP" "$ARCHIVE"

echo "Built $APP_DIR"
echo "Archived $ARCHIVE"
