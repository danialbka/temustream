#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"
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
BUILD_LOCK="${SKELETON_BUILD_LOCK:-$CACHE_ROOT/locks/xcode.lock}"
RETENTION_TOOL="$ROOT_DIR/scripts/build-cache-retention.sh"
SERVER_PID=""
STAGED_APP=""
PRODUCT_CACHE_REGISTERED=0

. "$ROOT_DIR/scripts/build-support.sh"

cleanup() {
  status=$?
  trap - EXIT INT TERM
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$STAGED_APP" ] && [ -d "$STAGED_APP" ]; then
    rm -rf "$STAGED_APP"
  fi
  if [ "$PRODUCT_CACHE_REGISTERED" -eq 1 ]; then
    stremio_release_build_cache "$RETENTION_TOOL" "$BUILD_ROOT"
  fi
  stremio_release_lock "$BUILD_LOCK"
  exit "$status"
}
trap cleanup EXIT INT TERM

stremio_acquire_lock "$BUILD_LOCK" "the Stremio screenshot build workspace" 900
stremio_register_build_cache "$RETENTION_TOOL" products "$BUILD_ROOT"
PRODUCT_CACHE_REGISTERED=1
stremio_prune_build_caches "$RETENTION_TOOL" --protect "$BUILD_ROOT"

BUILD_OUTPUT_ROOT="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$ROOT_DIR/build")"
OUTPUT_DIR="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$OUTPUT_DIR")"
case "$OUTPUT_DIR" in
  "$BUILD_OUTPUT_ROOT"/*) ;;
  *)
    echo "UI_SCREENSHOT_OUTPUT_DIR must resolve inside $BUILD_OUTPUT_ROOT" >&2
    exit 1
    ;;
esac

rm -rf "$OUTPUT_DIR"
mkdir -p "$BUILD_DIR" "$SERVER_DIR" "$OUTPUT_DIR" "$MODULE_CACHE"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SIMULATOR_ARCH="${SIMULATOR_ARCH:-$(uname -m)}"
RUST_FRAMEWORK="$ROOT_DIR/build/dependencies/StremioPlaybackCore.xcframework"
"$ROOT_DIR/scripts/build-rust-core.sh"
RUST_SLICE="$(find "$RUST_FRAMEWORK" -maxdepth 1 -type d -name '*-simulator' -print -quit)"
test -s "$RUST_SLICE/libstremio_playback_core.a"
SOURCES="$(find "$ROOT_DIR/Sources/StremioSkeletonCore" "$ROOT_DIR/iOS/App" \
  -name '*.swift' ! -name 'StremioSkeletonApp.swift' \
  ! -name 'BunnyPlayerView.swift' \
  ! -name 'PlaybackAudioSession.swift' \
  ! -name 'WatchTogetherModel.swift' \
  ! -name 'WatchTogetherViews.swift' -print)"

APP_SIGNATURE="$({
  printf '%s\n' "ui-state-harness-v2"
  xcrun --sdk iphonesimulator swiftc --version
  shasum -a 256 "$ROOT_DIR/iOS/Resources/Info.plist"
  shasum -a 256 "$RUST_SLICE/libstremio_playback_core.a"
  find "$ROOT_DIR/iOS/Resources/Assets.xcassets" -type f -print \
    | LC_ALL=C sort \
    | while IFS= read -r asset_file; do
        test -s "$asset_file"
        shasum -a 256 "$asset_file"
      done
  printf '%s\n' "$SOURCES" | LC_ALL=C sort | while IFS= read -r source_file; do
    test -s "$source_file"
    shasum -a 256 "$source_file"
  done
} | shasum -a 256 | awk '{print $1}')"
APP_STAMP="$APP_DIR/.stremio-ui-source-id"

if [ ! -s "$APP_DIR/StremioSkeletonUIStates" ] \
    || [ ! -f "$APP_STAMP" ] \
    || [ "$(cat "$APP_STAMP")" != "$APP_SIGNATURE" ] \
    || ! codesign --verify --strict "$APP_DIR" >/dev/null 2>&1; then
  STAGED_APP="$BUILD_DIR/.StremioSkeletonUIStates.app.tmp.$$"
  rm -rf "$STAGED_APP"
  mkdir -p "$STAGED_APP"
  cp "$ROOT_DIR/iOS/Resources/Info.plist" "$STAGED_APP/Info.plist"
  plutil -replace CFBundleExecutable -string StremioSkeletonUIStates "$STAGED_APP/Info.plist"
  plutil -replace CFBundleIdentifier -string local.stremio.skeleton.uistates "$STAGED_APP/Info.plist"

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
    -o "$STAGED_APP/StremioSkeletonUIStates" \
    $SOURCES
  test -s "$STAGED_APP/StremioSkeletonUIStates"
  ASSET_INFO_PLIST="$STAGED_APP/asset-catalog-info.plist"
  xcrun actool "$ROOT_DIR/iOS/Resources/Assets.xcassets" \
    --compile "$STAGED_APP" \
    --platform iphonesimulator \
    --minimum-deployment-target 16.0 \
    --target-device iphone \
    --target-device ipad \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO_PLIST" \
    >"$ROOT_DIR/build/ui-state-actool.log"
  test -s "$STAGED_APP/Assets.car"
  /usr/libexec/PlistBuddy -c "Merge $ASSET_INFO_PLIST" "$STAGED_APP/Info.plist"
  rm -f "$ASSET_INFO_PLIST"
  printf '%s\n' "$APP_SIGNATURE" > "$STAGED_APP/.stremio-ui-source-id"
  xattr -cr "$STAGED_APP"
  codesign --force --sign - "$STAGED_APP"
  codesign --verify --strict "$STAGED_APP"
  rm -rf "$APP_DIR"
  mv "$STAGED_APP" "$APP_DIR"
  echo "Built focused UI-state harness"
else
  echo "Reused focused UI-state harness"
fi

FIXTURE_SIGNATURE="$({
  printf '%s\n' "ui-state-fixtures-v4"
  find "$ROOT_DIR/Fixtures" -type f -print | LC_ALL=C sort | while IFS= read -r fixture_file; do
    test -s "$fixture_file"
    shasum -a 256 "$fixture_file"
  done
} | shasum -a 256 | awk '{print $1}')"
FIXTURE_STAMP="$SERVER_DIR/.stremio-fixture-source-id"
if [ ! -f "$FIXTURE_STAMP" ] || [ "$(cat "$FIXTURE_STAMP")" != "$FIXTURE_SIGNATURE" ]; then
  rm -rf "$SERVER_DIR"
  mkdir -p "$SERVER_DIR"
  cp -R "$ROOT_DIR/Fixtures/." "$SERVER_DIR/"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 4 -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -movflags +faststart "$SERVER_DIR/sample.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 16 -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -movflags +faststart "$SERVER_DIR/sample-autoplay.mp4"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc=size=640x360:rate=10" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 1201 -c:v libx264 -preset ultrafast -crf 34 -pix_fmt yuv420p \
  -g 20 -c:a aac -b:a 32k -movflags +faststart \
  "$SERVER_DIR/sample-content.mp4"
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
  printf '%s\n' "$FIXTURE_SIGNATURE" > "$FIXTURE_STAMP"
  echo "Built UI-state fixtures"
else
  echo "Reused UI-state fixtures"
fi

# Compilation and fixture mutation are complete. Do not serialize unrelated
# builds behind the Simulator's boot, launch, and screenshot work.
stremio_release_lock "$BUILD_LOCK"

python3 "$ROOT_DIR/scripts/range_server.py" "$PORT" "$SERVER_DIR" \
  >"$ROOT_DIR/build/ui-state-server.log" 2>&1 &
SERVER_PID=$!

ATTEMPT=0
while ! curl -fsS "http://127.0.0.1:$PORT/ui-states/cinemeta/manifest.json" >/dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge 100 ]; then
    echo "UI-state fixture server did not start" >&2
    exit 1
  fi
  sleep 0.1
done

ALL_STATES="catalog-loading home-cinemeta home-letterboxd home-series catalog-error details-streams details-resume details-cast-movie details-series-episodes details-cast-series episode-streams library-empty library-synced addons-offline account-signed-out account-signed-in torrent-starting playback-unavailable player-active settings-subtitles search-idle search-results profiles-picker"
STATES="${UI_SCREENSHOT_STATES:-$ALL_STATES}"

DEVICE_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name == "iPhone 17 Pro")][0].udid // [.devices[][] | select(.name | startswith("iPhone"))][0].udid')}"
if [ -z "$DEVICE_ID" ]; then
  echo "No iPhone simulator is available" >&2
  exit 1
fi

echo "Preparing Simulator: $DEVICE_ID"
stremio_run_bounded 30 "Simulator boot request" \
  xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
stremio_run_bounded 150 "Simulator boot readiness" \
  xcrun simctl bootstatus "$DEVICE_ID" -b
echo "Simulator ready"

INSTALLED_APP=""
if [ "${UI_SCREENSHOT_FRESH_INSTALL:-0}" != "1" ] && [ "$STATES" != "$ALL_STATES" ]; then
  if INSTALLED_APP="$(stremio_run_bounded 30 "installed UI harness lookup" \
      xcrun simctl get_app_container "$DEVICE_ID" \
        local.stremio.skeleton.uistates app 2>/dev/null)"; then
    :
  else
    INSTALLED_APP=""
  fi
fi

if [ -n "$INSTALLED_APP" ] \
    && [ -f "$INSTALLED_APP/.stremio-ui-source-id" ] \
    && [ "$(cat "$INSTALLED_APP/.stremio-ui-source-id")" = "$APP_SIGNATURE" ]; then
  echo "Reused installed UI-state harness"
else
  echo "Refreshing installed UI-state harness"
  stremio_run_bounded 45 "old UI harness uninstall" \
    xcrun simctl uninstall "$DEVICE_ID" local.stremio.skeleton.uistates 2>/dev/null || true
  stremio_run_bounded 60 "UI harness install" \
    xcrun simctl install "$DEVICE_ID" "$APP_DIR"
fi

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

  echo "Launching UI state: $STATE"
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
  stremio_run_bounded 60 "UI harness launch for $STATE" \
    xcrun simctl launch --terminate-running-process \
    "$DEVICE_ID" local.stremio.skeleton.uistates $LAUNCH_ARGS >/dev/null
  echo "Simulator accepted launch: $STATE"

  DATA_CONTAINER="$(stremio_run_bounded 30 "UI harness data-container lookup" \
    xcrun simctl get_app_container "$DEVICE_ID" \
      local.stremio.skeleton.uistates data)"
  READY_MARKER="$DATA_CONTAINER/tmp/ui-state-$RUN_ID.ready"
  ATTEMPT=0
  echo "Waiting for UI state: $STATE"
  while [ "$ATTEMPT" -lt "$READY_ATTEMPTS" ] && [ ! -f "$READY_MARKER" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    if [ $((ATTEMPT % 50)) -eq 0 ]; then
      echo "Still waiting for UI state: $STATE ($((ATTEMPT / 5))s)"
    fi
    sleep 0.2
  done
  if [ ! -f "$READY_MARKER" ]; then
    echo "Timed out waiting for UI state: $STATE" >&2
    exit 1
  fi

  stremio_run_bounded 60 "screenshot capture for $STATE" \
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
  test "$COUNT" -eq 23
  ffmpeg -hide_banner -loglevel error -y \
  -i "$OUTPUT_DIR/catalog-loading.png" \
  -i "$OUTPUT_DIR/home-cinemeta.png" \
  -i "$OUTPUT_DIR/home-letterboxd.png" \
  -i "$OUTPUT_DIR/home-series.png" \
  -i "$OUTPUT_DIR/catalog-error.png" \
  -i "$OUTPUT_DIR/details-streams.png" \
  -i "$OUTPUT_DIR/details-resume.png" \
  -i "$OUTPUT_DIR/details-cast-movie.png" \
  -i "$OUTPUT_DIR/details-series-episodes.png" \
  -i "$OUTPUT_DIR/details-cast-series.png" \
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
  -i "$OUTPUT_DIR/search-idle.png" \
  -i "$OUTPUT_DIR/search-results.png" \
  -i "$OUTPUT_DIR/profiles-picker.png" \
  -filter_complex '[0:v]scale=201:437[s0];[1:v]scale=201:437[s1];[2:v]scale=201:437[s2];[3:v]scale=201:437[s3];[4:v]scale=201:437[s4];[5:v]scale=201:437[s5];[6:v]scale=201:437[s6];[7:v]scale=201:437[s7];[8:v]scale=201:437[s8];[9:v]scale=201:437[s9];[10:v]scale=201:437[s10];[11:v]scale=201:437[s11];[12:v]scale=201:437[s12];[13:v]scale=201:437[s13];[14:v]scale=201:437[s14];[15:v]scale=201:437[s15];[16:v]scale=201:437[s16];[17:v]scale=201:437[s17];[18:v]scale=201:437[s18];[19:v]scale=201:437[s19];[20:v]scale=201:437[s20];[21:v]scale=201:437[s21];[22:v]scale=201:437[s22];[s0][s1][s2][s3][s4][s5][s6][s7][s8][s9][s10][s11][s12][s13][s14][s15][s16][s17][s18][s19][s20][s21][s22]xstack=inputs=23:layout=0_0|201_0|402_0|603_0|0_437|201_437|402_437|603_437|0_874|201_874|402_874|603_874|0_1311|201_1311|402_1311|603_1311|0_1748|201_1748|402_1748|603_1748|0_2185|201_2185|402_2185:fill=black[out]' \
    -map '[out]' -frames:v 1 "$OUTPUT_DIR/all-states-contact-sheet.png"
  test -s "$OUTPUT_DIR/all-states-contact-sheet.png"
  echo "UI STATE SCREENSHOTS PASS: $COUNT state PNGs + contact sheet in $OUTPUT_DIR"
else
  echo "UI STATE SCREENSHOTS PASS: $COUNT selected state PNG(s) in $OUTPUT_DIR"
fi
