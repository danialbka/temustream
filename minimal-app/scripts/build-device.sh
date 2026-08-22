#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-/private/tmp/stremio-skeleton-build}"
BUILD_DIR="$BUILD_ROOT/device"
APP_DIR="$BUILD_DIR/StremioSkeleton.app"
ARCHIVE="$ROOT_DIR/build/StremioSkeleton-device.zip"
IPA="$ROOT_DIR/build/StremioSkeleton-device.ipa"
IPA_ROOT="$BUILD_ROOT/ipa"
DERIVED_DATA="${SKELETON_DERIVED_DATA:-/private/tmp/stremio-skeleton-ks-derived}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/StremioSkeleton.app"
BUILD_LOG="$ROOT_DIR/build/build-device.log"

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR" "$ROOT_DIR/build"

cd "$ROOT_DIR"
"$ROOT_DIR/scripts/fetch-vlc.sh"
"$ROOT_DIR/scripts/build-rust-core.sh"
xcodegen generate --spec project.yml >/dev/null
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
  build >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG" >&2
  exit 1
fi
cp -R "$BUILT_APP" "$APP_DIR"

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
rm -f "$ARCHIVE"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE"
echo "Archived $ARCHIVE"

# Sideloaders require an IPA whose archive root is Payload/, not a renamed
# application ZIP. Strip resource-fork metadata above, preserve framework
# symlinks, and build the installable handoff deterministically.
rm -rf "$IPA_ROOT/Payload"
mkdir -p "$IPA_ROOT/Payload"
ditto "$APP_DIR" "$IPA_ROOT/Payload/StremioSkeleton.app"
rm -f "$IPA"
(
  cd "$IPA_ROOT"
  /usr/bin/zip -qry -y "$IPA" Payload
)
echo "Packaged $IPA"
