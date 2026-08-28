#!/bin/sh

# Read-only checks for files that should not be present in a public source
# release. Matching credential values are never printed.
set -eu

scan_history=0
history_timeout_seconds=${PUBLIC_RELEASE_HISTORY_TIMEOUT_SECONDS:-30}

usage() {
  cat <<'EOF'
Usage: ./scripts/public-release-check.sh [--history]

  --history  Also inspect history reachable from HEAD for sensitive paths and
             high-confidence credential markers. If local Git objects are
             cloud-only, the scanner can verify and inspect the matching origin.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --history)
      scan_history=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)

if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  printf 'public-release-check: not inside a Git worktree\n' >&2
  exit 70
fi

scan_tmp=$(mktemp -d "${TMPDIR:-/tmp}/temustremio-public-check.XXXXXX")
cleanup() {
  rm -rf -- "$scan_tmp"
}
trap cleanup EXIT HUP INT TERM

inventory="$scan_tmp/inventory"
history_paths="$scan_tmp/history-paths"
history_matches="$scan_tmp/history-matches"
history_personal_matches="$scan_tmp/history-personal-matches"
history_paths_raw="$scan_tmp/history-paths-raw"
history_matches_raw="$scan_tmp/history-matches-raw"
history_personal_matches_raw="$scan_tmp/history-personal-matches-raw"

git -C "$repo_root" ls-files --cached --others --exclude-standard -- . \
  | while IFS= read -r path; do
      # A tracked file can be deleted in the working tree before the release
      # commit exists. Scan the tree that would actually be reviewed instead
      # of reporting already-removed files as current artifacts.
      [ -e "$repo_root/$path" ] && printf '%s\n' "$path"
    done \
  | LC_ALL=C sort -u >"$inventory"

errors=0
warnings=0

error() {
  errors=$((errors + 1))
  printf '[ERROR] %s: %s\n' "$1" "$2"
}

warn() {
  warnings=$((warnings + 1))
  printf '[WARN]  %s: %s\n' "$1" "$2"
}

run_with_timeout() {
  timeout_seconds=$1
  shift

  "$@" &
  command_pid=$!
  (
    sleep "$timeout_seconds"
    kill -TERM "$command_pid" 2>/dev/null || true
    sleep 1
    kill -KILL "$command_pid" 2>/dev/null || true
  ) &
  watcher_pid=$!

  if wait "$command_pid"; then
    command_status=0
  else
    command_status=$?
  fi
  kill -TERM "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true
  return "$command_status"
}

is_example_path() {
  case "$1" in
    *.example|*.example.*|*.sample|*.sample.*|*.template|*.template.*|*.dist|*.dist.*)
      return 0
      ;;
  esac
  return 1
}

is_sensitive_path() {
  is_example_path "$1" && return 1
  case "$1" in
    .env|.env.*|*/.env|*/.env.*|.envrc|*/.envrc|.netrc|*/.netrc|.npmrc|*/.npmrc|.pypirc|*/.pypirc|\
    *.p8|*.p12|*.pfx|*.pem|*.key|*.jks|*.keystore|*.kdbx|*.mobileprovision|*.provisionprofile|\
    *credentials*.json|*credential*.json|*sideloadly*snapshot*.json|*Signing.local.xcconfig|*ExportOptions.local.plist)
      return 0
      ;;
  esac
  return 1
}

is_forbidden_artifact() {
  case "$1" in
    *.ipa|*.xcarchive|*.app|*.app/*|*.dylib|*.dSYM|*.dSYM/*|*.xcresult|*.xcresult/*|\
    *.resultbundle|*.resultbundle/*|*.profraw|*.profdata|*.trace|*.log)
      return 0
      ;;
  esac
  return 1
}

printf 'Public release check: %s\n' "$repo_root"

printf '\nRequired public files\n'
for required_path in \
  README.md LICENSE SECURITY.md PRIVACY.md THIRD_PARTY_NOTICES.md \
  CONTRIBUTING.md CODE_OF_CONDUCT.md SUPPORT.md \
  docs/RELEASING.md docs/ASSET_PROVENANCE.md \
  docs/assets/bunny-banner.png; do
  if [ ! -e "$repo_root/$required_path" ]; then
    error MISSING "$required_path"
  fi
done

printf '\nCurrent iOS dependency and notice inputs\n'
project_spec="$repo_root/minimal-app/project.yml"
rust_toolchain="$repo_root/minimal-app/rust-toolchain.toml"
rust_notice="$repo_root/minimal-app/ThirdParty/Rust/1.95.0/COPYRIGHT-library.html"
rust_notice_sha256='90567e2718bf7fd65a71a3a43c5596488e80e5f51ed02bfea6fec54458b5f3d1'

if [ ! -s "$project_spec" ]; then
  error MISSING "minimal-app/project.yml"
else
  if grep -Eq '^[[:space:]]*packages:' "$project_spec"; then
    error IOS_PACKAGE_GRAPH "project.yml declares Swift packages; update the release inventory"
  fi
  if grep -Eqi 'KSPlayer|FFmpegKit|MobileVLCKit|ConvexMobile|LiveKit|SwiftProtobuf|WebRTC' "$project_spec"; then
    error REMOVED_IOS_DEPENDENCY "project.yml references a removed iOS dependency"
  fi
  for bundled_resource in \
    '../LICENSE' \
    '../THIRD_PARTY_NOTICES.md' \
    'ThirdParty/Rust/1.95.0/COPYRIGHT-library.html'; do
    if ! grep -Fq "$bundled_resource" "$project_spec"; then
      error MISSING_BUNDLED_NOTICE "$bundled_resource"
    fi
  done
fi

if [ ! -s "$rust_toolchain" ] \
    || ! grep -Eq 'channel[[:space:]]*=[[:space:]]*"1\.95\.0"' "$rust_toolchain"; then
  error RUST_TOOLCHAIN "minimal-app/rust-toolchain.toml is missing the 1.95.0 pin"
fi
if [ ! -s "$rust_notice" ]; then
  error MISSING_RUST_NOTICE "minimal-app/ThirdParty/Rust/1.95.0/COPYRIGHT-library.html"
elif [ "$(shasum -a 256 "$rust_notice" | awk '{print $1}')" != "$rust_notice_sha256" ]; then
  error RUST_NOTICE_MISMATCH "the bundled Rust 1.95.0 library notice has changed"
fi

printf '\nSensitive paths and release artifacts\n'
while IFS= read -r path; do
  [ -n "$path" ] || continue
  if is_sensitive_path "$path"; then
    error SENSITIVE_PATH "$path"
  fi
  if is_forbidden_artifact "$path"; then
    error GENERATED_ARTIFACT "$path"
  fi
  case "$path" in
    *' '[0-9]*.xcodeproj/project.pbxproj|*'/Info '[0-9]*.plist)
      warn FINDER_DUPLICATE "$path"
      ;;
  esac
done <"$inventory"

printf '\nHigh-confidence credential markers\n'
secret_pattern='-----BEGIN ([A-Z0-9 ]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|npm_[A-Za-z0-9]{30,}|pypi-AgEIcH[A-Za-z0-9_-]{20,}|sk_live_[A-Za-z0-9]{16,}|sk-proj-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{30,}'
personal_device_pattern="[[:alpha:]][[:alnum:]_. -]{1,40}['’]s (iPhone|iPad|Apple Watch)"
history_personal_pattern="($personal_device_pattern|Measured [0-9]{4}-[0-9]{2}-[0-9]{2} on [[:alnum:]_.-]{3,40} \((iPhone|iPad|Apple Watch)|fast updater checks [[:alnum:]_.-]{3,40} before)"

while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    scripts/public-release-check.sh|minimal-app/scripts/repo-health.sh|\
    minimal-app/Vendor/*|*/node_modules/*|*/build/*|*/target/*)
      continue
      ;;
  esac
  file_path="$repo_root/$path"
  [ -f "$file_path" ] || continue
  byte_count=$(wc -c <"$file_path" 2>/dev/null | tr -d '[:space:]' || printf '0')
  case "$byte_count" in
    ''|*[!0-9]*) continue ;;
  esac
  [ "$byte_count" -le 2097152 ] || continue
  if LC_ALL=C grep -IEl -e "$secret_pattern" "$file_path" >/dev/null 2>&1; then
    error CREDENTIAL_MARKER "$path (matched value hidden)"
  fi
done <"$inventory"

printf '\nPersonal paths and device labels\n'
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "$path" in
    scripts/public-release-check.sh|*/build/*|*/node_modules/*|minimal-app/Vendor/*)
      continue
      ;;
  esac
  file_path="$repo_root/$path"
  [ -f "$file_path" ] || continue
  if LC_ALL=C grep -IEl '/Users/[^/[:space:]]+/' "$file_path" >/dev/null 2>&1; then
    error ABSOLUTE_HOME_PATH "$path (matched value hidden)"
  fi
  if LC_ALL=C grep -IEl -e "$personal_device_pattern" "$file_path" >/dev/null 2>&1; then
    error PERSONAL_DEVICE_LABEL "$path (matched value hidden)"
  fi
done <"$inventory"

if [ "$scan_history" -eq 1 ]; then
  printf '\nGit history\n'
  history_repo=$repo_root
  history_revision=HEAD
  if ! run_with_timeout "$history_timeout_seconds" \
      git -C "$history_repo" log "$history_revision" --name-only --pretty=format: \
      >"$history_paths_raw" 2>"$scan_tmp/local-history.err"; then
    origin_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
    local_head=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
    origin_mirror="$scan_tmp/origin.git"
    if [ -n "$origin_url" ] \
        && run_with_timeout 120 git clone --mirror --quiet "$origin_url" "$origin_mirror" \
        && [ "$(git -C "$origin_mirror" rev-parse HEAD 2>/dev/null || true)" = "$local_head" ]; then
      printf 'Local Git objects were unavailable; scanning the verified matching origin mirror.\n'
      history_repo=$origin_mirror
      history_revision=--all
      if ! run_with_timeout 120 \
          git -C "$history_repo" log "$history_revision" --name-only --pretty=format: \
          >"$history_paths_raw"; then
        error HISTORY_SCAN_INCOMPLETE "Git could not read the verified origin history"
      fi
    else
      error HISTORY_SCAN_INCOMPLETE "Git could not read local history or verify a matching origin"
    fi
  fi

  if [ -s "$history_paths_raw" ]; then
    LC_ALL=C sort -u "$history_paths_raw" >"$history_paths"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      if is_sensitive_path "$path"; then
        error HISTORY_SENSITIVE_PATH "$path"
      fi
      if is_forbidden_artifact "$path"; then
        error HISTORY_ARTIFACT "$path"
      fi
    done <"$history_paths"
  fi

  if run_with_timeout 120 \
      git -C "$history_repo" log "$history_revision" -G "$secret_pattern" --name-only --pretty=format: -- \
      . \
      ':(exclude)scripts/public-release-check.sh' \
      ':(exclude)minimal-app/scripts/repo-health.sh' \
      >"$history_matches_raw"; then
    LC_ALL=C sort -u "$history_matches_raw" >"$history_matches"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      error HISTORY_CREDENTIAL_MARKER "$path (matched value hidden)"
    done <"$history_matches"
  else
    error HISTORY_SCAN_INCOMPLETE "Git could not inspect every historical diff"
  fi

  if run_with_timeout 120 \
      git -C "$history_repo" log "$history_revision" -G "$history_personal_pattern" --name-only --pretty=format: -- \
      . \
      ':(exclude)scripts/public-release-check.sh' \
      >"$history_personal_matches_raw"; then
    LC_ALL=C sort -u "$history_personal_matches_raw" >"$history_personal_matches"
    while IFS= read -r path; do
      [ -n "$path" ] || continue
      warn HISTORY_PERSONAL_DEVICE_LABEL "$path (matched value hidden)"
    done <"$history_personal_matches"
  else
    error HISTORY_SCAN_INCOMPLETE "Git could not inspect historical device labels"
  fi
fi

printf '\nSummary: %s error(s), %s warning(s).\n' "$errors" "$warnings"
if [ "$errors" -gt 0 ]; then
  exit 1
fi

printf 'No blocking public-release hygiene issues were found.\n'
