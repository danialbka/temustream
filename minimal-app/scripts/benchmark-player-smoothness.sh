#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-/private/tmp/stremio-skeleton-build}"
APP_DIR="$BUILD_ROOT/simulator/StremioSkeleton.app"
BUNDLE_ID="local.stremio.skeleton"
DEVICE_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name == "iPhone 17 Pro")][0].udid')}"
FIXTURES="$ROOT_DIR/build/player-stress-server"
RESULTS="$ROOT_DIR/build/player-smoothness-results.jsonl"
REPORT="$ROOT_DIR/build/player-smoothness-report.json"
PORT="${SKELETON_PLAYER_STRESS_PORT:-18890}"

mkdir -p "$FIXTURES"
if [ ! -f "$FIXTURES/stress.mp4" ]; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=1280x720:rate=30' \
    -f lavfi -i 'sine=frequency=440:sample_rate=48000' \
    -t 60 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 60 \
    -c:a aac -movflags +faststart "$FIXTURES/stress.mp4"
fi
if [ ! -f "$FIXTURES/stress.m3u8" ]; then
  ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/stress.mp4" -c copy \
    -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 \
    -hls_fmp4_init_filename stress-init.mp4 \
    -hls_segment_filename "$FIXTURES/stress-%d.m4s" "$FIXTURES/stress.m3u8"
fi
if [ ! -f "$FIXTURES/stress-ts.m3u8" ]; then
  ffmpeg -hide_banner -loglevel error -y -i "$FIXTURES/stress.mp4" -c copy -t 30 \
    -hls_time 2 -hls_playlist_type vod -hls_segment_type mpegts \
    -hls_segment_filename "$FIXTURES/stress-ts-%d.ts" "$FIXTURES/stress-ts.m3u8"
fi
if [ ! -f "$FIXTURES/stress-av1-flac.mkv" ]; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=640x360:rate=24' \
    -f lavfi -i 'sine=frequency=660:sample_rate=48000' \
    -t 45 -c:v libsvtav1 -preset 11 -crf 42 -pix_fmt yuv420p \
    -c:a flac "$FIXTURES/stress-av1-flac.mkv"
fi
if [ ! -f "$FIXTURES/stress-audio.m4a" ]; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000' \
    -t 45 -c:a aac "$FIXTURES/stress-audio.m4a"
fi

python3 "$ROOT_DIR/scripts/range_server.py" "$PORT" "$FIXTURES" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM

"$ROOT_DIR/scripts/build-simulator.sh"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP_DIR"
: > "$RESULTS"

for CASE in \
  'direct-native|native|stress.mp4' \
  'hls-native|native|stress-ts.m3u8' \
  'mkv-av1-flac|ffmpeg|stress-av1-flac.mkv' \
  'audio-aac|ffmpeg|stress-audio.m4a'
do
  LABEL="${CASE%%|*}"
  REMAINDER="${CASE#*|}"
  ENGINE="${REMAINDER%%|*}"
  FILE="${REMAINDER#*|}"
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
  LAUNCH="$(
    SIMCTL_CHILD_SKELETON_PLAYER_STRESS_URL="http://127.0.0.1:$PORT/$FILE" \
    SIMCTL_CHILD_SKELETON_PLAYER_STRESS_ENGINE="$ENGINE" \
    xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
  )"
  PID="${LAUNCH##*: }"
  echo "Stress testing $LABEL (pid $PID)"

  ATTEMPT=0
  RESULT=""
  FAILED_RESULT=""
  while [ "$ATTEMPT" -lt 100 ]; do
    LOGS="$(xcrun simctl spawn "$DEVICE_ID" log show --last 3m --style compact \
      --predicate "processIdentifier == $PID AND eventMessage CONTAINS \"PLAYER_STRESS\"" \
      2>/dev/null || true)"
    RESULT="$(printf '%s\n' "$LOGS" | sed -n 's/.*PLAYER_STRESS PASS //p' | tail -1)"
    if [ -n "$RESULT" ]; then break; fi
    FAILED_RESULT="$(printf '%s\n' "$LOGS" | sed -n 's/.*PLAYER_STRESS FAIL //p' | tail -1)"
    if [ -n "$FAILED_RESULT" ]; then break; fi
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
  done
  if [ -n "$RESULT" ]; then
    printf '%s\n' "$RESULT" | jq -c --arg case "$LABEL" '. + {case: $case}' >> "$RESULTS"
  elif [ -n "$FAILED_RESULT" ]; then
    if printf '%s\n' "$FAILED_RESULT" | jq -e . >/dev/null 2>&1; then
      printf '%s\n' "$FAILED_RESULT" | jq -c --arg case "$LABEL" \
        '. + {case: $case, error: "Strict player thresholds failed"}' >> "$RESULTS"
    else
      jq -nc --arg case "$LABEL" --arg error "$FAILED_RESULT" \
        '{case: $case, error: $error}' >> "$RESULTS"
    fi
  else
    jq -nc --arg case "$LABEL" --arg error "Stress test failed or terminated" \
      '{case: $case, error: $error}' >> "$RESULTS"
  fi
done

jq -s '{generatedAt: (now | todateiso8601), tests: ., passed: (map(has("error") | not) | all)}' \
  "$RESULTS" > "$REPORT"
jq '{passed, tests: [.tests[] | {case,startupMilliseconds,seekMedianMilliseconds,seekP95Milliseconds,successfulSeeks,seekAttempts,successfulPauseResumes,pauseResumeAttempts,stalledIntervals,bufferingTransitions,droppedVideoFrames,realTimeRatio,renderedVideoFrame,error}]}' "$REPORT"
test "$(jq -r '.passed' "$REPORT")" = true
