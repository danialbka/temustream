#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
BUILD_DIR="$ROOT_DIR/enhancer/build/simulator"
APP_DIR="$BUILD_DIR/StremioEnhancerHarness.app"
FRAMEWORKS_DIR="$APP_DIR/Frameworks"
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
MODULE_CACHE="$ROOT_DIR/enhancer/build/ModuleCacheSimulator"
ENHANCER_SOURCE="$ROOT_DIR/enhancer/StremioPlayerEnhancer.m"
HARNESS_SOURCE="$ROOT_DIR/enhancer/simulator/SimulatorHarness.m"
DYLIB="$FRAMEWORKS_DIR/StremioPlayerEnhancerSim.dylib"

rm -rf "$APP_DIR"
mkdir -p "$FRAMEWORKS_DIR" "$MODULE_CACHE"
cp "$ROOT_DIR/enhancer/simulator/Info.plist" "$APP_DIR/Info.plist"

COMMON_FLAGS="-arch arm64 -fobjc-arc -fmodules -fmodules-cache-path=$MODULE_CACHE -Wall -Wextra -Werror -isysroot $SDK_PATH -mios-simulator-version-min=16.0"

# shellcheck disable=SC2086
xcrun --sdk iphonesimulator clang $COMMON_FLAGS \
  -dynamiclib \
  -framework Foundation \
  -framework UIKit \
  -framework AVKit \
  -Wl,-dead_strip \
  -Wl,-install_name,@rpath/StremioPlayerEnhancerSim.dylib \
  -o "$DYLIB" \
  "$ENHANCER_SOURCE"

# shellcheck disable=SC2086
xcrun --sdk iphonesimulator clang $COMMON_FLAGS \
  -framework Foundation \
  -framework UIKit \
  -framework AVKit \
  -Wl,-rpath,@executable_path/Frameworks \
  -Wl,-export_dynamic \
  -Wl,-dead_strip \
  -o "$APP_DIR/StremioEnhancerHarness" \
  "$HARNESS_SOURCE" \
  "$DYLIB"

codesign --force --sign - "$DYLIB"
xattr -cr "$APP_DIR"
xattr -d com.apple.FinderInfo "$APP_DIR" 2>/dev/null || true
xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" 2>/dev/null || true
codesign --force --sign - "$APP_DIR"

echo "Built $APP_DIR"
xcrun vtool -show-build "$APP_DIR/StremioEnhancerHarness"
xcrun otool -L "$APP_DIR/StremioEnhancerHarness"
