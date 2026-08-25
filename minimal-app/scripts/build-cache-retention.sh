#!/bin/zsh
set -euo pipefail
umask 077

marker_name=".temustream-build-cache"
last_used_name=".temustream-build-cache-last-used"
lease_name=".temustream-build-cache-active"
scan_root="${STREMIO_CACHE_SCAN_ROOT:-/private/tmp}"
default_keep="${STREMIO_CACHE_KEEP_PER_KIND:-2}"
default_grace="${STREMIO_CACHE_GRACE_SECONDS:-1800}"

note() {
  print -- "build-cache: $*"
}

fail() {
  print -u2 -- "build-cache: error: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/build-cache-retention.sh register --kind KIND --path PATH [--pid PID]
  ./scripts/build-cache-retention.sh release --path PATH [--pid PID]
  ./scripts/build-cache-retention.sh report [--legacy]
  ./scripts/build-cache-retention.sh prune [--apply] [--quiet]
      [--protect PATH] [--max-per-kind COUNT] [--grace-seconds SECONDS]

Only directories carrying a TemuStream ownership marker can be removed. The
automatic policy keeps the two most recently used caches of each kind, keeps
live leases and explicitly protected paths, and gives inactive caches a
30-minute grace period. Transient workspaces are retained only for that grace
period. Unmarked legacy stremio-* folders are report-only.

Environment:
  STREMIO_CACHE_SCAN_ROOT       Scan root, restricted to /private/tmp.
  STREMIO_CACHE_KEEP_PER_KIND  Default retained cache count (2).
  STREMIO_CACHE_GRACE_SECONDS  Default deletion grace period (1800).
USAGE
}

is_unsigned_integer() {
  [[ "$1" == <-> ]]
}

current_epoch() {
  local value="${STREMIO_CACHE_NOW_EPOCH:-$(date +%s)}"
  is_unsigned_integer "$value" || fail "invalid current epoch: $value"
  print -r -- "$value"
}

validate_kind() {
  case "$1" in
    derived-data|products|rust-target|swiftpm|transient) return 0 ;;
    *) fail "unsupported cache kind: $1" ;;
  esac
}

canonical_directory() {
  local cache_path="$1"
  [[ -d "$cache_path" ]] || fail "cache directory does not exist: $cache_path"
  [[ ! -L "$cache_path" ]] \
    || fail "cache directory cannot be a symbolic link: $cache_path"
  (cd "$cache_path" && pwd -P)
}

mkdir -p -- "$scan_root"
scan_root="$(canonical_directory "$scan_root")"
case "$scan_root" in
  /private/tmp|/private/tmp/*) ;;
  *) fail "scan root must resolve inside /private/tmp: $scan_root" ;;
esac

validate_target() {
  local cache_path="$1"
  local canonical
  [[ "$cache_path" != *$'\n'* && "$cache_path" != *$'\t'* ]] \
    || fail "cache path contains unsupported control characters"
  canonical="$(canonical_directory "$cache_path")"
  [[ "$canonical" == "$scan_root"/* ]] \
    || fail "cache path is outside $scan_root: $canonical"
  [[ "$canonical" != "$scan_root" ]] \
    || fail "refusing to operate on the scan root itself"
  print -r -- "$canonical"
}

marker_kind() {
  local marker="$1"
  [[ "$(sed -n '1p' "$marker" 2>/dev/null || true)" == \
      "temustream-build-cache-v1" ]] || return 1
  local kind="$(sed -n '2p' "$marker" 2>/dev/null || true)"
  case "$kind" in
    derived-data|products|rust-target|swiftpm|transient)
      print -r -- "$kind"
      ;;
    *) return 1 ;;
  esac
}

write_epoch() {
  local destination="$1"
  local value="$2"
  print -r -- "$value" > "$destination.tmp.$$"
  mv -f -- "$destination.tmp.$$" "$destination"
}

register_cache() {
  local kind="" cache_path="" owner_pid=""
  while (( $# > 0 )); do
    case "$1" in
      --kind) (( $# >= 2 )) || fail "--kind requires a value"; kind="$2"; shift 2 ;;
      --path) (( $# >= 2 )) || fail "--path requires a value"; cache_path="$2"; shift 2 ;;
      --pid) (( $# >= 2 )) || fail "--pid requires a value"; owner_pid="$2"; shift 2 ;;
      *) fail "unknown register option: $1" ;;
    esac
  done
  [[ -n "$kind" && -n "$cache_path" ]] \
    || fail "register requires --kind and --path"
  validate_kind "$kind"
  if [[ -n "$owner_pid" ]]; then
    is_unsigned_integer "$owner_pid" || fail "invalid owner pid: $owner_pid"
    kill -0 "$owner_pid" 2>/dev/null || fail "owner pid is not running: $owner_pid"
  fi

  mkdir -p -- "$cache_path"
  cache_path="$(validate_target "$cache_path")"
  local marker="$cache_path/$marker_name"
  local now="$(current_epoch)"
  if [[ -f "$marker" ]]; then
    [[ "$(marker_kind "$marker" 2>/dev/null || true)" == "$kind" ]] \
      || fail "cache marker ownership or kind mismatch: $cache_path"
  else
    {
      print -r -- "temustream-build-cache-v1"
      print -r -- "$kind"
      print -r -- "$now"
    } > "$marker.tmp.$$"
    mv -f -- "$marker.tmp.$$" "$marker"
  fi
  write_epoch "$cache_path/$last_used_name" "$now"

  if [[ -n "$owner_pid" ]]; then
    local existing_pid="$(sed -n '1p' "$cache_path/$lease_name" 2>/dev/null || true)"
    if is_unsigned_integer "$existing_pid" \
        && [[ "$existing_pid" != "$owner_pid" ]] \
        && kill -0 "$existing_pid" 2>/dev/null; then
      fail "cache is already leased by pid $existing_pid: $cache_path"
    fi
    {
      print -r -- "$owner_pid"
      print -r -- "$now"
    } > "$cache_path/$lease_name.tmp.$$"
    mv -f -- "$cache_path/$lease_name.tmp.$$" "$cache_path/$lease_name"
  fi
  note "registered $kind cache: $cache_path"
}

release_cache() {
  local cache_path="" owner_pid="${PPID:-}"
  while (( $# > 0 )); do
    case "$1" in
      --path) (( $# >= 2 )) || fail "--path requires a value"; cache_path="$2"; shift 2 ;;
      --pid) (( $# >= 2 )) || fail "--pid requires a value"; owner_pid="$2"; shift 2 ;;
      *) fail "unknown release option: $1" ;;
    esac
  done
  [[ -n "$cache_path" ]] || fail "release requires --path"
  is_unsigned_integer "$owner_pid" || fail "invalid owner pid: $owner_pid"
  cache_path="$(validate_target "$cache_path")"
  [[ -f "$cache_path/$marker_name" ]] || return 0
  marker_kind "$cache_path/$marker_name" >/dev/null \
    || fail "invalid cache marker: $cache_path"
  write_epoch "$cache_path/$last_used_name" "$(current_epoch)"
  local leased_pid="$(sed -n '1p' "$cache_path/$lease_name" 2>/dev/null || true)"
  if [[ "$leased_pid" == "$owner_pid" ]]; then
    rm -f -- "$cache_path/$lease_name"
  fi
}

human_kib() {
  local kib="$1"
  awk -v kib="$kib" 'BEGIN {
    if (kib >= 1048576) printf "%.1f GiB", kib / 1048576;
    else if (kib >= 1024) printf "%.1f MiB", kib / 1024;
    else printf "%d KiB", kib;
  }'
}

path_overlaps_protection() {
  local target="$1"
  local protected
  for protected in "${protected_paths[@]}"; do
    if [[ "$target" == "$protected" \
          || "$target" == "$protected"/* \
          || "$protected" == "$target"/* ]]; then
      return 0
    fi
  done
  return 1
}

report_legacy() {
  local candidate size_kib
  local found=0 total_kib=0
  while IFS= read -r -d '' candidate; do
    [[ -f "$candidate/$marker_name" ]] && continue
    case "$candidate" in
      "$scan_root/stremio-build-cache"|"$scan_root/stremio-dev-workflow") continue ;;
    esac
    size_kib="$(du -sk "$candidate" 2>/dev/null | awk '{print $1}' || true)"
    size_kib="${size_kib:-0}"
    note "LEGACY report-only $(human_kib "$size_kib") $candidate"
    found=$((found + 1))
    total_kib=$((total_kib + size_kib))
  done < <(find "$scan_root" -xdev -mindepth 1 -maxdepth 1 -type d \
    \( -name 'stremio-*-derived' \
       -o -name 'stremio-*-build' \
       -o -name 'stremio-*-build.*' \
       -o -name 'stremio-*-build[0-9]*' \
       -o -name 'stremio-*-xcode.*' \
       -o -name 'stremio-*-swiftpm' \
       -o -name 'stremio-*-swift-build' \
       -o -name 'stremio-*-swift-tests.*' \
       -o -name 'stremio-*-core-tests.*' \
       -o -name 'stremio-*-module-cache' \
       -o -name 'stremio-*-rust-target' \
       -o -name 'stremio-playback-rust-target' \
       -o -name 'stremio-fast-ota.*' \
       -o -name 'stremio-sideloadly-cli.*' \) -print0 2>/dev/null)
  if (( found > 0 )); then
    note "$found unmarked legacy candidate(s), approximately $(human_kib "$total_kib"); no deletion performed"
  else
    note "no unmarked legacy build-cache candidates found"
  fi
}

inventory_and_prune() {
  local apply_changes=0 quiet=0 include_legacy=0
  local max_per_kind="$default_keep" grace_seconds="$default_grace"
  protected_paths=()
  while (( $# > 0 )); do
    case "$1" in
      --apply) apply_changes=1; shift ;;
      --dry-run) apply_changes=0; shift ;;
      --quiet) quiet=1; shift ;;
      --legacy) include_legacy=1; shift ;;
      --protect)
        (( $# >= 2 )) || fail "--protect requires a path"
        [[ -d "$2" ]] || fail "protected path does not exist: $2"
        protected_paths+=("$(validate_target "$2")")
        shift 2
        ;;
      --max-per-kind)
        (( $# >= 2 )) || fail "--max-per-kind requires a value"
        max_per_kind="$2"
        shift 2
        ;;
      --grace-seconds)
        (( $# >= 2 )) || fail "--grace-seconds requires a value"
        grace_seconds="$2"
        shift 2
        ;;
      *) fail "unknown retention option: $1" ;;
    esac
  done
  is_unsigned_integer "$max_per_kind" || fail "invalid cache retention count: $max_per_kind"
  is_unsigned_integer "$grace_seconds" || fail "invalid grace period: $grace_seconds"

  local inventory="$(mktemp "$scan_root/.temustream-cache-inventory.XXXXXX")"
  local sorted="$(mktemp "$scan_root/.temustream-cache-sorted.XXXXXX")"
  trap 'rm -f -- "$inventory" "$sorted"' EXIT INT TERM
  local marker target kind last_used lease_pid active protected now
  now="$(current_epoch)"

  while IFS= read -r -d '' marker; do
    target="${marker:h}"
    target="$(validate_target "$target")"
    kind="$(marker_kind "$marker" 2>/dev/null || true)"
    if [[ -z "$kind" ]]; then
      (( quiet == 1 )) || note "SKIP invalid ownership marker: $target"
      continue
    fi
    last_used="$(sed -n '1p' "$target/$last_used_name" 2>/dev/null || true)"
    is_unsigned_integer "$last_used" || last_used="$(stat -f '%m' "$marker")"
    lease_pid="$(sed -n '1p' "$target/$lease_name" 2>/dev/null || true)"
    active=0
    if is_unsigned_integer "$lease_pid" && kill -0 "$lease_pid" 2>/dev/null; then
      active=1
    elif [[ -f "$target/$lease_name" && "$apply_changes" -eq 1 ]]; then
      rm -f -- "$target/$lease_name"
    fi
    protected=0
    path_overlaps_protection "$target" && protected=1
    print -r -- \
      "$last_used"$'\t'"$kind"$'\t'"$active"$'\t'"$protected"$'\t'"$target" \
      >> "$inventory"
  done < <(find "$scan_root" -xdev -mindepth 2 -maxdepth 7 \
    -type f -name "$marker_name" -print0 2>/dev/null)

  LC_ALL=C sort -t $'\t' -k2,2 -k1,1nr "$inventory" > "$sorted"
  typeset -A seen_by_kind
  local seen limit age size_kib prune_count=0 prune_kib=0 reason action
  while IFS=$'\t' read -r last_used kind active protected target; do
    [[ -n "$target" ]] || continue
    seen=$(( ${seen_by_kind[$kind]:-0} + 1 ))
    seen_by_kind[$kind]="$seen"
    limit="$max_per_kind"
    [[ "$kind" == "transient" ]] && limit=0
    age=$(( now > last_used ? now - last_used : 0 ))
    size_kib="$(du -sk "$target" 2>/dev/null | awk '{print $1}' || true)"
    size_kib="${size_kib:-0}"
    action="KEEP"
    reason="recent"
    if (( active == 1 )); then
      reason="active lease"
    elif (( protected == 1 )); then
      reason="protected"
    elif (( seen <= limit )); then
      reason="newest $limit"
    elif (( age < grace_seconds )); then
      reason="grace ${age}s/${grace_seconds}s"
    else
      action="PRUNE"
      reason="retention exceeded"
    fi

    if [[ "$action" == "PRUNE" ]]; then
      if (( apply_changes == 1 )); then
        [[ -f "$target/$marker_name" ]] \
          || fail "cache ownership marker disappeared before deletion: $target"
        marker_kind "$target/$marker_name" >/dev/null \
          || fail "cache ownership changed before deletion: $target"
        rm -rf -- "$target"
        prune_count=$((prune_count + 1))
        prune_kib=$((prune_kib + size_kib))
        (( quiet == 1 )) || note "PRUNED $kind $(human_kib "$size_kib") $target"
      else
        note "WOULD_PRUNE $kind $(human_kib "$size_kib") $target"
      fi
    elif (( quiet == 0 )); then
      note "KEEP $kind $(human_kib "$size_kib") ($reason) $target"
    fi
  done < "$sorted"

  rm -f -- "$inventory" "$sorted"
  trap - EXIT INT TERM
  if (( apply_changes == 1 && prune_count > 0 )); then
    note "pruned $prune_count owned cache(s), approximately $(human_kib "$prune_kib")"
  elif (( quiet == 0 && apply_changes == 1 )); then
    note "no owned caches exceeded retention"
  fi
  if (( include_legacy == 1 )); then
    report_legacy
  fi
  return 0
}

command_name="${1:-report}"
(( $# > 0 )) && shift
case "$command_name" in
  register) register_cache "$@" ;;
  release) release_cache "$@" ;;
  report) inventory_and_prune --dry-run "$@" ;;
  prune) inventory_and_prune "$@" ;;
  help|-h|--help) usage ;;
  *) usage >&2; fail "unknown command: $command_name" ;;
esac
