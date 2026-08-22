#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-/private/tmp/stremio-skeleton-build}"
BUILD_DIR="$BUILD_ROOT/simulator"
APP_DIR="$BUILD_DIR/StremioSkeleton.app"
ARCHIVE="$ROOT_DIR/build/StremioSkeleton-simulator.zip"
DERIVED_DATA="${SKELETON_DERIVED_DATA:-/private/tmp/stremio-skeleton-ks-derived}"
BUILT_APP="$DERIVED_DATA/Build/Products/Release-iphonesimulator/StremioSkeleton.app"
SIMULATOR_ARCH="${SIMULATOR_ARCH:-$(uname -m)}"
BUILD_LOG="$ROOT_DIR/build/build-simulator.log"

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
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  ARCHS="$SIMULATOR_ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  build >"$BUILD_LOG" 2>&1; then
  tail -n 80 "$BUILD_LOG" >&2
  exit 1
fi
cp -R "$BUILT_APP" "$APP_DIR"

xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
codesign --force --deep --sign - "$APP_DIR"

echo "Built $APP_DIR"
du -sh "$APP_DIR"
codesign --verify --strict --verbose=1 "$APP_DIR"
rm -f "$ARCHIVE"
ditto -c -k --norsrc --keepParent "$APP_DIR" "$ARCHIVE"
echo "Archived $ARCHIVE"
