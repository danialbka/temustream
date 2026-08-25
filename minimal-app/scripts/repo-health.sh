#!/bin/sh

# Read-only repository hygiene report. This script never removes or rewrites
# project files; --check only changes the exit status.
set -u

usage() {
  cat <<'EOF'
Usage: ./scripts/repo-health.sh [--report|--check] [--root PATH]
                                [--content-root PATH] [--max-source-lines N]

Modes:
  --report  Print every finding and exit 0 when the scan completes (default).
  --check   Exit 1 for warnings-only, 2 when any error is found, or 0 if clean.

Other exits:
  64        Invalid arguments.
  70        The repository could not be inspected.
EOF
}

HEALTH_MODE=report
HEALTH_ROOT_INPUT=
HEALTH_CONTENT_ROOT_INPUT=
HEALTH_MAX_SOURCE_LINES="${REPO_HEALTH_MAX_SOURCE_LINES:-1200}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --report)
      HEALTH_MODE=report
      shift
      ;;
    --check)
      HEALTH_MODE=check
      shift
      ;;
    --root)
      if [ "$#" -lt 2 ]; then
        usage >&2
        exit 64
      fi
      HEALTH_ROOT_INPUT=$2
      shift 2
      ;;
    --content-root)
      if [ "$#" -lt 2 ]; then
        usage >&2
        exit 64
      fi
      HEALTH_CONTENT_ROOT_INPUT=$2
      shift 2
      ;;
    --max-source-lines)
      if [ "$#" -lt 2 ]; then
        usage >&2
        exit 64
      fi
      HEALTH_MAX_SOURCE_LINES=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'repo-health: unknown option: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

case "$HEALTH_MAX_SOURCE_LINES" in
  ''|*[!0-9]*|0)
    printf 'repo-health: --max-source-lines must be a positive integer\n' >&2
    exit 64
    ;;
esac

if [ -z "$HEALTH_ROOT_INPUT" ]; then
  HEALTH_SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || {
    printf 'repo-health: could not resolve the script directory\n' >&2
    exit 70
  }
  HEALTH_ROOT_INPUT="$HEALTH_SCRIPT_DIR/.."
fi

HEALTH_ROOT=$(CDPATH= cd -- "$HEALTH_ROOT_INPUT" 2>/dev/null && pwd) || {
  printf 'repo-health: root does not exist or is not readable: %s\n' "$HEALTH_ROOT_INPUT" >&2
  exit 70
}

if [ -z "$HEALTH_CONTENT_ROOT_INPUT" ]; then
  HEALTH_CONTENT_ROOT=$HEALTH_ROOT
else
  HEALTH_CONTENT_ROOT=$(CDPATH= cd -- "$HEALTH_CONTENT_ROOT_INPUT" 2>/dev/null && pwd) || {
    printf 'repo-health: content root does not exist or is not readable: %s\n' \
      "$HEALTH_CONTENT_ROOT_INPUT" >&2
    exit 70
  }
fi

if ! git -C "$HEALTH_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'repo-health: root is not inside a Git worktree: %s\n' "$HEALTH_ROOT" >&2
  exit 70
fi

HEALTH_TMP_BASE=$(mktemp "${TMPDIR:-/tmp}/repo-health.XXXXXX") || {
  printf 'repo-health: could not create temporary scan files\n' >&2
  exit 70
}
HEALTH_TRACKED=$HEALTH_TMP_BASE
HEALTH_UNTRACKED=$HEALTH_TMP_BASE.untracked
HEALTH_ALL=$HEALTH_TMP_BASE.all
HEALTH_FILESYSTEM=$HEALTH_TMP_BASE.filesystem
HEALTH_DUPLICATES=$HEALTH_TMP_BASE.duplicates
HEALTH_SECRET_MATCHES=$HEALTH_TMP_BASE.secrets
HEALTH_SKIPPED_CONTENT=$HEALTH_TMP_BASE.skipped

cleanup_health_files() {
  rm -f -- "$HEALTH_TRACKED" "$HEALTH_UNTRACKED" "$HEALTH_ALL" \
    "$HEALTH_FILESYSTEM" "$HEALTH_DUPLICATES" "$HEALTH_SECRET_MATCHES"
  rm -f -- "$HEALTH_SKIPPED_CONTENT"
}
trap cleanup_health_files EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! git -C "$HEALTH_ROOT" ls-files --cached -- . >"$HEALTH_TRACKED"; then
  printf 'repo-health: could not list tracked files\n' >&2
  exit 70
fi
if ! git -C "$HEALTH_ROOT" ls-files --others --exclude-standard -- . >"$HEALTH_UNTRACKED"; then
  printf 'repo-health: could not list untracked files\n' >&2
  exit 70
fi
LC_ALL=C sort -u "$HEALTH_TRACKED" "$HEALTH_UNTRACKED" >"$HEALTH_ALL"

HEALTH_WARNINGS=0
HEALTH_ERRORS=0

warn() {
  HEALTH_WARNINGS=$((HEALTH_WARNINGS + 1))
  printf '[WARN] %-27s %s\n' "$1" "$2"
}

error() {
  HEALTH_ERRORS=$((HEALTH_ERRORS + 1))
  printf '[ERROR] %-26s %s\n' "$1" "$2"
}

path_state() {
  HEALTH_STATE_PATH=$1
  if grep -Fqx "$HEALTH_STATE_PATH" "$HEALTH_TRACKED" 2>/dev/null || \
    grep -Fq "$HEALTH_STATE_PATH/" "$HEALTH_TRACKED" 2>/dev/null; then
    printf 'tracked'
  elif grep -Fqx "$HEALTH_STATE_PATH" "$HEALTH_UNTRACKED" 2>/dev/null || \
    grep -Fq "$HEALTH_STATE_PATH/" "$HEALTH_UNTRACKED" 2>/dev/null; then
    printf 'untracked'
  else
    printf 'ignored/local'
  fi
}

require_path() {
  if [ ! -e "$HEALTH_ROOT/$1" ]; then
    error MISSING_CANONICAL "$1"
  fi
}

is_source_path() {
  case "$1" in
    Vendor/*|*/node_modules/*|*/target/*|Backend/watch-together/convex/_generated/*)
      return 1
      ;;
    Sources/*|Tests/*|iOS/App/*|tvOS/App/*|Backend/watch-together/*|rust/*|scripts/*)
      case "$1" in
        *.swift|*.m|*.mm|*.h|*.c|*.cc|*.cpp|*.rs|*.ts|*.tsx|*.js|*.jsx|*.mjs|*.sh|*.py)
          return 0
          ;;
      esac
      ;;
  esac
  return 1
}

is_example_secret_path() {
  case "$1" in
    *.example|*.example.*|*.sample|*.sample.*|*.template|*.template.*|*.dist|*.dist.*)
      return 0
      ;;
  esac
  return 1
}

is_sensitive_path() {
  if is_example_secret_path "$1"; then
    return 1
  fi
  case "$1" in
    .env|.env.*|*/.env|*/.env.*|*.p12|*.pfx|*.pem|*.key|*.mobileprovision|*.provisionprofile|\
    *credentials*.json|*credential*.json|*sideloadly*snapshot*.json|*WatchTogether.local.xcconfig)
      return 0
      ;;
  esac
  return 1
}

is_generated_artifact_path() {
  case "$1" in
    *.ipa|*.zip|*.xcarchive|*.app|*.dSYM|*.log|*.mov|*.mp4|*.trace|*.profraw|*.profdata|*.xcresult|*.xcresult/*|*.png|*.jpg|*.jpeg)
      return 0
      ;;
  esac
  return 1
}

is_approved_artifact_location() {
  case "$1" in
    Vendor/*|Fixtures/*|iOS/Resources/Assets.xcassets/*|iOS/Resources/Brand/*)
      return 0
      ;;
    docs/*.png|docs/*.jpg|docs/*.jpeg|docs/*.mov|docs/*.mp4)
      return 0
      ;;
  esac
  return 1
}

is_dataless_file() {
  HEALTH_FILE_FLAGS=$(ls -lO "$1" 2>/dev/null || true)
  case "$HEALTH_FILE_FLAGS" in
    *dataless*) return 0 ;;
  esac
  return 1
}

printf 'Repository health: %s\n' "$HEALTH_ROOT"
printf 'Mode: %s; source hotspot threshold: %s lines\n' "$HEALTH_MODE" "$HEALTH_MAX_SOURCE_LINES"
if [ "$HEALTH_CONTENT_ROOT" != "$HEALTH_ROOT" ]; then
  printf 'Content mirror: %s\n' "$HEALTH_CONTENT_ROOT"
fi

printf '\nCanonical paths\n'
require_path README.md
require_path Package.swift
require_path project.yml
require_path UI_STATE_MATRIX.md
require_path PLAYBACK_BENCHMARKS.md
require_path Sources/StremioSkeletonCore
require_path Tests/StremioSkeletonCoreTests
require_path iOS/App
require_path iOS/Resources
require_path tvOS/App
require_path tvOS/Resources
require_path scripts/test.sh
require_path scripts/build-simulator.sh
require_path scripts/build-tvos.sh
require_path scripts/build-device.sh
require_path scripts/verify.sh
require_path scripts/repo-health.sh
require_path docs/CODEBASE_HYGIENE.md

printf '\nFinder-style duplicates and local debris\n'
if ! find "$HEALTH_ROOT" \
  \( -type d \( -name .git -o -name build -o -name .build -o -name .swiftpm \
    -o -name node_modules -o -name target -o -name Vendor \) -prune \) \
  -o -print >"$HEALTH_FILESYSTEM"; then
  printf 'repo-health: filesystem scan failed\n' >&2
  exit 70
fi

: >"$HEALTH_DUPLICATES"
while IFS= read -r HEALTH_ABSOLUTE_PATH; do
  [ "$HEALTH_ABSOLUTE_PATH" = "$HEALTH_ROOT" ] && continue
  HEALTH_RELATIVE_PATH=${HEALTH_ABSOLUTE_PATH#"$HEALTH_ROOT"/}

  case "$HEALTH_RELATIVE_PATH" in
    .DS_Store|*/.DS_Store)
      warn GENERATED_DEBRIS "$HEALTH_RELATIVE_PATH ($(path_state "$HEALTH_RELATIVE_PATH"))"
      ;;
    */xcuserdata)
      warn GENERATED_DEBRIS "$HEALTH_RELATIVE_PATH ($(path_state "$HEALTH_RELATIVE_PATH"))"
      ;;
    */xcuserdata/*)
      ;;
  esac

  if is_generated_artifact_path "$HEALTH_RELATIVE_PATH" && \
    ! is_approved_artifact_location "$HEALTH_RELATIVE_PATH"; then
    HEALTH_ARTIFACT_STATE=$(path_state "$HEALTH_RELATIVE_PATH")
    if [ "$HEALTH_ARTIFACT_STATE" = ignored/local ]; then
      warn UNEXPECTED_ARTIFACT "$HEALTH_RELATIVE_PATH ($HEALTH_ARTIFACT_STATE)"
    fi
  fi

  HEALTH_DUPLICATE_ROOT=$(printf '%s\n' "$HEALTH_RELATIVE_PATH" | awk -F/ '
    {
      prefix = ""
      for (i = 1; i <= NF; i++) {
        prefix = (prefix == "" ? $i : prefix "/" $i)
        if ($i ~ / ([2-9]|[1-9][0-9]+)(\.[^.]*)?$/) {
          print prefix
          exit
        }
      }
    }
  ')
  if [ -n "$HEALTH_DUPLICATE_ROOT" ]; then
    printf '%s\n' "$HEALTH_DUPLICATE_ROOT" >>"$HEALTH_DUPLICATES"
  fi
done <"$HEALTH_FILESYSTEM"

LC_ALL=C sort -u -o "$HEALTH_DUPLICATES" "$HEALTH_DUPLICATES"
while IFS= read -r HEALTH_DUPLICATE_ROOT; do
  [ -z "$HEALTH_DUPLICATE_ROOT" ] && continue
  warn FINDER_DUPLICATE "$HEALTH_DUPLICATE_ROOT ($(path_state "$HEALTH_DUPLICATE_ROOT"))"
done <"$HEALTH_DUPLICATES"

printf '\nArtifacts and sensitive paths outside ignored output\n'
scan_inventory() {
  HEALTH_INVENTORY=$1
  HEALTH_INVENTORY_STATE=$2
  while IFS= read -r HEALTH_PATH; do
    [ -z "$HEALTH_PATH" ] && continue

    if is_generated_artifact_path "$HEALTH_PATH" && \
      ! is_approved_artifact_location "$HEALTH_PATH"; then
      warn UNEXPECTED_ARTIFACT "$HEALTH_PATH ($HEALTH_INVENTORY_STATE)"
    fi

    if is_sensitive_path "$HEALTH_PATH"; then
      error SENSITIVE_PATH "$HEALTH_PATH ($HEALTH_INVENTORY_STATE; verify it contains no credentials)"
    fi
  done <"$HEALTH_INVENTORY"
}

scan_inventory "$HEALTH_TRACKED" tracked
scan_inventory "$HEALTH_UNTRACKED" untracked

printf '\nSource integrity and hotspots\n'
: >"$HEALTH_SKIPPED_CONTENT"
while IFS= read -r HEALTH_PATH; do
  [ -z "$HEALTH_PATH" ] && continue
  if ! is_source_path "$HEALTH_PATH"; then
    continue
  fi
  HEALTH_CONTENT_PATH="$HEALTH_CONTENT_ROOT/$HEALTH_PATH"
  if [ ! -e "$HEALTH_CONTENT_PATH" ] && [ "$HEALTH_CONTENT_ROOT" != "$HEALTH_ROOT" ]; then
    HEALTH_CONTENT_PATH="$HEALTH_ROOT/$HEALTH_PATH"
  fi
  if [ ! -e "$HEALTH_CONTENT_PATH" ]; then
    continue
  fi
  if [ ! -s "$HEALTH_CONTENT_PATH" ]; then
    error ZERO_BYTE_SOURCE "$HEALTH_PATH"
    continue
  fi
  if is_dataless_file "$HEALTH_CONTENT_PATH"; then
    printf '%s\n' "$HEALTH_PATH" >>"$HEALTH_SKIPPED_CONTENT"
    continue
  fi
  HEALTH_LINE_COUNT=$(wc -l <"$HEALTH_CONTENT_PATH" 2>/dev/null | tr -d '[:space:]')
  case "$HEALTH_LINE_COUNT" in
    ''|*[!0-9]*)
      error UNREADABLE_SOURCE "$HEALTH_PATH"
      ;;
    *)
      if [ "$HEALTH_LINE_COUNT" -gt "$HEALTH_MAX_SOURCE_LINES" ]; then
        warn SOURCE_HOTSPOT "$HEALTH_PATH ($HEALTH_LINE_COUNT lines)"
      fi
      ;;
  esac
done <"$HEALTH_ALL"

printf '\nHigh-confidence credential markers\n'
HEALTH_SECRET_PATTERN='-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk_live_[A-Za-z0-9]{16,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}'
: >"$HEALTH_SECRET_MATCHES"

while IFS= read -r HEALTH_PATH; do
  [ -z "$HEALTH_PATH" ] && continue
  [ "$HEALTH_PATH" = scripts/repo-health.sh ] && continue
  case "$HEALTH_PATH" in
    Vendor/*|*/node_modules/*|*/target/*|Backend/watch-together/convex/_generated/*)
      continue
      ;;
  esac
  HEALTH_CONTENT_PATH="$HEALTH_CONTENT_ROOT/$HEALTH_PATH"
  if [ ! -e "$HEALTH_CONTENT_PATH" ] && [ "$HEALTH_CONTENT_ROOT" != "$HEALTH_ROOT" ]; then
    HEALTH_CONTENT_PATH="$HEALTH_ROOT/$HEALTH_PATH"
  fi
  [ -f "$HEALTH_CONTENT_PATH" ] || continue
  if is_dataless_file "$HEALTH_CONTENT_PATH"; then
    printf '%s\n' "$HEALTH_PATH" >>"$HEALTH_SKIPPED_CONTENT"
    continue
  fi
  HEALTH_BYTE_COUNT=$(stat -f '%z' "$HEALTH_CONTENT_PATH" 2>/dev/null || true)
  case "$HEALTH_BYTE_COUNT" in
    ''|*[!0-9]*) continue ;;
  esac
  [ "$HEALTH_BYTE_COUNT" -le 1048576 ] || continue
  if LC_ALL=C grep -IEl -e "$HEALTH_SECRET_PATTERN" "$HEALTH_CONTENT_PATH" >/dev/null 2>&1 \
      && ! grep -Fqx "$HEALTH_PATH" "$HEALTH_SECRET_MATCHES" 2>/dev/null; then
    error CREDENTIAL_MARKER \
      "$HEALTH_PATH ($(path_state "$HEALTH_PATH"); matched content is intentionally hidden)"
  fi
done <"$HEALTH_ALL"

LC_ALL=C sort -u -o "$HEALTH_SKIPPED_CONTENT" "$HEALTH_SKIPPED_CONTENT"
HEALTH_SKIPPED_COUNT=$(wc -l <"$HEALTH_SKIPPED_CONTENT" | tr -d '[:space:]')
if [ "$HEALTH_SKIPPED_COUNT" -gt 0 ]; then
  warn CLOUD_CONTENT_SKIPPED \
    "$HEALTH_SKIPPED_COUNT cloud-placeholder file(s); use --content-root with a verified local workspace for content checks"
fi

printf '\nSummary: %s warning(s), %s error(s). No files were changed.\n' \
  "$HEALTH_WARNINGS" "$HEALTH_ERRORS"

if [ "$HEALTH_MODE" = report ]; then
  printf 'Exit 0: report mode completed. Use --check for enforceable exit codes.\n'
  exit 0
fi

if [ "$HEALTH_ERRORS" -gt 0 ]; then
  printf 'Exit 2: check mode found at least one error.\n'
  exit 2
fi
if [ "$HEALTH_WARNINGS" -gt 0 ]; then
  printf 'Exit 1: check mode found warnings only.\n'
  exit 1
fi

printf 'Exit 0: check mode found no issues.\n'
exit 0
