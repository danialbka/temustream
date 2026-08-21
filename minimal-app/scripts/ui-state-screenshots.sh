#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-/private/tmp/stremio-skeleton-build}"
BUILD_DIR="$BUILD_ROOT/ui-state-simulator"
APP_DIR="$BUILD_DIR/StremioSkeletonUIStates.app"
SERVER_DIR="$ROOT_DIR/build/ui-state-server"
OUTPUT_DIR="${UI_SCREENSHOT_OUTPUT_DIR:-$ROOT_DIR/build/ui-states}"
MODULE_CACHE="$ROOT_DIR/build/ModuleCacheUIStates"
PORT=18766

rm -rf "$APP_DIR" "$SERVER_DIR" "$OUTPUT_DIR"
mkdir -p "$APP_DIR" "$SERVER_DIR" "$OUTPUT_DIR" "$MODULE_CACHE"
cp "$ROOT_DIR/iOS/Resources/Info.plist" "$APP_DIR/Info.plist"
plutil -replace CFBundleExecutable -string StremioSkeletonUIStates "$APP_DIR/Info.plist"
plutil -replace CFBundleIdentifier -string local.stremio.skeleton.uistates "$APP_DIR/Info.plist"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIMULATOR_ARCH="${SIMULATOR_ARCH:-$(uname -m)}"
SOURCES="$(find "$ROOT_DIR/Sources/StremioSkeletonCore" "$ROOT_DIR/iOS/App" \
  -name '*.swift' ! -name 'StremioSkeletonApp.swift' -print)"

# shellcheck disable=SC2086
xcrun --sdk iphonesimulator swiftc \
  -target "$SIMULATOR_ARCH-apple-ios16.0-simulator" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -parse-as-library \
  -D SKELETON_SCREENSHOT_HARNESS \
  -O \
  -whole-module-optimization \
  -framework AVFoundation \
  -framework AVKit \
  -framework Combine \
  -framework Security \
  -framework SwiftUI \
  -o "$APP_DIR/StremioSkeletonUIStates" \
  $SOURCES

xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
cp -R "$ROOT_DIR/Fixtures/." "$SERVER_DIR/"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 4 -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -movflags +faststart "$SERVER_DIR/sample.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0xE8752D:size=600x900" -frames:v 1 \
  "$SERVER_DIR/ui-states/poster-portrait.png"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x36558F:size=900x600" -frames:v 1 \
  "$SERVER_DIR/ui-states/poster-wide.png"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=0x408D72:size=500x1000" -frames:v 1 \
  "$SERVER_DIR/ui-states/poster-tall.png"

python3 "$ROOT_DIR/scripts/range_server.py" "$PORT" "$SERVER_DIR" \
  >"$ROOT_DIR/build/ui-state-server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM

ATTEMPT=0
while ! curl -fsS "http://127.0.0.1:$PORT/ui-states/cinemeta/manifest.json" >/dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge 30 ]; then
    echo "UI-state fixture server did not start" >&2
    exit 1
  fi
  sleep 0.1
done

DEVICE_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name == "iPhone 17 Pro")][0].udid // [.devices[][] | select(.name | startswith("iPhone"))][0].udid')}"
if [ -z "$DEVICE_ID" ]; then
  echo "No iPhone simulator is available" >&2
  exit 1
fi

xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE_ID" -b

ALL_STATES="catalog-loading home-cinemeta home-letterboxd catalog-error details-streams library-empty library-synced addons-offline account-signed-out account-signed-in torrent-starting playback-unavailable player-active"
STATES="${UI_SCREENSHOT_STATES:-$ALL_STATES}"
for STATE in $STATES; do
  xcrun simctl terminate "$DEVICE_ID" local.stremio.skeleton.uistates 2>/dev/null || true
  xcrun simctl uninstall "$DEVICE_ID" local.stremio.skeleton.uistates 2>/dev/null || true
  xcrun simctl install "$DEVICE_ID" "$APP_DIR"
  RUN_ID="$(date +%s)-$$-$STATE"

  CINEMETA_URL="http://127.0.0.1:$PORT/ui-states/cinemeta/manifest.json"
  if [ "$STATE" = "catalog-error" ]; then
    CINEMETA_URL="http://127.0.0.1:$PORT/ui-states/missing/manifest.json"
  fi

  LAUNCH_ARGS=""
  if [ "$STATE" = "home-letterboxd" ]; then
    LAUNCH_ARGS="-selectedCatalogSource letterboxd"
  fi

  # shellcheck disable=SC2086
  SIMCTL_CHILD_UI_SCREENSHOT_STATE="$STATE" \
  SIMCTL_CHILD_UI_SCREENSHOT_RUN_ID="$RUN_ID" \
  SIMCTL_CHILD_SKELETON_ADDON_URL="$CINEMETA_URL" \
  SIMCTL_CHILD_SKELETON_LETTERBOXD_ADDON_URL="http://127.0.0.1:$PORT/ui-states/letterboxd/manifest.json" \
  SIMCTL_CHILD_SKELETON_CINEMETA_CATALOG_ID="top" \
  SIMCTL_CHILD_SKELETON_LETTERBOXD_CATALOG_ID="letterboxd-popular" \
  SIMCTL_CHILD_SKELETON_API_URL="http://127.0.0.1:$PORT" \
  SIMCTL_CHILD_SKELETON_STREAMING_SERVER_URL="http://127.0.0.1:$PORT" \
  xcrun simctl launch "$DEVICE_ID" local.stremio.skeleton.uistates $LAUNCH_ARGS >/dev/null

  ATTEMPT=0
  while [ "$ATTEMPT" -lt 25 ]; do
    LOGS="$(xcrun simctl spawn "$DEVICE_ID" log show --last 1m --style compact \
      --predicate "process == \"StremioSkeletonUIStates\" AND eventMessage CONTAINS \"[UIState:$RUN_ID:$STATE]\"" 2>/dev/null || true)"
    if echo "$LOGS" | grep -q "READY"; then
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 0.4
  done
  if [ "$ATTEMPT" -ge 25 ]; then
    echo "Timed out waiting for UI state: $STATE" >&2
    exit 1
  fi

  xcrun simctl io "$DEVICE_ID" screenshot "$OUTPUT_DIR/$STATE.png" >/dev/null
  test -s "$OUTPUT_DIR/$STATE.png"
  echo "Captured $STATE.png"
done

COUNT=0
for STATE in $STATES; do
  test -s "$OUTPUT_DIR/$STATE.png"
  COUNT=$((COUNT + 1))
done
sips -g pixelWidth -g pixelHeight "$OUTPUT_DIR"/*.png >"$OUTPUT_DIR/dimensions.txt"
cp "$ROOT_DIR/UI_STATE_MATRIX.md" "$OUTPUT_DIR/README.md"

if [ "$STATES" = "$ALL_STATES" ]; then
  test "$COUNT" -eq 13
  ffmpeg -hide_banner -loglevel error -y \
  -i "$OUTPUT_DIR/catalog-loading.png" \
  -i "$OUTPUT_DIR/home-cinemeta.png" \
  -i "$OUTPUT_DIR/home-letterboxd.png" \
  -i "$OUTPUT_DIR/catalog-error.png" \
  -i "$OUTPUT_DIR/details-streams.png" \
  -i "$OUTPUT_DIR/library-empty.png" \
  -i "$OUTPUT_DIR/library-synced.png" \
  -i "$OUTPUT_DIR/addons-offline.png" \
  -i "$OUTPUT_DIR/account-signed-out.png" \
  -i "$OUTPUT_DIR/account-signed-in.png" \
  -i "$OUTPUT_DIR/torrent-starting.png" \
  -i "$OUTPUT_DIR/playback-unavailable.png" \
  -i "$OUTPUT_DIR/player-active.png" \
  -filter_complex '[0:v]scale=201:437[s0];[1:v]scale=201:437[s1];[2:v]scale=201:437[s2];[3:v]scale=201:437[s3];[4:v]scale=201:437[s4];[5:v]scale=201:437[s5];[6:v]scale=201:437[s6];[7:v]scale=201:437[s7];[8:v]scale=201:437[s8];[9:v]scale=201:437[s9];[10:v]scale=201:437[s10];[11:v]scale=201:437[s11];[12:v]scale=201:437[s12];[s0][s1][s2][s3][s4][s5][s6][s7][s8][s9][s10][s11][s12]xstack=inputs=13:layout=0_0|201_0|402_0|603_0|0_437|201_437|402_437|603_437|0_874|201_874|402_874|603_874|0_1311:fill=black[out]' \
    -map '[out]' -frames:v 1 "$OUTPUT_DIR/all-states-contact-sheet.png"
  test -s "$OUTPUT_DIR/all-states-contact-sheet.png"
  echo "UI STATE SCREENSHOTS PASS: $COUNT state PNGs + contact sheet in $OUTPUT_DIR"
else
  echo "UI STATE SCREENSHOTS PASS: $COUNT selected state PNG(s) in $OUTPUT_DIR"
fi
