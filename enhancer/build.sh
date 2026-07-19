#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT_DIR/enhancer/StremioPlayerEnhancer.m"
OUTPUT="$ROOT_DIR/artifacts/StremioPlayerEnhancer.dylib"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MODULE_CACHE="$ROOT_DIR/enhancer/build/ModuleCache"

mkdir -p "$ROOT_DIR/artifacts" "$MODULE_CACHE"

xcrun --sdk iphoneos clang \
  -arch arm64 \
  -fobjc-arc \
  -fmodules \
  -fmodules-cache-path="$MODULE_CACHE" \
  -Wall \
  -Wextra \
  -Werror \
  -dynamiclib \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=13.0 \
  -framework Foundation \
  -framework UIKit \
  -framework AVKit \
  -Wl,-dead_strip \
  -Wl,-install_name,@rpath/StremioPlayerEnhancer.dylib \
  -o "$OUTPUT" \
  "$SOURCE"

codesign --force --sign - "$OUTPUT"

echo "Built $OUTPUT"
xcrun lipo -info "$OUTPUT"
shasum -a 256 "$OUTPUT"
