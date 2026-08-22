#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SERVER_DIR="$ROOT_DIR/build/e2e-server"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-/private/tmp/stremio-skeleton-build}"
BASE_APP_DIR="$BUILD_ROOT/simulator/StremioSkeleton.app"
APP_DIR="$BUILD_ROOT/e2e-simulator/StremioSkeletonE2E.app"
BUNDLE_ID="local.stremio.skeleton.e2e"
PORT=18765
TORRENT_SERVER_URL="${SKELETON_E2E_TORRENT_SERVER_URL:-http://127.0.0.1:$PORT}"

if [ "${SKELETON_SKIP_SIMULATOR_BUILD:-0}" != "1" ]; then
  "$ROOT_DIR/scripts/build-simulator.sh"
fi
if [ ! -d "$BASE_APP_DIR" ]; then
  echo "Simulator app is missing at $BASE_APP_DIR" >&2
  exit 1
fi

BACKGROUND_MODE="$(/usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes:0' "$BASE_APP_DIR/Info.plist")"
ORIENTATIONS="$(/usr/libexec/PlistBuddy -c 'Print :UISupportedInterfaceOrientations' "$BASE_APP_DIR/Info.plist")"
test "$BACKGROUND_MODE" = "audio"
echo "$ORIENTATIONS" | grep -q "UIInterfaceOrientationPortrait"
echo "$ORIENTATIONS" | grep -q "UIInterfaceOrientationLandscapeLeft"
echo "$ORIENTATIONS" | grep -q "UIInterfaceOrientationLandscapeRight"

rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
cp -R "$BASE_APP_DIR" "$APP_DIR"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP_DIR/Info.plist"
plutil -replace CFBundleDisplayName -string "Stremio Skeleton E2E" "$APP_DIR/Info.plist"
codesign --force --sign - "$APP_DIR"
rm -rf "$SERVER_DIR"
mkdir -p "$SERVER_DIR"
cp -R "$ROOT_DIR/Fixtures/." "$SERVER_DIR/"

ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "testsrc2=size=1280x720:rate=30" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t 4 -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -c:a aac -movflags +faststart "$SERVER_DIR/sample.mp4"

ffmpeg -hide_banner -loglevel error -y \
  -i "$SERVER_DIR/sample.mp4" -c copy \
  -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 \
  -hls_fmp4_init_filename sample-init.mp4 \
  -hls_segment_filename "$SERVER_DIR/sample-%d.m4s" \
  "$SERVER_DIR/sample.m3u8"

# Keep the compatibility-path vector deterministic; live SVT-AV1 encoding can
# deadlock on GitHub's macOS runners before the simulator even launches.
if ! base64 -D < "$SERVER_DIR/sample-av1-flac.mkv.b64" \
  > "$SERVER_DIR/sample-av1-flac.mkv" 2>/dev/null; then
  base64 --decode < "$SERVER_DIR/sample-av1-flac.mkv.b64" \
    > "$SERVER_DIR/sample-av1-flac.mkv"
fi

python3 "$ROOT_DIR/scripts/range_server.py" "$PORT" "$SERVER_DIR" \
  >"$ROOT_DIR/build/e2e-server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM

ATTEMPT=0
while ! curl -fsS -r 0-1 "http://127.0.0.1:$PORT/sample.mp4" >/dev/null 2>&1; do
  ATTEMPT=$((ATTEMPT + 1))
  if [ "$ATTEMPT" -ge 20 ]; then
    echo "Range fixture server did not start" >&2
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
xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP_DIR"
RUN_ID="$(date +%s)-$$"
SIMCTL_CHILD_SKELETON_E2E=1 \
SIMCTL_CHILD_SKELETON_E2E_RUN_ID="$RUN_ID" \
SIMCTL_CHILD_SKELETON_ADDON_URL="http://127.0.0.1:$PORT/manifest.json" \
SIMCTL_CHILD_SKELETON_LETTERBOXD_ADDON_URL="http://127.0.0.1:$PORT/letterboxd/manifest.json" \
SIMCTL_CHILD_SKELETON_API_URL="http://127.0.0.1:$PORT" \
SIMCTL_CHILD_SKELETON_STREAMING_SERVER_URL="$TORRENT_SERVER_URL" \
SIMCTL_CHILD_SKELETON_E2E_COMPATIBILITY_SERVER_URL="${SKELETON_E2E_COMPATIBILITY_SERVER_URL:-$TORRENT_SERVER_URL}" \
SIMCTL_CHILD_SKELETON_E2E_EMAIL="e2e@example.test" \
SIMCTL_CHILD_SKELETON_E2E_PASSWORD="fixture-only" \
xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"

ATTEMPT=0
while [ "$ATTEMPT" -lt 40 ]; do
  LOGS="$(xcrun simctl spawn "$DEVICE_ID" log show --last 2m --style compact \
    --predicate "process == \"StremioSkeleton\" AND eventMessage CONTAINS \"[SkeletonE2E:$RUN_ID]\"" 2>/dev/null || true)"
  if echo "$LOGS" | grep -q "\[SkeletonE2E:$RUN_ID\] PASS"; then
    xcrun simctl io "$DEVICE_ID" screenshot "$ROOT_DIR/build/e2e-pass.png"
    echo "$LOGS" | tail -n 3
    echo "E2E PASS: $ROOT_DIR/build/e2e-pass.png"
    exit 0
  fi
  if echo "$LOGS" | grep -q "\[SkeletonE2E:$RUN_ID\] FAIL"; then
    echo "$LOGS" | tail -n 5 >&2
    exit 1
  fi
  ATTEMPT=$((ATTEMPT + 1))
  sleep 1
done

echo "Timed out waiting for E2E result" >&2
exit 1
