#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"
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
if [ ! -f "$FIXTURES/stress-h264-aac.mkv" ]; then
  # Exercise Bunny's production Matroska path with a film-rate cadence and
  # reordered B-frames. MP4/HLS belong to AVPlayer and are intentionally not
  # fed into the Rust EBML demuxer by this benchmark.
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=1280x720:rate=24000/1001' \
    -f lavfi -i 'sine=frequency=520:sample_rate=48000' \
    -t 60 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
    -g 48 -bf 3 -c:a aac -b:a 192k "$FIXTURES/stress-h264-aac.mkv"
fi
if [ ! -f "$FIXTURES/stress-h264-aac-no-bframes.mkv" ]; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'testsrc2=size=1280x720:rate=24000/1001' \
    -f lavfi -i 'sine=frequency=520:sample_rate=48000' \
    -t 60 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p \
    -g 48 -bf 0 -c:a aac -b:a 192k "$FIXTURES/stress-h264-aac-no-bframes.mkv"
fi
if [ ! -f "$FIXTURES/stress-audio.m4a" ]; then
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i 'sine=frequency=880:sample_rate=48000' \
    -t 45 -c:a aac "$FIXTURES/stress-audio.m4a"
fi

python3 "$ROOT_DIR/scripts/range_server.py" "$PORT" "$FIXTURES" >/dev/null 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT INT TERM
sleep 0.2
if ! kill -0 "$SERVER_PID" 2>/dev/null \
  || ! curl --fail --silent --show-error --max-time 3 \
    "http://127.0.0.1:$PORT/heartbeat" >/dev/null; then
  echo "Player stress server could not start on port $PORT" >&2
  echo "Set SKELETON_PLAYER_STRESS_PORT to an unused local port and retry." >&2
  exit 1
fi

"$ROOT_DIR/scripts/build-simulator.sh"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP_DIR"
DATA_DIR="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)"
ARTIFACT="$DATA_DIR/Documents/player-stress-result.json"
: > "$RESULTS"

for CASE in \
  'mkv-h264-aac-film-cadence|stress-h264-aac.mkv' \
  'mkv-h264-aac-no-bframes|stress-h264-aac-no-bframes.mkv'
do
  LABEL="${CASE%%|*}"
  FILE="${CASE#*|}"
  if [ -n "${SKELETON_PLAYER_STRESS_CASE:-}" ] \
    && [ "$LABEL" != "$SKELETON_PLAYER_STRESS_CASE" ]; then
    continue
  fi
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
  rm -f "$ARTIFACT"
  LAUNCH="$(
    SIMCTL_CHILD_SKELETON_PLAYER_STRESS_URL="http://127.0.0.1:$PORT/$FILE" \
    SIMCTL_CHILD_SKELETON_PLAYER_STRESS_BENCHMARK=1 \
    SIMCTL_CHILD_SKELETON_PLAYER_STRESS_VISIBLE=1 \
    SIMCTL_CHILD_SKELETON_PLAYER_STRESS_CADENCE_ONLY=1 \
    xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
  )"
  PID="${LAUNCH##*: }"
  echo "Stress testing $LABEL (pid $PID)"

  ATTEMPT=0
  while [ "$ATTEMPT" -lt 100 ] && [ ! -s "$ARTIFACT" ]; do
    if ! kill -0 "$PID" 2>/dev/null; then break; fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
  done
  if [ -s "$ARTIFACT" ] && jq -e . "$ARTIFACT" >/dev/null 2>&1; then
    jq -c --arg case "$LABEL" '
      if .metrics then
        .metrics + {case: $case}
          + (if .passed then {} else {error: "Strict player thresholds failed"} end)
      else
        {case: $case, error: (.error // "Player stress failed")}
      end
    ' "$ARTIFACT" >> "$RESULTS"
  else
    jq -nc --arg case "$LABEL" --arg error "Stress result artifact was not produced" \
      '{case: $case, error: $error}' >> "$RESULTS"
  fi
done

jq -s '{generatedAt: (now | todateiso8601), tests: ., passed: (map(has("error") | not) | all)}' \
  "$RESULTS" > "$REPORT"
jq '{passed, tests: [.tests[] | {case,startupMilliseconds,seekMedianMilliseconds,seekP95Milliseconds,successfulSeeks,seekAttempts,successfulPauseResumes,pauseResumeAttempts,videoUnderflowIntervals,videoQueueStateTransitions,enqueuedVideoFPS,presentedVideoFPS,droppedVideoFrames,corruptedVideoFrames,averageFrameDelayMilliseconds,sourcePTSP95Milliseconds,sourcePTSBackwardTransitions,displayRefreshHz,displayP95IntervalMilliseconds,displayMissedRefreshes,realTimeRatio,renderedVideoFrame,error}]}' "$REPORT"
test "$(jq -r '.passed' "$REPORT")" = true
