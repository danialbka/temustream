#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE_IPA="${1:-$ROOT_DIR/artifacts/stremio_iOS-2.0.3-18.ipa}"
ENHANCER="$ROOT_DIR/artifacts/StremioPlayerEnhancer.dylib"
OUTPUT_IPA="${2:-}"
BUILD_DIR="$ROOT_DIR/enhancer/build"
INSERT_TOOL="$BUILD_DIR/insert_dylib"
EXPECTED_IPA_SHA="${3:-f23c50e52756d90573c3328d7f5bb2bc5930b1fe478bf7318013d83a80cfd37a}"
EXPECTED_ENHANCER_SHA="dfa6a4de7d89eb1378ccec2c9c5bf4e5c38048f3b4fe607cbd90d8e110b0e5cb"
LOAD_PATH="@executable_path/Frameworks/StremioPlayerEnhancer.dylib"

[ -f "$SOURCE_IPA" ] || {
  echo "Source IPA not found: $SOURCE_IPA" >&2
  exit 1
}

actual_ipa_sha="$(shasum -a 256 "$SOURCE_IPA" | awk '{print $1}')"
actual_enhancer_sha="$(shasum -a 256 "$ENHANCER" | awk '{print $1}')"
[ "$actual_ipa_sha" = "$EXPECTED_IPA_SHA" ] || {
  echo "Official IPA checksum mismatch: $actual_ipa_sha" >&2
  exit 1
}
[ "$actual_enhancer_sha" = "$EXPECTED_ENHANCER_SHA" ] || {
  echo "V7 enhancer checksum mismatch: $actual_enhancer_sha" >&2
  exit 1
}

mkdir -p "$BUILD_DIR"
xcrun clang -std=c11 -Wall -Wextra -Werror \
  "$ROOT_DIR/enhancer/insert_dylib.c" -o "$INSERT_TOOL"

PACKAGE_DIR="$(mktemp -d /tmp/stremio-v7-package.XXXXXX)"
trap 'rm -rf "$PACKAGE_DIR"' EXIT HUP INT TERM
unzip -q "$SOURCE_IPA" -d "$PACKAGE_DIR"

APP_DIR="$PACKAGE_DIR/Payload/Stremio.app"
INFO_PLIST="$APP_DIR/Info.plist"
EXECUTABLE="$APP_DIR/Stremio"
FRAMEWORKS_DIR="$APP_DIR/Frameworks"

[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" = \
  "com.stremio.pal" ]
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
MINIMUM_IOS="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$INFO_PLIST")"
[ -n "$APP_VERSION" ]
[ -n "$APP_BUILD" ]
[ -n "$MINIMUM_IOS" ]

if [ -z "$OUTPUT_IPA" ]; then
  OUTPUT_IPA="$ROOT_DIR/artifacts/Stremio-$APP_VERSION-$APP_BUILD-V7-PiP.ipa"
fi

# Fail closed when an upstream player refactor removes any runtime entry point
# used by the V7 rotation/PiP extension.
for required_runtime_name in \
  '_TtC7Stremio17VideoControlsView' \
  '_TtC7Stremio20PlayerViewController' \
  'pictureInPictureButton' \
  'onPipClicked:' \
  'useVLCKit' \
  'useAVPlayer' \
  'anyRotationOnVideo'; do
  strings "$EXECUTABLE" | grep -Fq "$required_runtime_name" || {
    echo "Incompatible Stremio runtime: missing $required_runtime_name" >&2
    exit 1
  }
done

KSPLAYER_BINARY="$FRAMEWORKS_DIR/KSPlayer.framework/KSPlayer"
for required_ks_symbol in \
  'KSMEPlayerC15enterBackgroundyyF' \
  'KSMEPlayerC15enterForegroundyyF' \
  'KSMEPlayerC9configPIPyyF' \
  'KSPictureInPictureControllerC5start5layery'; do
  nm -gU "$KSPLAYER_BINARY" | grep -Fq "$required_ks_symbol" || {
    echo "Incompatible KSPlayer runtime: missing $required_ks_symbol" >&2
    exit 1
  }
done

cp -f "$ENHANCER" "$FRAMEWORKS_DIR/StremioPlayerEnhancer.dylib"
chmod 0755 "$FRAMEWORKS_DIR/StremioPlayerEnhancer.dylib"
"$INSERT_TOOL" "$LOAD_PATH" "$EXECUTABLE"

if /usr/libexec/PlistBuddy -c 'Print :StremioEnhancerVersion' "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c 'Set :StremioEnhancerVersion 7' "$INFO_PLIST"
else
  /usr/libexec/PlistBuddy -c 'Add :StremioEnhancerVersion string 7' "$INFO_PLIST"
fi
if /usr/libexec/PlistBuddy -c 'Print :StremioEnhancerSHA256' "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c \
    "Set :StremioEnhancerSHA256 $EXPECTED_ENHANCER_SHA" "$INFO_PLIST"
else
  /usr/libexec/PlistBuddy -c \
    "Add :StremioEnhancerSHA256 string $EXPECTED_ENHANCER_SHA" "$INFO_PLIST"
fi
if /usr/libexec/PlistBuddy -c 'Print :StremioEnhancerSourceSHA256' "$INFO_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c \
    "Set :StremioEnhancerSourceSHA256 $EXPECTED_IPA_SHA" "$INFO_PLIST"
else
  /usr/libexec/PlistBuddy -c \
    "Add :StremioEnhancerSourceSHA256 string $EXPECTED_IPA_SHA" "$INFO_PLIST"
fi
xattr -cr "$APP_DIR"

# Normalize archive metadata so rebuilding identical inputs produces the same
# IPA bytes and checksum. -X omits host-specific extended ZIP attributes.
find "$PACKAGE_DIR/Payload" -exec touch -h -t 202607190000 {} +
rm -f "$OUTPUT_IPA"
(cd "$PACKAGE_DIR" && zip -Xqry "$OUTPUT_IPA" Payload)
unzip -tq "$OUTPUT_IPA"

echo "Built $OUTPUT_IPA"
echo "Upstream Stremio $APP_VERSION ($APP_BUILD), minimum iOS $MINIMUM_IOS"
shasum -a 256 "$OUTPUT_IPA"
stat -f '%z bytes' "$OUTPUT_IPA"
