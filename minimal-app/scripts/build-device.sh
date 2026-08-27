#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"
BUILD_DIR="$BUILD_ROOT/device"
APP_DIR="$BUILD_DIR/StremioSkeleton.app"
ARCHIVE="$ROOT_DIR/build/StremioSkeleton-device.zip"
IPA="$ROOT_DIR/build/StremioSkeleton-device.ipa"
IPA_ROOT="$BUILD_ROOT/ipa"
DERIVED_DATA="${SKELETON_DERIVED_DATA:-$CACHE_ROOT/DerivedData}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/StremioSkeleton.app"
BUILD_LOG="$ROOT_DIR/build/build-device.log"
BUILD_LOCK="${SKELETON_BUILD_LOCK:-$CACHE_ROOT/locks/xcode.lock}"
RETENTION_TOOL="$ROOT_DIR/scripts/build-cache-retention.sh"
SOURCE_ID="${STREMIO_SOURCE_ID:-unverified}"
PUBLIC_RELEASE="${SKELETON_PUBLIC_RELEASE:-0}"
STAGED_APP="$BUILD_DIR/.StremioSkeleton.app.tmp.$$"
IPA_TEMP="$ROOT_DIR/build/.StremioSkeleton-device.ipa.tmp.$$"
PROVENANCE="$ROOT_DIR/build/StremioSkeleton-device.ipa.source.json"
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
  rm -f "$IPA_TEMP" "$PROVENANCE.tmp.$$"
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
"$ROOT_DIR/scripts/fetch-vlc.sh"
"$ROOT_DIR/scripts/build-rust-core.sh"
xcodegen generate --spec project.yml >/dev/null
set -- build
if [ "$PUBLIC_RELEASE" -eq 1 ]; then
  echo "Public release mode: disabling Watch Together endpoints and cleaning the app target"
  set -- \
    WATCH_TOGETHER_CONVEX_URL= \
    WATCH_TOGETHER_LIVEKIT_URL= \
    clean build
fi
if ! xcodebuild \
  -project StremioSkeleton.xcodeproj \
  -scheme StremioSkeleton \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  STREMIO_SOURCE_ID="$SOURCE_ID" \
  "$@" >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG" >&2
  exit 1
fi
test -s "$BUILT_APP/StremioSkeleton"
ditto "$BUILT_APP" "$STAGED_APP"
test -s "$STAGED_APP/StremioSkeleton"
test "$(plutil -extract StremioSourceIdentity raw -o - "$STAGED_APP/Info.plist")" = "$SOURCE_ID"
if [ "$PUBLIC_RELEASE" -eq 1 ]; then
  test -z "$(plutil -extract WatchTogetherConvexURL raw -o - "$STAGED_APP/Info.plist")"
  test -z "$(plutil -extract WatchTogetherLiveKitURL raw -o - "$STAGED_APP/Info.plist")"
fi
mv "$STAGED_APP" "$APP_DIR"

# The vendored MobileVLCKit device framework still carries armv7 and armv7s
# slices even though this app targets iOS 16+. Keep only arm64 in the device
# handoff so local signing and CoreDevice Wi-Fi transfer tens of megabytes less.
for FRAMEWORK_DIR in "$APP_DIR"/Frameworks/*.framework; do
  [ -d "$FRAMEWORK_DIR" ] || continue
  EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -o - "$FRAMEWORK_DIR/Info.plist" 2>/dev/null || true)"
  FRAMEWORK_BINARY="$FRAMEWORK_DIR/$EXECUTABLE_NAME"
  [ -n "$EXECUTABLE_NAME" ] && [ -f "$FRAMEWORK_BINARY" ] || continue
  FRAMEWORK_ARCHS="$(lipo -archs "$FRAMEWORK_BINARY" 2>/dev/null || true)"
  case " $FRAMEWORK_ARCHS " in
    *" arm64 "*) ;;
    *)
      echo "Framework is missing arm64: $FRAMEWORK_DIR" >&2
      exit 1
      ;;
  esac
  ARCH_COUNT="$(printf '%s\n' "$FRAMEWORK_ARCHS" | awk '{print NF}')"
  if [ "$ARCH_COUNT" -gt 1 ]; then
    THIN_BINARY="$FRAMEWORK_BINARY.arm64.tmp"
    lipo "$FRAMEWORK_BINARY" -thin arm64 -output "$THIN_BINARY"
    mv -f "$THIN_BINARY" "$FRAMEWORK_BINARY"
    echo "Thinned $(basename "$FRAMEWORK_DIR") to arm64"
  fi
done

xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
# Sign nested frameworks first, then add the app-only Group Activities request
# to the handoff IPA so Sideloadly can request a matching provisioning profile
# when it performs the final device signature.
codesign --force --deep --sign - "$APP_DIR"
codesign --force --sign - \
  --entitlements "$ROOT_DIR/iOS/Resources/StremioSkeleton.entitlements" \
  "$APP_DIR"

echo "Built $APP_DIR"
du -sh "$APP_DIR"
file "$APP_DIR/StremioSkeleton"
codesign --verify --strict --verbose=1 "$APP_DIR"
if [ "${SKELETON_SKIP_DEVICE_ZIP:-0}" != "1" ]; then
  rm -f "$ARCHIVE"
  ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE"
  echo "Archived $ARCHIVE"
else
  rm -f "$ARCHIVE"
  echo "Skipped the redundant device ZIP for fast OTA"
fi

# Sideloaders require an IPA whose archive root is Payload/, not a renamed
# application ZIP. Strip resource-fork metadata above, preserve framework
# symlinks, and build the installable handoff deterministically.
rm -rf "$IPA_ROOT/Payload"
mkdir -p "$IPA_ROOT/Payload"
ditto "$APP_DIR" "$IPA_ROOT/Payload/StremioSkeleton.app"
rm -f "$IPA_TEMP"
(
  cd "$IPA_ROOT"
  /usr/bin/zip -qry -y "$IPA_TEMP" Payload
)
unzip -tq "$IPA_TEMP" >/dev/null
mv -f "$IPA_TEMP" "$IPA"

IPA_SHA256="$(shasum -a 256 "$IPA" | awk '{print $1}')"
IPA_SIZE="$(stat -f '%z' "$IPA")"
jq -n \
  --arg sourceID "$SOURCE_ID" \
  --arg ipaSHA256 "$IPA_SHA256" \
  --arg capturedAt "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
  --argjson ipaBytes "$IPA_SIZE" \
  '{schemaVersion: 1, sourceID: $sourceID, ipaSHA256: $ipaSHA256, ipaBytes: $ipaBytes, capturedAt: $capturedAt}' \
  > "$PROVENANCE.tmp.$$"
mv -f "$PROVENANCE.tmp.$$" "$PROVENANCE"
echo "Packaged $IPA"
echo "Source identity $SOURCE_ID"
