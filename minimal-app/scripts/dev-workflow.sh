#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
source_root="${script_dir:h}"

find_git_root() {
  local candidate="$source_root"
  while [[ "$candidate" != "/" ]]; do
    if [[ -d "$candidate/.git" ]]; then
      print -r -- "$candidate"
      return 0
    fi
    candidate="${candidate:h}"
  done
  return 1
}

git_root="$(find_git_root)" || {
  print -u2 -- "dev-workflow: error: no parent Git repository found"
  exit 1
}
git_dir="$git_root/.git"
repo_prefix="${source_root#$git_root/}"
repo_prefix="${repo_prefix%/}/"
repo_pathspec=":(top)$repo_prefix"
source_commit="$(git --git-dir="$git_dir" rev-parse HEAD)"

dev_root="${STREMIO_DEV_ROOT:-/private/tmp/stremio-dev-workflow}"
shared_cache_root="${STREMIO_BUILD_CACHE_ROOT:-/private/tmp/stremio-build-cache}"
mirror="$dev_root/repository.git"
bases_root="$dev_root/bases"
workspace="$dev_root/workspace"
cache_root="${STREMIO_DEV_CACHE_ROOT:-$shared_cache_root}"
metadata_out="${STREMIO_DEV_METADATA_OUT:-$dev_root/latest.json}"
prepare_lock="$dev_root/locks/prepare.lock"
build_lock="$dev_root/locks/xcode.lock"
rust_lock="$dev_root/locks/rust.lock"
derived_data="${STREMIO_DEV_DERIVED_DATA:-$cache_root/DerivedData}"
build_root="${STREMIO_DEV_BUILD_ROOT:-$cache_root/products}"
rust_target="${STREMIO_DEV_RUST_TARGET:-$cache_root/rust-target}"
overlay_cache="$dev_root/overlay-cache"
retention_tool="$source_root/scripts/build-cache-retention.sh"

# Keep bootstrap self-contained. In a File Provider checkout, sourcing even a
# tiny helper can block while macOS hydrates it, which defeats this launcher's
# purpose of moving work into a local scratch workspace.
stremio_acquire_lock() {
  local lock_dir="$1"
  local lock_label="$2"
  local lock_timeout="${3:-300}"
  local lock_started lock_owner lock_now
  lock_started="$(date +%s)"

  mkdir -p "${lock_dir:h}"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    lock_owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    if [[ "$lock_owner" == <-> ]] && ! kill -0 "$lock_owner" 2>/dev/null; then
      rm -f -- "$lock_dir/pid" 2>/dev/null || true
      rmdir -- "$lock_dir" 2>/dev/null || true
      continue
    fi

    lock_now="$(date +%s)"
    if (( lock_now - lock_started >= lock_timeout )); then
      print -u2 -- "Timed out waiting for $lock_label (owner pid ${lock_owner:-unknown})"
      return 1
    fi
    sleep 1
  done

  print -r -- "$$" > "$lock_dir/pid"
}

stremio_release_lock() {
  local lock_dir="${1:-}"
  local lock_owner
  [[ -n "$lock_dir" ]] || return 0
  lock_owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [[ -z "$lock_owner" || "$lock_owner" == "$$" ]]; then
    rm -f -- "$lock_dir/pid" 2>/dev/null || true
    rmdir -- "$lock_dir" 2>/dev/null || true
  fi
}

note() {
  print -u2 -- "dev-workflow: $*"
}

fail() {
  print -u2 -- "dev-workflow: error: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/dev-workflow.sh prepare
  ./scripts/dev-workflow.sh test
  ./scripts/dev-workflow.sh typecheck-watchos
  ./scripts/dev-workflow.sh typecheck-tvos
  ./scripts/dev-workflow.sh build-simulator
  ./scripts/dev-workflow.sh build-watchos
  ./scripts/dev-workflow.sh build-tvos
  ./scripts/dev-workflow.sh build-device
  ./scripts/dev-workflow.sh screenshots [STATE ...]
  ./scripts/dev-workflow.sh cache-report
  ./scripts/dev-workflow.sh prune-cache

The workflow creates an exact local scratch workspace from the current remote
commit, overlays current tracked/untracked source edits one file at a time,
verifies source/destination sizes and SHA-256 hashes, and reuses persistent
SwiftPM, Xcode, Rust, VLC, and screenshot caches outside File Provider.

Set STREMIO_DEV_ROOT to choose another local scratch root. Set
STREMIO_BUILD_CACHE_ROOT to relocate the single shared bounded cache. Advanced
overrides remain available through STREMIO_DEV_DERIVED_DATA and related vars,
but every generated cache is registered for marker-owned retention.
USAGE
}

cleanup_stage=""
cleanup() {
  local exit_code=$?
  stremio_release_lock "$prepare_lock"
  if [[ -n "$cleanup_stage" && "$cleanup_stage" == "$dev_root"/stage.* && -d "$cleanup_stage" ]]; then
    rm -rf -- "$cleanup_stage"
  fi
  return "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_bounded() {
  local seconds="$1"
  shift
  /usr/bin/perl -e '
    my $seconds = shift @ARGV;
    $SIG{ALRM} = sub { exit 124 };
    alarm($seconds);
    exec @ARGV or exit 127;
  ' "$seconds" "$@"
}

safe_generated_remove() {
  local target="$1"
  case "$target" in
    "$dev_root"/stage.*|"$bases_root"/.base.*) rm -rf -- "$target" ;;
    *) fail "refusing to remove unexpected generated path: $target" ;;
  esac
}

prune_abandoned_stages() {
  local grace="${STREMIO_DEV_STAGE_GRACE_SECONDS:-3600}"
  local now candidate modified removed=0
  [[ "$grace" == <-> ]] || fail "invalid stage grace period: $grace"
  now="$(date +%s)"
  for candidate in "$dev_root"/stage.*(N/); do
    [[ -n "$cleanup_stage" && "$candidate" == "$cleanup_stage" ]] && continue
    modified="$(stat -f '%m' "$candidate")"
    if (( now - modified >= grace )); then
      safe_generated_remove "$candidate"
      removed=$((removed + 1))
    fi
  done
  (( removed == 0 )) || note "removed $removed abandoned source stage(s)"
}

ensure_remote_base() {
  local base_dir="$bases_root/$source_commit"
  local base_temp="$bases_root/.base.$source_commit.$$"
  local archive_path="$base_temp/source.tar"

  mkdir -p "$dev_root" "$bases_root" "$cache_root" "$dev_root/locks"
  if [[ ! -d "$mirror" ]]; then
    note "initializing the local Git object cache"
    git init --bare "$mirror" >/dev/null
  fi
  if ! git --git-dir="$mirror" cat-file -e "$source_commit^{commit}" 2>/dev/null; then
    note "fetching current commit $source_commit into the local cache"
    git --git-dir="$mirror" fetch --quiet "$git_dir" "$source_commit"
  fi

  if [[ ! -d "$base_dir/$repo_prefix" ]]; then
    safe_generated_remove "$base_temp" 2>/dev/null || true
    mkdir -p "$base_temp"
    git --git-dir="$mirror" archive --format=tar "$source_commit" "$repo_prefix" > "$archive_path"
    [[ -s "$archive_path" ]] || fail "the local Git archive was empty"
    tar -xf "$archive_path" -C "$base_temp"
    rm -f -- "$archive_path"
    [[ -s "$base_temp/$repo_prefix/project.yml" ]] || fail "the local Git base is incomplete"
    mv "$base_temp" "$base_dir"
  fi
  print -r -- "$base_dir/$repo_prefix"
}

allowed_untracked_source() {
  local relative="$1"
  case "$relative" in
    'iOS/Resources/Info '[0-9]*'.plist') return 1 ;;
    Sources/*.swift|Sources/**/*.swift|Tests/*.swift|Tests/**/*.swift|iOS/App/*|iOS/App/**/*|iOS/UITests/*|iOS/UITests/**/*|iOS/Resources/PrivacyInfo.xcprivacy|iOS/Resources/Assets.xcassets/*|iOS/Resources/Assets.xcassets/**/*|tvOS/*|tvOS/**/*|watchOS/*|watchOS/**/*|rust/*|rust/**/*|Fixtures/*|Fixtures/**/*|scripts/*.sh|Backend/watch-together/*|Backend/watch-together/**/*) return 0 ;;
    *) return 1 ;;
  esac
}

copy_verified_file() {
  local source_file="$1"
  local destination_file="$2"
  local logical_size source_hash copied_hash copied_size temp_file relative_path
  local source_metadata cache_key cache_file cache_meta cached_metadata cached_hash
  local source_metadata_after attempt verified=0

  [[ -f "$source_file" ]] || fail "source overlay disappeared: $source_file"
  logical_size="$(stat -f '%z' "$source_file")"
  [[ "$logical_size" -gt 0 ]] || fail "refusing zero-byte source overlay: ${source_file#$git_root/}"
  source_metadata="$(stat -f '%z:%m:%c:%i' "$source_file")"
  relative_path="${source_file#$source_root/}"
  [[ "$relative_path" != "$source_file" ]] || fail "overlay is outside the app source root"
  cache_key="$(print -rn -- "$relative_path" | shasum -a 256 | awk '{print $1}')"
  cache_file="$overlay_cache/$cache_key.data"
  cache_meta="$overlay_cache/$cache_key.meta"
  mkdir -p "$overlay_cache"

  cached_metadata="$(sed -n '1p' "$cache_meta" 2>/dev/null || true)"
  cached_hash="$(sed -n '2p' "$cache_meta" 2>/dev/null || true)"
  if [[ "$cached_metadata" == "$source_metadata" \
        && ${#cached_hash} -eq 64 \
        && -s "$cache_file" \
        && "$(stat -f '%z' "$cache_file")" == "$logical_size" \
        && "$(shasum -a 256 "$cache_file" | awk '{print $1}')" == "$cached_hash" ]]; then
    mkdir -p "${destination_file:h}"
    temp_file="$destination_file.tmp.$$"
    /bin/cp -p "$cache_file" "$temp_file"
    mv -f -- "$temp_file" "$destination_file"
    return 0
  fi

  if ls -lO "$source_file" 2>/dev/null | grep -q dataless; then
    command -v brctl >/dev/null 2>&1 && brctl download "$source_file" >/dev/null 2>&1 || true
  fi
  mkdir -p "${destination_file:h}"
  temp_file="$destination_file.tmp.$$"

  # File Provider may finish hydration between the hash and copy operations.
  # Accept only a stable metadata window and matching byte hashes; retry that
  # one source instead of failing the entire build on a transient transition.
  for attempt in 1 2 3; do
    rm -f -- "$temp_file"
    logical_size="$(stat -f '%z' "$source_file")"
    source_metadata="$(stat -f '%z:%m:%c:%i' "$source_file")"
    source_hash=""
    if source_hash="$(run_bounded 45 shasum -a 256 "$source_file" | awk '{print $1}')" \
        && [[ ${#source_hash} -eq 64 ]] \
        && run_bounded 45 /bin/cp -p "$source_file" "$temp_file"; then
      source_metadata_after="$(stat -f '%z:%m:%c:%i' "$source_file")"
      copied_size="$(stat -f '%z' "$temp_file")"
      copied_hash="$(shasum -a 256 "$temp_file" | awk '{print $1}')"
      if [[ "$source_metadata_after" == "$source_metadata" \
            && "$copied_size" == "$logical_size" \
            && "$copied_hash" == "$source_hash" ]]; then
        verified=1
        break
      fi
    fi
    if (( attempt < 3 )); then
      note "source: retrying unstable File Provider read for $relative_path ($attempt/3)"
      sleep 0.25
    fi
  done
  (( verified == 1 )) || fail \
    "source remained unstable while staging ${source_file#$git_root/} after 3 attempts"

  mv -f -- "$temp_file" "$destination_file"
  /bin/cp -p "$destination_file" "$cache_file.tmp.$$"
  mv -f -- "$cache_file.tmp.$$" "$cache_file"
  {
    print -r -- "$source_metadata"
    print -r -- "$source_hash"
  } > "$cache_meta.tmp.$$"
  mv -f -- "$cache_meta.tmp.$$" "$cache_meta"
}

write_manifest() {
  local root="$1"
  local output="$2"
  local list_file="$output.files"
  local relative size digest

  (
    cd "$root"
    for candidate in Package.swift project.yml Sources Tests iOS tvOS watchOS Vendor/KSPlayer rust Fixtures scripts config; do
      if [[ -f "$candidate" ]]; then
        print -r -- "$candidate"
      elif [[ -d "$candidate" ]]; then
        find "$candidate" -type f \
          ! -path '*/target/*' \
          ! -path '*/node_modules/*' \
          ! -name '.DS_Store' \
          ! -name 'Info [0-9]*.plist' -print
      fi
    done | LC_ALL=C sort -u
  ) > "$list_file"
  [[ -s "$list_file" ]] || fail "source manifest file list is empty"

  : > "$output"
  while IFS= read -r relative; do
    [[ -f "$root/$relative" ]] || fail "manifest input disappeared: $relative"
    size="$(stat -f '%z' "$root/$relative")"
    [[ "$size" -gt 0 ]] || fail "zero-byte build input: $relative"
    digest="$(shasum -a 256 "$root/$relative" | awk '{print $1}')"
    [[ ${#digest} -eq 64 ]] || fail "could not hash build input: $relative"
    print -r -- "$digest\t$size\t$relative" >> "$output"
  done < "$list_file"
  rm -f -- "$list_file"
}

prepare_workspace() {
  local phase_started=$SECONDS
  local base_dir stage_dir changed_list modified_list staged_list untracked_list repo_path relative
  local modified_pid staged_pid untracked_pid modified_result staged_result untracked_result
  local manifest source_id file_count overlay_count=0

  stremio_acquire_lock "$prepare_lock" "the Stremio source materializer" 180
  prune_abandoned_stages
  "$retention_tool" prune --apply --quiet
  note "source: staging the committed base in local scratch storage"
  base_dir="$(ensure_remote_base)"
  cleanup_stage="$(mktemp -d "$dev_root/stage.XXXXXX")"
  stage_dir="$cleanup_stage/workspace"
  ditto "$base_dir" "$stage_dir"

  changed_list="$cleanup_stage/changed.zlist"
  modified_list="$cleanup_stage/modified.zlist"
  staged_list="$cleanup_stage/staged.zlist"
  untracked_list="$cleanup_stage/untracked.zlist"
  # `git diff` hashes modified working-tree files. In a File Provider checkout
  # that can block indefinitely while macOS hydrates every dataless source,
  # defeating the verified overlay cache below. `ls-files -m -d` uses the
  # index/stat cache to identify working-tree overlays without opening their
  # contents; the cached diff separately covers staged-only paths.
  note "source: inventorying modified, staged, and untracked paths in parallel"
  run_bounded 15 git --git-dir="$git_dir" --work-tree="$git_root" \
    ls-files --full-name -m -d --deduplicate -z -- "$repo_pathspec" > "$modified_list" &
  modified_pid=$!
  run_bounded 15 git --git-dir="$git_dir" --work-tree="$git_root" \
    diff --cached --name-only --no-relative -z -- "$repo_pathspec" > "$staged_list" &
  staged_pid=$!
  run_bounded 15 git --git-dir="$git_dir" --work-tree="$git_root" \
    ls-files --full-name --others --exclude-standard -z -- "$repo_pathspec" > "$untracked_list" &
  untracked_pid=$!

  if wait "$modified_pid"; then modified_result=0; else modified_result=$?; fi
  if wait "$staged_pid"; then staged_result=0; else staged_result=$?; fi
  if wait "$untracked_pid"; then untracked_result=0; else untracked_result=$?; fi
  (( modified_result == 0 )) || fail "could not inventory modified source paths within 15 seconds"
  (( staged_result == 0 )) || fail "could not inventory staged source paths within 15 seconds"
  (( untracked_result == 0 )) || fail "could not inventory untracked source paths within 15 seconds"
  cat "$modified_list" "$staged_list" > "$changed_list"

  note "source: verifying current overlays against the local cache"

  while IFS= read -r -d '' repo_path; do
    [[ "$repo_path" == "$repo_prefix"* ]] || fail "unexpected changed path: $repo_path"
    relative="${repo_path#$repo_prefix}"
    if [[ -f "$git_root/$repo_path" ]]; then
      copy_verified_file "$git_root/$repo_path" "$stage_dir/$relative"
      overlay_count=$((overlay_count + 1))
    else
      rm -f -- "$stage_dir/$relative"
    fi
  done < "$changed_list"

  while IFS= read -r -d '' repo_path; do
    [[ "$repo_path" == "$repo_prefix"* ]] || continue
    relative="${repo_path#$repo_prefix}"
    allowed_untracked_source "$relative" || continue
    copy_verified_file "$git_root/$repo_path" "$stage_dir/$relative"
    overlay_count=$((overlay_count + 1))
  done < "$untracked_list"

  # This ignored file contains public endpoints needed by the app build. It is
  # copied without printing its contents or digest. Apple/Sideloadly secrets are
  # intentionally not part of the build workspace.
  if [[ -f "$source_root/config/WatchTogether.local.xcconfig" ]]; then
    copy_verified_file "$source_root/config/WatchTogether.local.xcconfig" \
      "$stage_dir/config/WatchTogether.local.xcconfig"
    overlay_count=$((overlay_count + 1))
  fi

  mkdir -p "$workspace" "$workspace/build"
  rsync -a --delete \
    --exclude '/build/' \
    --exclude '/.build/' \
    --exclude '/node_modules/' \
    "$stage_dir/" "$workspace/"
  manifest="$cleanup_stage/workspace-manifest.tsv"
  write_manifest "$workspace" "$manifest"
  file_count="$(wc -l < "$manifest" | tr -d ' ')"
  source_id="$(shasum -a 256 "$manifest" | awk '{print $1}')"
  [[ "$file_count" -gt 0 && ${#source_id} -eq 64 ]] || fail "source manifest validation failed"
  cp "$manifest" "$workspace/.stremio-source-manifest.tsv"
  print -r -- "$source_id" > "$workspace/.stremio-source-id"
  [[ ! -s "$workspace/Sources/StremioSkeletonCore/Models.swift" ]] \
    && fail "post-copy Models.swift is missing or zero bytes"

  prepared_seconds=$((SECONDS - phase_started))
  current_source_id="$source_id"
  current_file_count="$file_count"
  current_overlay_count="$overlay_count"
  stremio_release_lock "$prepare_lock"
  cleanup_stage=""
  safe_generated_remove "${stage_dir:h}"
  note "prepared $file_count verified files ($overlay_count overlays) as ${source_id[1,12]} in ${prepared_seconds}s"
}

write_metadata() {
  local operation="$1"
  local artifact_path="${2:-}"
  local artifact_hash=""
  local finished_at
  finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  if [[ -n "$artifact_path" ]]; then
    [[ -s "$artifact_path" ]] || fail "expected artifact is missing: $artifact_path"
    artifact_hash="$(shasum -a 256 "$artifact_path" | awk '{print $1}')"
  fi
  mkdir -p "${metadata_out:h}"
  jq -n \
    --arg operation "$operation" \
    --arg workspace "$workspace" \
    --arg cacheRoot "$cache_root" \
    --arg sourceID "$current_source_id" \
    --arg commit "$source_commit" \
    --arg artifact "$artifact_path" \
    --arg artifactSHA256 "$artifact_hash" \
    --arg capturedAt "$finished_at" \
    --argjson sourceFiles "$current_file_count" \
    --argjson overlayFiles "$current_overlay_count" \
    --argjson prepareSeconds "$prepared_seconds" \
    --argjson operationSeconds "${operation_seconds:-0}" \
    '{
      schemaVersion: 1,
      operation: $operation,
      workspace: $workspace,
      cacheRoot: $cacheRoot,
      sourceID: $sourceID,
      commit: $commit,
      sourceFiles: $sourceFiles,
      overlayFiles: $overlayFiles,
      artifact: (if $artifact == "" then null else $artifact end),
      artifactSHA256: (if $artifactSHA256 == "" then null else $artifactSHA256 end),
      timingsSeconds: {prepare: $prepareSeconds, operation: $operationSeconds},
      capturedAt: $capturedAt
    }' > "$metadata_out.tmp.$$"
  mv -f -- "$metadata_out.tmp.$$" "$metadata_out"
  note "metadata: $metadata_out"
}

run_in_workspace() {
  local command_path="$1"
  shift
  (
    cd "$workspace"
    SKELETON_BUILD_ROOT="$build_root" \
    SKELETON_DERIVED_DATA="$derived_data" \
    SKELETON_RUST_TARGET_DIR="$rust_target" \
    STREMIO_BUILD_CACHE_ROOT="$cache_root" \
    SKELETON_BUILD_LOCK="$build_lock" \
    SKELETON_RUST_BUILD_LOCK="$rust_lock" \
    SKELETON_VLC_VALIDATION_CACHE=1 \
    STREMIO_SOURCE_ID="$current_source_id" \
    UI_SCREENSHOT_SOURCE_ID="$current_source_id" \
      "$command_path" "$@"
  )
}

command_name="${1:-help}"
(( $# > 0 )) && shift
case "$command_name" in
  help|-h|--help)
    usage
    ;;
  prepare)
    (( $# == 0 )) || fail "prepare does not accept arguments"
    prepare_workspace
    operation_seconds=0
    write_metadata prepare
    ;;
  test)
    (( $# == 0 )) || fail "test does not accept arguments"
    prepare_workspace
    operation_started=$SECONDS
    CARGO_TARGET_DIR="$rust_target" run_in_workspace "$workspace/scripts/test.sh"
    operation_seconds=$((SECONDS - operation_started))
    write_metadata test
    ;;
  typecheck-tvos)
    (( $# == 0 )) || fail "typecheck-tvos does not accept arguments"
    prepare_workspace
    operation_started=$SECONDS
    run_in_workspace "$workspace/scripts/build-tvos.sh" --typecheck
    operation_seconds=$((SECONDS - operation_started))
    write_metadata typecheck-tvos
    ;;
  typecheck-watchos)
    (( $# == 0 )) || fail "typecheck-watchos does not accept arguments"
    prepare_workspace
    operation_started=$SECONDS
    run_in_workspace "$workspace/scripts/build-watchos.sh" --typecheck
    operation_seconds=$((SECONDS - operation_started))
    write_metadata typecheck-watchos
    ;;
  build-simulator)
    (( $# == 0 )) || fail "build-simulator does not accept arguments"
    prepare_workspace
    operation_started=$SECONDS
    run_in_workspace "$workspace/scripts/build-simulator.sh"
    operation_seconds=$((SECONDS - operation_started))
    write_metadata build-simulator "$workspace/build/StremioSkeleton-simulator.zip"
    ;;
  build-tvos)
    (( $# == 0 )) || fail "build-tvos does not accept arguments"
    prepare_workspace
    operation_started=$SECONDS
    run_in_workspace "$workspace/scripts/build-tvos.sh"
    operation_seconds=$((SECONDS - operation_started))
    write_metadata build-tvos "$workspace/build/TemuStreamTV-simulator.zip"
    ;;
  build-watchos)
    (( $# == 0 )) || fail "build-watchos does not accept arguments"
    prepare_workspace
    operation_started=$SECONDS
    run_in_workspace "$workspace/scripts/build-watchos.sh"
    operation_seconds=$((SECONDS - operation_started))
    write_metadata build-watchos "$workspace/build/TemuStremioWatch-simulator.zip"
    ;;
  build-device)
    (( $# == 0 )) || fail "build-device does not accept arguments"
    prepare_workspace
    operation_started=$SECONDS
    run_in_workspace "$workspace/scripts/build-device.sh"
    operation_seconds=$((SECONDS - operation_started))
    write_metadata build-device "$workspace/build/StremioSkeleton-device.ipa"
    ;;
  screenshots)
    prepare_workspace
    states="$*"
    [[ -n "$states" ]] || states="home-series"
    operation_started=$SECONDS
    UI_SCREENSHOT_STATES="$states" run_in_workspace "$workspace/scripts/ui-state-screenshots.sh"
    operation_seconds=$((SECONDS - operation_started))
    write_metadata screenshots "$workspace/build/ui-states/${${states%% *}//\//-}.png"
    ;;
  cache-report)
    (( $# == 0 )) || fail "cache-report does not accept arguments"
    "$retention_tool" report --legacy
    ;;
  prune-cache)
    (( $# == 0 )) || fail "prune-cache does not accept arguments"
    "$retention_tool" prune --apply --legacy
    ;;
  *)
    usage >&2
    fail "unknown command: $command_name"
    ;;
esac
