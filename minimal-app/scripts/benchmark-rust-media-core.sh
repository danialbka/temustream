#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app_root="$(cd "$script_dir/.." && pwd)"
crate_root="$app_root/rust/StremioPlaybackCore"
invocation_dir="$PWD"

fixture_path=""
fixture_mode="generated"
fixture_label=""
fixture_provenance=""
generated_seconds=300
warmups=5
repetitions=25
seek_operations=500
external_warmups=1
external_repetitions=5
include_ffprobe=1
json_output="$app_root/build/benchmarks/rust-media-core.json"

usage() {
  printf '%s\n' \
    'Usage: ./scripts/benchmark-rust-media-core.sh [options]' \
    '' \
    'Options:' \
    '  --fixture PATH             Benchmark an explicit MKV/WebM fixture.' \
    '  --tracked                  Use the tracked one-second AV1/FLAC fixture.' \
    '  --generated-seconds N      Stream-copy the tracked fixture to N seconds' \
    '                             when ffmpeg is available (default: 300).' \
    '  --warmups N                Rust warmups (default: 5).' \
    '  --repetitions N            Rust timed repetitions (default: 25).' \
    '  --seek-operations N        Fixed seek targets per run (default: 500).' \
    '  --external-warmups N       ffprobe warmups (default: 1).' \
    '  --external-repetitions N   ffprobe timed runs (default: 5).' \
    '  --no-ffprobe               Skip the external-process reference.' \
    '  --output PATH              JSON output path.' \
    '  -h, --help                 Show this help.'
}

# Same-fixture benchmark runner for the dependency-free Rust Matroska core.
#
# Usage:
#   ./scripts/benchmark-rust-media-core.sh [options]
#
# Options:
#   --fixture PATH             Benchmark an explicit MKV/WebM fixture.
#   --tracked                  Use the tracked one-second AV1/FLAC fixture.
#   --generated-seconds N      Stream-copy the tracked fixture to N seconds
#                              when ffmpeg is available (default: 300).
#   --warmups N                Rust warmups (default: 5).
#   --repetitions N            Rust timed repetitions (default: 25).
#   --seek-operations N        Fixed seek targets per run (default: 500).
#   --external-warmups N       ffprobe warmups (default: 1).
#   --external-repetitions N   ffprobe timed runs (default: 5).
#   --no-ffprobe               Skip the external-process reference.
#   --output PATH              JSON output path.
#   -h, --help                 Show this help.
#
# ffprobe numbers are deliberately labeled as external-process references:
# they include process startup and file I/O and are not direct win/loss data.

require_uint() {
  local option="$1"
  local value="$2"
  local minimum="$3"
  local maximum="$4"
  if [[ ! "$value" =~ ^(0|[1-9][0-9]*)$ ]] || (( value < minimum || value > maximum )); then
    printf '%s must be an integer between %s and %s\n' "$option" "$minimum" "$maximum" >&2
    exit 2
  fi
}

while (($#)); do
  case "$1" in
    --fixture)
      [[ $# -ge 2 ]] || { printf '%s requires a path\n' "$1" >&2; exit 2; }
      fixture_path="$2"
      fixture_mode="explicit"
      shift 2
      ;;
    --tracked)
      fixture_mode="tracked"
      shift
      ;;
    --generated-seconds)
      [[ $# -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      generated_seconds="$2"
      shift 2
      ;;
    --warmups)
      [[ $# -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      warmups="$2"
      shift 2
      ;;
    --repetitions)
      [[ $# -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      repetitions="$2"
      shift 2
      ;;
    --seek-operations)
      [[ $# -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      seek_operations="$2"
      shift 2
      ;;
    --external-warmups)
      [[ $# -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      external_warmups="$2"
      shift 2
      ;;
    --external-repetitions)
      [[ $# -ge 2 ]] || { printf '%s requires a value\n' "$1" >&2; exit 2; }
      external_repetitions="$2"
      shift 2
      ;;
    --no-ffprobe)
      include_ffprobe=0
      shift
      ;;
    --output)
      [[ $# -ge 2 ]] || { printf '%s requires a path\n' "$1" >&2; exit 2; }
      json_output="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require_uint --generated-seconds "$generated_seconds" 1 3600
require_uint --warmups "$warmups" 0 1000
require_uint --repetitions "$repetitions" 1 1000
require_uint --seek-operations "$seek_operations" 1 1000000
require_uint --external-warmups "$external_warmups" 0 100
require_uint --external-repetitions "$external_repetitions" 1 100

if [[ "$json_output" != /* ]]; then
  json_output="$invocation_dir/$json_output"
fi
mkdir -p "$(dirname "$json_output")"

artifact_dir="$app_root/build/benchmarks/fixtures"
mkdir -p "$artifact_dir"
tracked_source="$app_root/Fixtures/sample-av1-flac.mkv.b64"
decoded_fixture="$artifact_dir/tracked-av1-flac.mkv"

decode_tracked_fixture() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    base64 -D -i "$tracked_source" -o "$decoded_fixture"
  else
    base64 --decode "$tracked_source" > "$decoded_fixture"
  fi
}

if [[ "$fixture_mode" == "explicit" ]]; then
  if [[ "$fixture_path" != /* ]]; then
    fixture_path="$invocation_dir/$fixture_path"
  fi
  [[ -f "$fixture_path" ]] || { printf 'Fixture not found: %s\n' "$fixture_path" >&2; exit 2; }
  fixture_label="explicit"
  fixture_provenance="caller-provided fixture"
else
  [[ -f "$tracked_source" ]] || { printf 'Tracked fixture not found: %s\n' "$tracked_source" >&2; exit 2; }
  decode_tracked_fixture
  if [[ "$fixture_mode" == "generated" ]] && command -v ffmpeg >/dev/null 2>&1; then
    fixture_path="$artifact_dir/generated-${generated_seconds}s-av1-flac.mkv"
    loop_count=$((generated_seconds - 1))
    ffmpeg \
      -hide_banner \
      -loglevel error \
      -nostdin \
      -y \
      -stream_loop "$loop_count" \
      -i "$decoded_fixture" \
      -map 0:v:0 \
      -map 0:a:0 \
      -c copy \
      -t "$generated_seconds" \
      -metadata title="Bunny Rust benchmark fixture" \
      -f matroska \
      "$fixture_path"
    fixture_label="generated-${generated_seconds}s-av1-flac"
    fixture_provenance="ffmpeg stream-copy loop of tracked Fixtures/sample-av1-flac.mkv.b64; SHA-256 identifies this exact generated run"
  else
    if [[ "$fixture_mode" == "generated" ]]; then
      printf 'ffmpeg is unavailable; falling back to the tracked one-second fixture.\n' >&2
    fi
    fixture_path="$decoded_fixture"
    fixture_label="tracked-av1-flac"
    fixture_provenance="base64-decoded from tracked Fixtures/sample-av1-flac.mkv.b64"
  fi
fi

fixture_sha256=""
if command -v shasum >/dev/null 2>&1; then
  fixture_sha256="$(shasum -a 256 "$fixture_path" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  fixture_sha256="$(sha256sum "$fixture_path" | awk '{print $1}')"
fi

benchmark_arguments=(
  --fixture "$fixture_path"
  --fixture-label "$fixture_label"
  --fixture-provenance "$fixture_provenance"
  --json-output "$json_output"
  --warmups "$warmups"
  --repetitions "$repetitions"
  --seek-operations "$seek_operations"
  --external-warmups "$external_warmups"
  --external-repetitions "$external_repetitions"
)

if [[ -n "$fixture_sha256" ]]; then
  benchmark_arguments+=(--fixture-sha256 "$fixture_sha256")
fi

if (( include_ffprobe )) && command -v ffprobe >/dev/null 2>&1; then
  benchmark_arguments+=(--ffprobe "$(command -v ffprobe)")
fi

cd "$crate_root"
cargo run --quiet --release --example media_core_benchmark -- "${benchmark_arguments[@]}"
