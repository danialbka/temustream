#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
CACHE_ROOT="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
BUILD_ROOT="${SKELETON_BUILD_ROOT:-$CACHE_ROOT/products}"
APP_DIR="$BUILD_ROOT/simulator/StremioSkeleton.app"
BUNDLE_ID="local.stremio.skeleton"
DEVICE_ID="${SIMULATOR_ID:-$(xcrun simctl list devices available -j | jq -r '[.devices[][] | select(.name == "iPhone 17 Pro")][0].udid')}"
PARTS_DIR="$ROOT_DIR/build/obsession-stream-parts"
FINAL_REPORT="$ROOT_DIR/build/obsession-20-stream-torbox-report.json"

"$ROOT_DIR/scripts/build-simulator.sh"
xcrun simctl boot "$DEVICE_ID" 2>/dev/null || true
xcrun simctl install "$DEVICE_ID" "$APP_DIR"
DATA_DIR="$(xcrun simctl get_app_container "$DEVICE_ID" "$BUNDLE_ID" data)"

mkdir -p "$PARTS_DIR"
find "$PARTS_DIR" -type f -name 'obsession-stream-report-*.json' -delete

START=0
while [ "$START" -lt 20 ]; do
  END=$((START + 1))
  xcrun simctl terminate "$DEVICE_ID" "$BUNDLE_ID" 2>/dev/null || true
  LAUNCH_OUTPUT="$(
    SIMCTL_CHILD_SKELETON_OBSESSION_STREAM_STRESS=1 \
    SIMCTL_CHILD_SKELETON_OBSESSION_STREAM_START="$START" \
    SIMCTL_CHILD_SKELETON_OBSESSION_STREAM_COUNT=1 \
    xcrun simctl launch "$DEVICE_ID" "$BUNDLE_ID"
  )"
  PID="${LAUNCH_OUTPUT##*: }"
  echo "Benchmarking ranked streams $((START + 1))-$END (pid $PID)"

  ATTEMPT=0
  COMPLETED=0
  TERMINATED=0
  while [ "$ATTEMPT" -lt 150 ]; do
    LOGS="$(xcrun simctl spawn "$DEVICE_ID" log show --last 4m --style compact \
      --predicate "processIdentifier == $PID AND eventMessage CONTAINS \"OBSESSION_STREAM_STRESS\"" \
      2>/dev/null || true)"
    if echo "$LOGS" | grep -Eq 'OBSESSION_STREAM_STRESS (PASS|FAIL) available='; then
      COMPLETED=1
      break
    fi
    if ! kill -0 "$PID" 2>/dev/null; then
      TERMINATED=1
      break
    fi
    ATTEMPT=$((ATTEMPT + 1))
    sleep 1
  done

  PART_NAME="obsession-stream-report-$((START + 1))-$END.json"
  if [ "$COMPLETED" -eq 1 ] && [ -f "$DATA_DIR/Documents/$PART_NAME" ]; then
    cp "$DATA_DIR/Documents/$PART_NAME" "$PARTS_DIR/$PART_NAME"
  else
    FAILURE="Benchmark timed out before producing a result"
    if [ "$TERMINATED" -eq 1 ]; then
      FAILURE="Player process terminated during playback"
    fi
    PROFILE="$(printf '%s\n' "$LOGS" | sed -n 's/.*source=//p' | tail -1)"
    PROFILE="${PROFILE:-unknown source}"
    jq -n \
      --argjson index "$((START + 1))" \
      --arg profile "$PROFILE" \
      --arg error "$FAILURE" \
      '{
        generatedAt: (now | todateiso8601),
        requestedStreams: 1,
        availableStreams: 0,
        testedStreams: 1,
        passedStreams: 0,
        entries: [{
          streamIndex: $index,
          provider: "Debridio - Scraper TB",
          sourceProfile: $profile,
          engine: null,
          metrics: null,
          error: $error
        }]
      }' > "$PARTS_DIR/$PART_NAME"
  fi
  START=$END
done

jq -s '
  {
    generatedAt: (now | todateiso8601),
    requestedStreams: 20,
    availableStreams: (map(.availableStreams) | max),
    testedStreams: (map(.testedStreams) | add),
    passedStreams: (map(.passedStreams) | add),
    passed: ((map(.testedStreams) | add) == 20 and (map(.passedStreams) | add) == 20),
    entries: (map(.entries) | add | sort_by(.streamIndex))
  }
' "$PARTS_DIR"/obsession-stream-report-*.json > "$FINAL_REPORT"

TESTED="$(jq -r '.testedStreams' "$FINAL_REPORT")"
PASSED="$(jq -r '.passedStreams' "$FINAL_REPORT")"
echo "Obsession TorBox benchmark: $PASSED/$TESTED strict passes"
echo "Report: $FINAL_REPORT"
test "$TESTED" -eq 20
test "$PASSED" -eq 20
