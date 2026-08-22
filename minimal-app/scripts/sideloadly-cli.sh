#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
snapshot_path="${SIDELOADLY_SNAPSHOT:-$repo_root/config/sideloadly-orangeapple.snapshot.json}"
support_dir="${HOME}/Library/Application Support/sideloadly"
database_path="$support_dir/installations.db"
cache_dir="${HOME}/Library/Caches/sideloadly"
anisette_option_path="$support_dir/option-anisette-mode"
zipstream_option_path="$support_dir/option-zipstream"
chunk_option_path="$support_dir/option-custom-chunk-size"
cli_tmp_dir=""
queue_token=""
silent_process_pid=""

note() {
  print -- "sideloadly-cli: $*"
}

fail() {
  print -u2 -- "sideloadly-cli: error: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/sideloadly-cli.sh snapshot
  ./scripts/sideloadly-cli.sh doctor
  ./scripts/sideloadly-cli.sh update [--ipa PATH] [--skip-build] [--dry-run] [--no-launch]

The update command builds the current app, updates the configured Sideloadly
AutoRefresh record, invokes Sideloadly 0.60's internal silent queue, verifies
the installed version with devicectl, and launches the app.

No Apple ID, password, session token, certificate, or private key is copied into
the repository or printed by this command.
USAGE
}

cleanup() {
  if [[ -n "${silent_process_pid:-}" ]] && kill -0 "$silent_process_pid" 2>/dev/null; then
    terminate_silent_process "$silent_process_pid" || true
  fi
  if [[ -n "${queue_token:-}" \
        && -n "${installation_id:-}" \
        && -f "${database_path:-}" ]]; then
    local escaped_cleanup_token
    escaped_cleanup_token="$(sql_escape "$queue_token")"
    sqlite3 "$database_path" \
      "UPDATE installations SET enqueued_at=NULL, enqueue_token=NULL WHERE id=$installation_id AND enqueue_token='$escaped_cleanup_token';" \
      >/dev/null 2>&1 || true
  fi
  if [[ -n "${cli_tmp_dir:-}" \
        && "$cli_tmp_dir" == /private/tmp/stremio-sideloadly-cli.* \
        && -d "$cli_tmp_dir" ]]; then
    rm -rf -- "$cli_tmp_dir"
  fi
}
trap cleanup EXIT INT TERM

redact_sideloadly_log() {
  sed -E \
    -e 's/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/<redacted-email>/Ig' \
    -e 's/^Final anisette map.*/Final anisette map [redacted]/' \
    -e 's/^Sideloadly will be shown.*/Sideloadly client identity prepared [redacted]/' \
    -e 's/^Using team .*/Using configured Apple developer team [redacted]/' \
    -e 's/EnqueueToken:[^ ]*/EnqueueToken:<redacted>/g'
}

terminate_silent_process() {
  local process_pid="$1" child_pid
  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] && kill -TERM "$child_pid" 2>/dev/null || true
  done < <(pgrep -P "$process_pid" || true)
  kill -TERM "$process_pid" 2>/dev/null || true
  for _ in {1..10}; do
    kill -0 "$process_pid" 2>/dev/null || return 0
    sleep 0.2
  done
  kill -KILL "$process_pid" 2>/dev/null || true
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

json_value() {
  jq -er "$1" "$snapshot_path"
}

sql_escape() {
  print -rn -- "$1" | sed "s/'/''/g"
}

read_option() {
  [[ -f "$1" ]] || fail "Missing Sideloadly option file: $1"
  tr -d '\r\n' < "$1"
}

ensure_tmp_dir() {
  if [[ -z "$cli_tmp_dir" ]]; then
    cli_tmp_dir="$(mktemp -d /private/tmp/stremio-sideloadly-cli.XXXXXX)"
  fi
}

load_snapshot() {
  [[ -f "$snapshot_path" ]] || fail "Settings snapshot not found: $snapshot_path"
  snapshot_schema="$(json_value '.schemaVersion')"
  [[ "$snapshot_schema" == "1" ]] || fail "Unsupported snapshot schema: $snapshot_schema"

  sideloadly_app="$(json_value '.sideloadly.appPath')"
  expected_sideloadly_version="$(json_value '.sideloadly.version')"
  sideloadly_binary="$sideloadly_app/Contents/MacOS/Sideloadly"
  device_name="$(json_value '.device.name')"
  device_udid="$(json_value '.device.udid')"
  source_bundle_id="$(json_value '.app.sourceBundleID')"
  installed_bundle_id="$(json_value '.app.installedBundleID')"
  required_entitlement="$(json_value '.app.requiredEntitlement')"
  expected_anisette_value="$(json_value '.sideloadly.settings.anisetteDatabaseValue')"
  expected_sign_mode="$(json_value '.sideloadly.settings.signingModeDatabaseValue')"
  expected_refresh_hours="$(json_value '.sideloadly.settings.refreshAfterHours')"
}

load_installation_record() {
  local escaped_udid escaped_bundle record_count record_row
  escaped_udid="$(sql_escape "$device_udid")"
  escaped_bundle="$(sql_escape "$installed_bundle_id")"

  record_count="$(sqlite3 "$database_path" \
    "SELECT COUNT(*) FROM installations WHERE deleted_at IS NULL AND device_udid='$escaped_udid' AND final_bundle_id='$escaped_bundle';")"
  [[ "$record_count" == "1" ]] || fail \
    "Expected exactly one AutoRefresh record for $device_name/$installed_bundle_id; found $record_count"

  record_row="$(sqlite3 -noheader -separator $'\t' "$database_path" \
    "SELECT i.id, i.ipa_id, COALESCE(f.stored_name,'-'), COALESCE(i.anisette_mode,-1), COALESCE(i.sign_mode,-1), COALESCE(i.drop_plugins,-1), COALESCE(i.alt_entitlements_id,0), COALESCE(json(i.info_props),'{}'), COALESCE(i.one_off,-1), COALESCE(i.refresh_at_hours,-1), CASE WHEN length(i.apple_id)>3 THEN 1 ELSE 0 END, COALESCE(i.last_updated,'-'), COALESCE(i.version,'-') FROM installations i LEFT JOIN stored_files f ON f.id=i.ipa_id WHERE i.deleted_at IS NULL AND i.device_udid='$escaped_udid' AND i.final_bundle_id='$escaped_bundle' LIMIT 1;")"
  IFS=$'\t' read -r installation_id previous_ipa_id previous_stored_name \
    record_anisette record_sign_mode record_drop_plugins record_alt_entitlements \
    record_info_props record_one_off record_refresh_hours record_has_account \
    record_last_updated record_version <<< "$record_row"

  [[ "$record_anisette" == "$expected_anisette_value" ]] || fail \
    "AutoRefresh record no longer uses the captured Local Anisette setting"
  [[ "$record_sign_mode" == "$expected_sign_mode" ]] || fail \
    "AutoRefresh record no longer uses the captured Apple ID signing mode"
  [[ "$record_drop_plugins" == "0" ]] || fail "Drop Plug-ins is unexpectedly enabled"
  [[ "$record_alt_entitlements" == "0" ]] || fail "Custom entitlements are unexpectedly attached"
  [[ "$record_info_props" == "{}" ]] || fail "Info.plist mutations are unexpectedly configured"
  [[ "$record_one_off" == "0" ]] || fail "The installation is not enrolled for AutoRefresh"
  [[ "$record_refresh_hours" == "$expected_refresh_hours" ]] || fail \
    "Refresh interval differs from the captured snapshot"
  [[ "$record_has_account" == "1" ]] || fail "The AutoRefresh record has no saved Apple ID reference"
}

run_doctor() {
  local actual_version anisette_value zipstream_value chunk_value gui_pid
  local silent_flag_count enqueue_flag_count
  for dependency in jq sqlite3 plutil strings xcrun ditto unzip md5 stat grep codesign cmp pgrep; do
    require_command "$dependency"
  done
  [[ -x "$sideloadly_binary" ]] || fail "Sideloadly executable not found: $sideloadly_binary"
  [[ -f "$database_path" ]] || fail "Sideloadly database not found: $database_path"
  [[ -d "$cache_dir" ]] || fail "Sideloadly cache not found: $cache_dir"

  actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$sideloadly_app/Contents/Info.plist")"
  [[ "$actual_version" == "$expected_sideloadly_version" ]] || fail \
    "This wrapper is pinned to Sideloadly $expected_sideloadly_version; installed version is $actual_version"
  silent_flag_count="$(strings -a "$sideloadly_binary" | grep -Fxc -- '--silent' || true)"
  enqueue_flag_count="$(strings -a "$sideloadly_binary" | grep -Fxc -- 'enqueue' || true)"
  (( silent_flag_count >= 1 )) || fail \
    "Installed Sideloadly no longer exposes its internal --silent queue"
  (( enqueue_flag_count >= 1 )) || fail \
    "Installed Sideloadly no longer exposes its internal --enqueue queue"

  anisette_value="$(read_option "$anisette_option_path")"
  zipstream_value="$(read_option "$zipstream_option_path")"
  chunk_value="$(read_option "$chunk_option_path")"
  [[ "$anisette_value" == "$expected_anisette_value" ]] || fail \
    "Local Anisette option differs from the captured snapshot"
  [[ "$zipstream_value" == "0" ]] || fail "Dynamic upload differs from the captured snapshot"
  [[ "$chunk_value" == "-1" ]] || fail "Custom upload chunk size differs from the captured snapshot"

  load_installation_record
  ensure_tmp_dir
  xcrun devicectl device info details \
    --device "$device_udid" \
    --timeout 45 \
    --quiet \
    --json-output "$cli_tmp_dir/device.json" >/dev/null
  [[ "$(jq -r '.error // empty' "$cli_tmp_dir/device.json")" == "" ]] || fail \
    "$device_name is not available to CoreDevice"

  gui_pid="$(pgrep -f "${sideloadly_binary}$" || true)"
  if [[ -n "$gui_pid" ]]; then
    note "doctor: Sideloadly GUI is running (update will require it to be closed)"
  fi
  note "doctor: Sideloadly $actual_version, $device_name, and AutoRefresh record $installation_id are ready"
}

inspect_ipa() {
  local ipa_path="$1" app_count entitlement_value
  [[ -f "$ipa_path" ]] || fail "IPA not found: $ipa_path"
  unzip -tq "$ipa_path" >/dev/null || fail "IPA archive validation failed"
  ensure_tmp_dir
  unzip -Z1 "$ipa_path" > "$cli_tmp_dir/archive-entries.txt"
  if grep -q '^__MACOSX/' "$cli_tmp_dir/archive-entries.txt"; then
    fail "IPA contains an unsupported __MACOSX archive root"
  fi

  mkdir -p "$cli_tmp_dir/unpacked"
  ditto -x -k "$ipa_path" "$cli_tmp_dir/unpacked"
  [[ -d "$cli_tmp_dir/unpacked/Payload" ]] || fail "IPA root is missing Payload/"
  app_count="$(find "$cli_tmp_dir/unpacked/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
  [[ "$app_count" == "1" ]] || fail "Expected one application under Payload/; found $app_count"
  ipa_app_dir="$(find "$cli_tmp_dir/unpacked/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"
  [[ -f "$ipa_app_dir/Info.plist" ]] || fail "IPA application has no Info.plist"

  ipa_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$ipa_app_dir/Info.plist")"
  ipa_version="$(plutil -extract CFBundleShortVersionString raw -o - "$ipa_app_dir/Info.plist")"
  ipa_build="$(plutil -extract CFBundleVersion raw -o - "$ipa_app_dir/Info.plist")"
  ipa_name="$(plutil -extract CFBundleName raw -o - "$ipa_app_dir/Info.plist")"
  [[ "$ipa_bundle_id" == "$source_bundle_id" ]] || fail \
    "IPA bundle ID is $ipa_bundle_id; expected $source_bundle_id"

  codesign --display --entitlements :- "$ipa_app_dir" \
    > "$cli_tmp_dir/entitlements.plist" 2>/dev/null
  entitlement_value="$(plutil -convert json -o - "$cli_tmp_dir/entitlements.plist" 2>/dev/null \
    | jq -r --arg key "$required_entitlement" '.[$key] // false')"
  [[ "$entitlement_value" == "true" || "$entitlement_value" == "1" ]] || fail \
    "IPA does not request the required $required_entitlement entitlement"

  ipa_md5="$(md5 -q "$ipa_path" | tr '[:upper:]' '[:lower:]')"
  ipa_size="$(stat -f '%z' "$ipa_path")"
  ipa_absolute_path="${ipa_path:A}"
  note "IPA: $ipa_name $ipa_version ($ipa_build), $ipa_size bytes, md5=$ipa_md5"
}

stage_ipa_for_record() {
  local timestamp backup_dir database_backup stored_name cache_target temp_cache_target
  local escaped_stored_name escaped_nickname escaped_queue_token new_ipa_id
  timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  backup_dir="$repo_root/build/sideloadly-cli-backups/$timestamp"
  mkdir -p "$backup_dir" "$repo_root/build/sideloadly-cli"
  database_backup="$backup_dir/installations.db"
  sqlite3 "$database_path" ".timeout 10000" ".backup '$database_backup'"

  stored_name="$ipa_md5.ipa"
  cache_target="$cache_dir/$stored_name"
  temp_cache_target="$cache_dir/.${stored_name}.tmp.$$"
  if [[ ! -f "$cache_target" ]] || ! cmp -s "$ipa_absolute_path" "$cache_target"; then
    ditto "$ipa_absolute_path" "$temp_cache_target"
    mv -f -- "$temp_cache_target" "$cache_target"
  fi
  [[ "$(md5 -q "$cache_target" | tr '[:upper:]' '[:lower:]')" == "$ipa_md5" ]] || fail \
    "Staged Sideloadly cache file failed its checksum"

  escaped_stored_name="$(sql_escape "$stored_name")"
  escaped_nickname="$(sql_escape "${ipa_absolute_path:t}")"
  queue_token="$(sqlite3 "$database_path" "SELECT lower(hex(randomblob(16)));" )"
  [[ ${#queue_token} == 32 && "$queue_token" != *[^0-9a-f]* ]] || fail \
    "Failed to create the one-time Sideloadly queue token"
  escaped_queue_token="$(sql_escape "$queue_token")"
  sqlite3 "$database_path" <<SQL
.timeout 10000
BEGIN IMMEDIATE;
INSERT INTO stored_files
  (created_at, updated_at, stored_name, nickname, ext, size, hash, uncached_path)
SELECT
  CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '$escaped_stored_name', '$escaped_nickname',
  '.ipa', $ipa_size, X'$ipa_md5', NULL
WHERE NOT EXISTS (
  SELECT 1 FROM stored_files WHERE stored_name='$escaped_stored_name' AND deleted_at IS NULL
);
UPDATE stored_files
SET updated_at=CURRENT_TIMESTAMP,
    nickname='$escaped_nickname',
    ext='.ipa',
    size=$ipa_size,
    hash=X'$ipa_md5',
    deleted_at=NULL
WHERE stored_name='$escaped_stored_name';
UPDATE installations
SET ipa_id=(SELECT id FROM stored_files WHERE stored_name='$escaped_stored_name' AND deleted_at IS NULL LIMIT 1),
    updated_at=CURRENT_TIMESTAMP,
    enqueued_at=CURRENT_TIMESTAMP,
    enqueue_token='$escaped_queue_token',
    last_error='',
    failures_count=0,
    last_failure_at=NULL
WHERE id=$installation_id;
COMMIT;
SQL
  new_ipa_id="$(sqlite3 "$database_path" \
    "SELECT ipa_id FROM installations WHERE id=$installation_id;")"
  [[ -n "$new_ipa_id" && "$new_ipa_id" != "0" ]] || fail "Failed to attach the new IPA to AutoRefresh"

  receipt_path="$repo_root/build/sideloadly-cli/$timestamp.json"
  jq -n \
    --arg capturedAt "$timestamp" \
    --arg device "$device_name" \
    --arg udid "$device_udid" \
    --arg ipa "$ipa_absolute_path" \
    --arg md5 "$ipa_md5" \
    --arg version "$ipa_version" \
    --arg build "$ipa_build" \
    --arg installedBundleID "$installed_bundle_id" \
    --arg databaseBackup "$database_backup" \
    --arg previousStoredName "$previous_stored_name" \
    --argjson installationID "$installation_id" \
    --argjson previousIPAID "$previous_ipa_id" \
    --argjson stagedIPAID "$new_ipa_id" \
    '{
      capturedAt: $capturedAt,
      status: "staged",
      device: $device,
      deviceUDID: $udid,
      installationID: $installationID,
      sourceIPA: $ipa,
      sourceMD5: $md5,
      version: $version,
      build: $build,
      installedBundleID: $installedBundleID,
      databaseBackup: $databaseBackup,
      previousIPAID: $previousIPAID,
      previousStoredName: $previousStoredName,
      stagedIPAID: $stagedIPAID
    }' > "$receipt_path"
  cp "$receipt_path" "$repo_root/build/sideloadly-cli/latest.json"
  note "staged: AutoRefresh record $installation_id now points to cached IPA $new_ipa_id"
  note "backup: $database_backup"
}

wait_for_silent_install() {
  local install_log raw_install_log deadline exit_status timed_out
  local queue_state current_last_updated current_error_length queue_marker_present
  local queue_completed queue_failed
  ensure_tmp_dir
  install_log="$repo_root/build/sideloadly-cli/install-$(date -u '+%Y%m%dT%H%M%SZ').log"
  raw_install_log="$cli_tmp_dir/sideloadly-install.raw.log"
  note "install: invoking Sideloadly's internal silent queue for record $installation_id"

  set +e
  "$sideloadly_binary" --silent --enqueue "$installation_id" >"$raw_install_log" 2>&1 &
  silent_process_pid=$!
  deadline=$((SECONDS + 1200))
  timed_out=0
  queue_completed=0
  queue_failed=0
  while kill -0 "$silent_process_pid" 2>/dev/null; do
    queue_state="$(sqlite3 -noheader -separator $'\t' "$database_path" \
      "SELECT COALESCE(last_updated,''), length(COALESCE(last_error,'')), CASE WHEN enqueue_token IS NULL OR enqueue_token='' THEN 0 ELSE 1 END FROM installations WHERE id=$installation_id;")"
    IFS=$'\t' read -r current_last_updated current_error_length queue_marker_present <<< "$queue_state"
    if [[ "$queue_marker_present" == "0" \
          && ( "$current_last_updated" != "$record_last_updated" || "$current_error_length" != "0" ) ]]; then
      queue_completed=1
      [[ "$current_error_length" == "0" ]] || queue_failed=1
      terminate_silent_process "$silent_process_pid"
      break
    fi
    if (( SECONDS >= deadline )); then
      timed_out=1
      terminate_silent_process "$silent_process_pid"
      break
    fi
    sleep 2
  done
  wait "$silent_process_pid"
  exit_status=$?
  silent_process_pid=""
  set -e
  redact_sideloadly_log < "$raw_install_log" > "$install_log"

  if (( queue_completed == 0 )); then
    queue_state="$(sqlite3 -noheader -separator $'\t' "$database_path" \
      "SELECT COALESCE(last_updated,''), length(COALESCE(last_error,'')), CASE WHEN enqueue_token IS NULL OR enqueue_token='' THEN 0 ELSE 1 END FROM installations WHERE id=$installation_id;")"
    IFS=$'\t' read -r current_last_updated current_error_length queue_marker_present <<< "$queue_state"
    if [[ "$queue_marker_present" == "0" \
          && ( "$current_last_updated" != "$record_last_updated" || "$current_error_length" != "0" ) ]]; then
      queue_completed=1
      [[ "$current_error_length" == "0" ]] || queue_failed=1
    fi
  fi

  if (( timed_out == 1 )); then
    fail "Sideloadly silent install timed out; log: $install_log"
  fi
  if (( queue_completed == 0 )); then
    tail -n 60 "$install_log" >&2
    fail "Sideloadly exited with status $exit_status before completing the queued install; log: $install_log"
  fi
  if (( queue_failed == 1 )); then
    tail -n 60 "$install_log" >&2
    fail "Sideloadly reported an installation error; log: $install_log"
  fi
  note "install: Sideloadly queue completed"
}

verify_and_launch() {
  local apps_json installed_version installed_build last_error launch_json receipt_temp
  ensure_tmp_dir
  apps_json="$cli_tmp_dir/apps-after.json"
  xcrun devicectl device info apps \
    --device "$device_udid" \
    --bundle-id "$installed_bundle_id" \
    --timeout 60 \
    --quiet \
    --json-output "$apps_json" >/dev/null
  installed_version="$(jq -er '.result.apps[0].version' "$apps_json")"
  installed_build="$(jq -er '.result.apps[0].bundleVersion' "$apps_json")"
  [[ "$installed_version" == "$ipa_version" ]] || fail \
    "Device still reports version $installed_version; expected $ipa_version"
  [[ "$installed_build" == "$ipa_build" ]] || fail \
    "Device still reports build $installed_build; expected $ipa_build"

  last_error="$(sqlite3 "$database_path" \
    "SELECT COALESCE(last_error,'') FROM installations WHERE id=$installation_id;")"
  [[ -z "$last_error" ]] || fail "Sideloadly recorded an installation error"

  if (( launch_after_install == 1 )); then
    launch_json="$cli_tmp_dir/launch.json"
    xcrun devicectl device process launch \
      --device "$device_udid" \
      --terminate-existing \
      --activate \
      --timeout 60 \
      --quiet \
      --json-output "$launch_json" \
      "$installed_bundle_id" >/dev/null
    [[ "$(jq -r '.error // empty' "$launch_json")" == "" ]] || fail \
      "The updated app installed but did not launch"
    note "launch: $ipa_name $ipa_version ($ipa_build) opened on $device_name"
  fi

  receipt_temp="$cli_tmp_dir/receipt-complete.json"
  jq \
    --arg status "complete" \
    --arg installedVersion "$installed_version" \
    --arg installedBuild "$installed_build" \
    --argjson launched "$launch_after_install" \
    '.status=$status | .installedVersion=$installedVersion | .installedBuild=$installedBuild | .launched=($launched == 1)' \
    "$receipt_path" > "$receipt_temp"
  mv -f "$receipt_temp" "$receipt_path"
  cp "$receipt_path" "$repo_root/build/sideloadly-cli/latest.json"
  note "verified: $installed_bundle_id is installed on $device_name"
  note "receipt: $receipt_path"
}

load_snapshot
command_name="${1:-help}"
if (( $# > 0 )); then shift; fi

case "$command_name" in
  help|-h|--help)
    usage
    ;;
  snapshot)
    jq '.' "$snapshot_path"
    ;;
  doctor)
    run_doctor
    ;;
  update)
    ipa_path="$repo_root/$(json_value '.app.defaultIPA')"
    skip_build=0
    dry_run=0
    launch_after_install=1
    while (( $# > 0 )); do
      case "$1" in
        --ipa)
          (( $# >= 2 )) || fail "--ipa requires a path"
          ipa_path="$2"
          shift 2
          ;;
        --skip-build)
          skip_build=1
          shift
          ;;
        --dry-run)
          dry_run=1
          shift
          ;;
        --no-launch)
          launch_after_install=0
          shift
          ;;
        *)
          fail "Unknown update option: $1"
          ;;
      esac
    done

    run_doctor
    if (( skip_build == 0 && dry_run == 0 )); then
      note "build: creating the current device IPA"
      "$repo_root/scripts/build-device.sh"
    fi
    inspect_ipa "$ipa_path"
    if (( dry_run == 1 )); then
      note "dry-run: settings, device, AutoRefresh record, IPA, and entitlement are valid"
      exit 0
    fi
    if pgrep -f "${sideloadly_binary}$" >/dev/null 2>&1; then
      fail "Quit the visible Sideloadly window before using the headless update command"
    fi
    stage_ipa_for_record
    wait_for_silent_install
    verify_and_launch
    ;;
  *)
    usage >&2
    fail "Unknown command: $command_name"
    ;;
esac
