#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
APP_VARIANT="${SKELETON_IOS_VARIANT:-temustremio}"
case "$APP_VARIANT" in
  temustremio)
    SCHEME="StremioSkeleton"
    PRODUCT_NAME="StremioSkeleton"
    ARTIFACT_NAME="StremioSkeleton"
    BUILD_SUBDIR="simulator"
    ;;
  bunny)
    SCHEME="Bunny"
    PRODUCT_NAME="Bunny"
    ARTIFACT_NAME="Bunny"
    BUILD_SUBDIR="bunny-simulator"
    ;;
  *)
    echo "SKELETON_IOS_VARIANT must be temustremio or bunny" >&2
    exit 2
    ;;
esac
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"
BUILD_DIR="$BUILD_ROOT/$BUILD_SUBDIR"
APP_DIR="$BUILD_DIR/$PRODUCT_NAME.app"
ARCHIVE="$ROOT_DIR/build/$ARTIFACT_NAME-simulator.zip"
DERIVED_DATA="${SKELETON_DERIVED_DATA:-$CACHE_ROOT/DerivedData}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/$PRODUCT_NAME.app"
SIMULATOR_ARCH="${SIMULATOR_ARCH:-$(uname -m)}"
BUILD_LOG="$ROOT_DIR/build/build-$ARTIFACT_NAME-simulator.log"
BUILD_LOCK="${SKELETON_BUILD_LOCK:-$CACHE_ROOT/locks/xcode.lock}"
RETENTION_TOOL="$ROOT_DIR/scripts/build-cache-retention.sh"
SOURCE_ID="${STREMIO_SOURCE_ID:-unverified}"
PUBLIC_RELEASE="${SKELETON_PUBLIC_RELEASE:-0}"
STAGED_APP="$BUILD_DIR/.$PRODUCT_NAME.app.tmp.$$"
ARCHIVE_TEMP="$ROOT_DIR/build/.$ARTIFACT_NAME-simulator.zip.tmp.$$"
PRODUCT_CACHE_REGISTERED=0
DERIVED_CACHE_REGISTERED=0

. "$ROOT_DIR/scripts/build-support.sh"

case "$PUBLIC_RELEASE" in
  0|1) ;;
  *)
    echo "SKELETON_PUBLIC_RELEASE must be 0 or 1" >&2
    exit 2
    ;;
esac

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

stremio_acquire_lock "$BUILD_LOCK" "the Stremio Xcode build workspace" 900
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
"$ROOT_DIR/scripts/build-rust-core.sh"
xcodegen generate --spec project.yml >/dev/null
set -- build
if [ "$PUBLIC_RELEASE" -eq 1 ]; then
  echo "Public release mode: cleaning the iOS app target"
  set -- clean build
fi
if ! xcodebuild \
  -project StremioSkeleton.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -destination-timeout 5 \
  -derivedDataPath "$DERIVED_DATA" \
  -skipPackageUpdates \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="$SIMULATOR_ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  STREMIO_SOURCE_ID="$SOURCE_ID" \
  "$@" >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG" >&2
  exit 1
fi
test -s "$BUILT_APP/$PRODUCT_NAME"
ditto "$BUILT_APP" "$STAGED_APP"
test -s "$STAGED_APP/$PRODUCT_NAME"
test "$(plutil -extract StremioSourceIdentity raw -o - "$STAGED_APP/Info.plist")" = "$SOURCE_ID"
mv "$STAGED_APP" "$APP_DIR"

xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
du -sh "$APP_DIR"
codesign --verify --strict --verbose=1 "$APP_DIR"
rm -f "$ARCHIVE_TEMP"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE_TEMP"
unzip -tq "$ARCHIVE_TEMP" >/dev/null
mv -f "$ARCHIVE_TEMP" "$ARCHIVE"
echo "Archived $ARCHIVE"
