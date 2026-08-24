#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-/private/tmp/stremio-skeleton-build}"
BUILD_DIR="$BUILD_ROOT/ui-state-simulator"
APP_DIR="$BUILD_DIR/StremioSkeletonUIStates.app"
SERVER_DIR="$ROOT_DIR/build/ui-state-server"
OUTPUT_DIR="${UI_SCREENSHOT_OUTPUT_DIR:-$ROOT_DIR/build/ui-states}"
# Keep compiler caches off iCloud-backed workspaces. Swift's Clang importer can
# otherwise spend minutes waiting on FileProvider while emitting the bridging PCH.
MODULE_CACHE="${SKELETON_UI_MODULE_CACHE:-$BUILD_ROOT/ui-state-module-cache}"
PORT=18766
# A cold Simulator can spend over a minute restoring graphics/compiler state
# before the fixture app reaches its first SwiftUI task. Keep this harness gate
# bounded, but do not mistake that cold boot for an app-state failure.
READY_ATTEMPTS="${UI_SCREENSHOT_READY_ATTEMPTS:-600}"

BUILD_OUTPUT_ROOT="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$ROOT_DIR/build")"
OUTPUT_DIR="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$OUTPUT_DIR")"
case "$OUTPUT_DIR" in
  "$BUILD_OUTPUT_ROOT"/*) ;;
  *)
    echo "UI_SCREENSHOT_OUTPUT_DIR must resolve inside $BUILD_OUTPUT_ROOT" >&2
    exit 1
    ;;
esac

rm -rf "$APP_DIR" "$SERVER_DIR" "$OUTPUT_DIR"
mkdir -p "$APP_DIR" "$SERVER_DIR" "$OUTPUT_DIR" "$MODULE_CACHE"
cp "$ROOT_DIR/iOS/Resources/Info.plist" "$APP_DIR/Info.plist"
plutil -replace CFBundleExecutable -string StremioSkeletonUIStates "$APP_DIR/Info.plist"
plutil -replace CFBundleIdentifier -string local.stremio.skeleton.uistates "$APP_DIR/Info.plist"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIMULATOR_ARCH="${SIMULATOR_ARCH:-$(uname -m)}"
RUST_FRAMEWORK="$ROOT_DIR/build/dependencies/StremioPlaybackCore.xcframework"
RUST_SLICE="$(find "$RUST_FRAMEWORK" -maxdepth 1 -type d -name '*-simulator' -print -quit 2>/dev/null || true)"
if [ -z "$RUST_SLICE" ] || [ ! -f "$RUST_SLICE/libstremio_playback_core.a" ]; then
  "$ROOT_DIR/scripts/build-rust-core.sh"
  RUST_SLICE="$(find "$RUST_FRAMEWORK" -maxdepth 1 -type d -name '*-simulator' -print -quit)"
fi
SOURCES="$(find "$ROOT_DIR/Sources/StremioSkeletonCore" "$ROOT_DIR/iOS/App" \
  -name '*.swift' ! -name 'StremioSkeletonApp.swift' \
  ! -name 'BunnyPlayerView.swift' \
  ! -name 'PlaybackAudioSession.swift' \
  ! -name 'WatchTogetherModel.swift' \
  ! -name 'WatchTogetherViews.swift' -print)"

# shellcheck disable=SC2086
xcrun --sdk iphonesimulator swiftc \
  -target "$SIMULATOR_ARCH-apple-ios16.0-simulator" \
  -sdk "$SDK_PATH" \
  -module-cache-path "$MODULE_CACHE" \
  -import-objc-header "$ROOT_DIR/iOS/App/StremioSkeleton-Bridging-Header.h" \
  -I "$RUST_SLICE/Headers" \
  -parse-as-library \
  -D SKELETON_SCREENSHOT_HARNESS \
  -O \
  -whole-module-optimization \
  -framework AVFoundation \
  -framework AVKit \
  -framework Combine \
  -framework SafariServices \
  -framework Security \
  -framework SwiftUI \
  "$RUST_SLICE/libstremio_playback_core.a" \
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
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=1" -vf "hue=h=12" -frames:v 1 \
  "$SERVER_DIR/ui-states/episode-1.png"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=1" -vf "hue=h=82" -frames:v 1 \
  "$SERVER_DIR/ui-states/episode-2.png"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=1" -vf "hue=h=156" -frames:v 1 \
  "$SERVER_DIR/ui-states/episode-3.png"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=640x360:rate=1" -vf "hue=h=238" -frames:v 1 \
  "$SERVER_DIR/ui-states/episode-4.png"

python3 "$ROOT_DIR/scripts/range_server.py" "$PORT" "$SERVER_DIR" \
  >"$ROOT_DIR/build/ui-state-server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM

ATTEMPT=0
while ! curl -fsS "http://127.0.0.1:$PORT/ui-states/cinemeta/manifest.json" >/dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge 100 ]; then
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
xcrun simctl uninstall "$DEVICE_ID" local.stremio.skeleton.uistates 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP_DIR"

ALL_STATES="catalog-loading home-cinemeta home-letterboxd home-series catalog-error details-streams details-resume details-series-episodes episode-streams library-empty library-synced addons-offline account-signed-out account-signed-in torrent-starting playback-unavailable player-active settings-subtitles"
STATES="${UI_SCREENSHOT_STATES:-$ALL_STATES}"
for STATE in $STATES; do
  RUN_ID="$(date +%s)-$$-$STATE"

  CINEMETA_URL="http://127.0.0.1:$PORT/ui-states/cinemeta/manifest.json"
  if [ "$STATE" = "catalog-error" ]; then
    CINEMETA_URL="http://127.0.0.1:$PORT/ui-states/missing/manifest.json"
  fi

  LAUNCH_ARGS="-selectedCatalogSource cinemeta"
  if [ "$STATE" = "home-letterboxd" ]; then
    LAUNCH_ARGS="-selectedCatalogSource letterboxd"
  elif [ "$STATE" = "home-series" ]; then
    LAUNCH_ARGS="-selectedCatalogSource cinemeta-series"
  fi

  APPEARANCE_MODE="dark"
  ACCENT_PRESET="orange"
  CUSTOM_ACCENT_HEX="FF9500"
  if [ "$STATE" = "settings-appearance-light" ]; then
    APPEARANCE_MODE="light"
    ACCENT_PRESET="blue"
  elif [ "$STATE" = "home-light-custom-theme" ]; then
    APPEARANCE_MODE="light"
    ACCENT_PRESET="custom"
    CUSTOM_ACCENT_HEX="7C4DFF"
  fi

  BRIDGE_FAILURES=""
  FAILOVER_COUNTDOWN_SECONDS=""
  if [ "$STATE" = "stream-failover-countdown" ]; then
    BRIDGE_FAILURES="bunny"
    # Simulator cold-start work can delay the harness marker. Keep this
    # fixture visible long enough to capture the actual recovery card.
    FAILOVER_COUNTDOWN_SECONDS="30"
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
  SIMCTL_CHILD_SKELETON_APPEARANCE_MODE="$APPEARANCE_MODE" \
  SIMCTL_CHILD_SKELETON_ACCENT_PRESET="$ACCENT_PRESET" \
  SIMCTL_CHILD_SKELETON_CUSTOM_ACCENT_HEX="$CUSTOM_ACCENT_HEX" \
  SIMCTL_CHILD_SKELETON_PLAYER_BRIDGE_FAIL="$BRIDGE_FAILURES" \
  SIMCTL_CHILD_SKELETON_FAILOVER_TEST_COUNTDOWN_SECONDS="$FAILOVER_COUNTDOWN_SECONDS" \
  xcrun simctl launch --terminate-running-process \
    "$DEVICE_ID" local.stremio.skeleton.uistates $LAUNCH_ARGS >/dev/null

  DATA_CONTAINER="$(xcrun simctl get_app_container \
    "$DEVICE_ID" local.stremio.skeleton.uistates data)"
  READY_MARKER="$DATA_CONTAINER/tmp/ui-state-$RUN_ID.ready"
  ATTEMPT=0
  while [ "$ATTEMPT" -lt "$READY_ATTEMPTS" ] && [ ! -f "$READY_MARKER" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    sleep 0.2
  done
  if [ ! -f "$READY_MARKER" ]; then
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
  test "$COUNT" -eq 18
  ffmpeg -hide_banner -loglevel error -y \
  -i "$OUTPUT_DIR/catalog-loading.png" \
  -i "$OUTPUT_DIR/home-cinemeta.png" \
  -i "$OUTPUT_DIR/home-letterboxd.png" \
  -i "$OUTPUT_DIR/home-series.png" \
  -i "$OUTPUT_DIR/catalog-error.png" \
  -i "$OUTPUT_DIR/details-streams.png" \
  -i "$OUTPUT_DIR/details-resume.png" \
  -i "$OUTPUT_DIR/details-series-episodes.png" \
  -i "$OUTPUT_DIR/episode-streams.png" \
  -i "$OUTPUT_DIR/library-empty.png" \
  -i "$OUTPUT_DIR/library-synced.png" \
  -i "$OUTPUT_DIR/addons-offline.png" \
  -i "$OUTPUT_DIR/account-signed-out.png" \
  -i "$OUTPUT_DIR/account-signed-in.png" \
  -i "$OUTPUT_DIR/torrent-starting.png" \
  -i "$OUTPUT_DIR/playback-unavailable.png" \
  -i "$OUTPUT_DIR/player-active.png" \
  -i "$OUTPUT_DIR/settings-subtitles.png" \
  -filter_complex '[0:v]scale=201:437[s0];[1:v]scale=201:437[s1];[2:v]scale=201:437[s2];[3:v]scale=201:437[s3];[4:v]scale=201:437[s4];[5:v]scale=201:437[s5];[6:v]scale=201:437[s6];[7:v]scale=201:437[s7];[8:v]scale=201:437[s8];[9:v]scale=201:437[s9];[10:v]scale=201:437[s10];[11:v]scale=201:437[s11];[12:v]scale=201:437[s12];[13:v]scale=201:437[s13];[14:v]scale=201:437[s14];[15:v]scale=201:437[s15];[16:v]scale=201:437[s16];[17:v]scale=201:437[s17];[s0][s1][s2][s3][s4][s5][s6][s7][s8][s9][s10][s11][s12][s13][s14][s15][s16][s17]xstack=inputs=18:layout=0_0|201_0|402_0|603_0|0_437|201_437|402_437|603_437|0_874|201_874|402_874|603_874|0_1311|201_1311|402_1311|603_1311|0_1748|201_1748:fill=black[out]' \
    -map '[out]' -frames:v 1 "$OUTPUT_DIR/all-states-contact-sheet.png"
  test -s "$OUTPUT_DIR/all-states-contact-sheet.png"
  echo "UI STATE SCREENSHOTS PASS: $COUNT state PNGs + contact sheet in $OUTPUT_DIR"
else
  echo "UI STATE SCREENSHOTS PASS: $COUNT selected state PNG(s) in $OUTPUT_DIR"
fi
