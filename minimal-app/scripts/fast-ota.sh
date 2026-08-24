#!/bin/zsh
set -euo pipefail
umask 077

script_dir="${0:A:h}"
repo_root="${script_dir:h}"
snapshot_path="${SIDELOADLY_SNAPSHOT:-$repo_root/config/sideloadly-orangeapple.snapshot.json}"
sideloadly_support_dir="${HOME}/Library/Application Support/sideloadly"
fast_ota_support_dir="${STREMIO_FAST_OTA_SUPPORT:-${HOME}/Library/Application Support/stremio-fast-ota}"
profile_cache="$fast_ota_support_dir/profile.mobileprovision"

work_dir=""
temporary_keychain=""
search_list_changed=0
original_keychains=()
signing_certificate=""
signing_fingerprint=""
profile_plist=""
profile_team_id=""
profile_expiration=""
issuer_certificate=""
device_transport=""

note() {
  print -- "fast-ota: $*"
}

fail() {
  print -u2 -- "fast-ota: error: $*"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage:
  ./scripts/fast-ota.sh doctor [--seed-ipa PATH]
  ./scripts/fast-ota.sh update [--skip-build] [--ipa PATH] [--seed-ipa PATH]
                               [--dry-run] [--no-launch] [--no-stage]

The fast updater checks OrangeApple before doing expensive work, locally signs
the app with Sideloadly's active certificate and provisioning profile, installs
the signed .app directly over Apple's CoreDevice Wi-Fi tunnel, verifies the
installed build, and launches it.

Sideloadly is still the profile-renewal fallback. Run sideloadly-cli.sh update
when doctor reports that the seven-day provisioning profile has expired.

No Apple ID, password, session token, certificate private key, or temporary
keychain password is copied into the repository or printed.
USAGE
}

cleanup_signing_keychain() {
  if (( search_list_changed == 1 )); then
    if (( ${#original_keychains[@]} > 0 )); then
      security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    fi
    search_list_changed=0
  fi
  if [[ -n "$temporary_keychain" && -f "$temporary_keychain" ]]; then
    security delete-keychain "$temporary_keychain" >/dev/null 2>&1 || true
  fi
  temporary_keychain=""
  return 0
}

cleanup() {
  local exit_status=$?
  cleanup_signing_keychain
  if [[ -n "$work_dir" \
        && "$work_dir" == /private/tmp/stremio-fast-ota.* \
        && -d "$work_dir" ]]; then
    rm -rf -- "$work_dir"
  fi
  return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command is unavailable: $1"
}

json_value() {
  jq -er "$1" "$snapshot_path"
}

ensure_work_dir() {
  if [[ -z "$work_dir" ]]; then
    work_dir="$(mktemp -d /private/tmp/stremio-fast-ota.XXXXXX)"
  fi
}

load_snapshot() {
  [[ -f "$snapshot_path" ]] || fail "Settings snapshot not found: $snapshot_path"
  [[ "$(json_value '.schemaVersion')" == "1" ]] || fail "Unsupported snapshot schema"
  device_name="$(json_value '.device.name')"
  device_udid="$(json_value '.device.udid')"
  core_device_identifier="$(json_value '.device.coreDeviceIdentifier // .device.udid')"
  source_bundle_id="$(json_value '.app.sourceBundleID')"
  installed_bundle_id="$(json_value '.app.installedBundleID')"
  default_ipa="$repo_root/$(json_value '.app.defaultIPA')"
}

read_keychain_search_list() {
  local line
  original_keychains=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [[ -n "$line" ]] && original_keychains+=("$line")
  done < <(security list-keychains -d user)
  (( ${#original_keychains[@]} > 0 )) || fail "Could not capture the current user keychain search list"
}

preflight_device() {
  local output_path="$1" attempt_output reported_udid tunnel_state pairing_state boot_state
  local attempt command_succeeded
  reported_udid=""
  tunnel_state="missing"
  pairing_state="missing"
  boot_state="missing"

  for attempt in 1 2 3 4; do
    attempt_output="$output_path.$attempt"
    command_succeeded=1
    xcrun devicectl device info details \
      --device "$core_device_identifier" \
      --timeout 6 \
      --quiet \
      --json-output "$attempt_output" >/dev/null 2>"$attempt_output.log" || command_succeeded=0
    if (( command_succeeded == 1 )) && [[ "$(jq -r '.error // empty' "$attempt_output")" == "" ]]; then
      reported_udid="$(jq -r '.result.hardwareProperties.udid // empty' "$attempt_output")"
      tunnel_state="$(jq -r '.result.connectionProperties.tunnelState // empty' "$attempt_output")"
      pairing_state="$(jq -r '.result.connectionProperties.pairingState // empty' "$attempt_output")"
      boot_state="$(jq -r '.result.deviceProperties.bootState // empty' "$attempt_output")"
      device_transport="$(jq -r '.result.connectionProperties.transportType // empty' "$attempt_output")"
      if [[ "$reported_udid" == "$device_udid" \
            && "$pairing_state" == "paired" \
            && "$tunnel_state" == "connected" \
            && "$boot_state" == "booted" ]]; then
        mv -f -- "$attempt_output" "$output_path"
        note "preflight: $device_name is ready over $device_transport"
        return 0
      fi
    fi
    if (( attempt == 1 )); then
      note "preflight: waiting briefly for $device_name's CoreDevice tunnel"
    fi
    sleep 1
  done

  [[ -z "$reported_udid" || "$reported_udid" == "$device_udid" ]] || fail "CoreDevice resolved the wrong phone"
  [[ "$pairing_state" == "missing" || "$pairing_state" == "paired" ]] || fail "$device_name is no longer paired"
  fail "$device_name is unavailable (tunnel=${tunnel_state:-missing}, pairing=${pairing_state:-missing}, boot=${boot_state:-missing}). Wake and unlock it, then retry"
}

profile_is_valid() {
  local candidate="$1" expiration_epoch now_epoch expected_application_id profile_entitlements
  local provisioned_device device_index has_device
  [[ -f "$candidate" ]] || return 1
  ensure_work_dir
  profile_plist="$work_dir/profile.plist"
  security cms -D -i "$candidate" > "$profile_plist" 2>/dev/null || return 1

  profile_team_id="$(plutil -extract TeamIdentifier.0 raw -o - "$profile_plist" 2>/dev/null)" || return 1
  profile_expiration="$(plutil -extract ExpirationDate raw -o - "$profile_plist" 2>/dev/null)" || return 1
  expiration_epoch="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$profile_expiration" '+%s' 2>/dev/null)" || return 1
  now_epoch="$(date -u '+%s')"
  (( expiration_epoch > now_epoch + 3600 )) || return 1

  expected_application_id="$profile_team_id.$installed_bundle_id"
  profile_entitlements="$work_dir/profile-entitlements-validation.plist"
  plutil -extract Entitlements xml1 -o "$profile_entitlements" "$profile_plist" 2>/dev/null || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$profile_entitlements" 2>/dev/null)" == "$expected_application_id" ]] || return 1
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$profile_entitlements" 2>/dev/null)" == "$profile_team_id" ]] || return 1
  has_device=0
  device_index=0
  while provisioned_device="$(plutil -extract "ProvisionedDevices.$device_index" raw -o - "$profile_plist" 2>/dev/null)"; do
    if [[ "$provisioned_device" == "$device_udid" ]]; then
      has_device=1
      break
    fi
    device_index=$((device_index + 1))
  done
  (( has_device == 1 )) || return 1
  return 0
}

profile_contains_certificate() {
  local expected_base64="$1" profile_base64 certificate_index
  certificate_index=0
  while profile_base64="$(plutil -extract "DeveloperCertificates.$certificate_index" raw -o - "$profile_plist" 2>/dev/null)"; do
    [[ "$profile_base64" == "$expected_base64" ]] && return 0
    certificate_index=$((certificate_index + 1))
  done
  return 1
}

latest_signed_seed_ipa() {
  local seed_row
  seed_row="$(find "$repo_root/build/sideloadly-cli" -maxdepth 1 -type f \
    -name '*-sideloadly-signed.ipa' -exec stat -f $'%m\t%N' {} + 2>/dev/null \
    | sort -rn | head -n 1)"
  [[ -n "$seed_row" ]] || return 1
  print -r -- "${seed_row#*$'\t'}"
}

cache_profile_from_seed() {
  local seed_ipa="$1" profile_entry profile_temp
  [[ -f "$seed_ipa" ]] || return 1
  unzip -tq "$seed_ipa" >/dev/null || return 1
  profile_entry="$(unzip -Z1 "$seed_ipa" \
    | grep -E '^Payload/[^/]+\.app/embedded\.mobileprovision$' \
    | head -n 1)"
  [[ -n "$profile_entry" ]] || return 1

  mkdir -p "$fast_ota_support_dir"
  profile_temp="$fast_ota_support_dir/.profile.mobileprovision.tmp.$$"
  unzip -p "$seed_ipa" "$profile_entry" > "$profile_temp"
  if ! profile_is_valid "$profile_temp"; then
    rm -f -- "$profile_temp"
    return 1
  fi
  mv -f -- "$profile_temp" "$profile_cache"
  chmod 600 "$profile_cache"
  note "profile: initialized the secure cache from a validated Sideloadly-signed build"
}

load_signing_profile() {
  local seed_candidate="${1:-}"
  if profile_is_valid "$profile_cache"; then
    note "profile: active through $profile_expiration"
    return 0
  fi
  if [[ -z "$seed_candidate" ]]; then
    seed_candidate="$(latest_signed_seed_ipa 2>/dev/null || true)"
  fi
  if [[ -n "$seed_candidate" ]] && cache_profile_from_seed "$seed_candidate" \
      && profile_is_valid "$profile_cache"; then
    note "profile: active through $profile_expiration"
    return 0
  fi
  fail "No current matching provisioning profile is cached. Run ./scripts/sideloadly-cli.sh update once to renew it"
}

locate_signing_material() {
  local key_path="$sideloadly_support_dir/key.pem" candidate certificate_base64
  local certificate_public_key private_public_key
  local -a candidates
  [[ -f "$key_path" ]] || fail "Sideloadly's local signing key is missing; renew once with sideloadly-cli.sh"
  candidates=("$sideloadly_support_dir"/cert-*.pem(N))
  (( ${#candidates[@]} > 0 )) || fail "Sideloadly's signing certificate is missing; renew once with sideloadly-cli.sh"

  signing_certificate=""
  for candidate in "${candidates[@]}"; do
    openssl x509 -in "$candidate" -noout >/dev/null 2>&1 || continue
    certificate_base64="$(openssl x509 -in "$candidate" -outform DER 2>/dev/null | base64 | tr -d '\r\n')"
    if profile_contains_certificate "$certificate_base64"; then
      signing_certificate="$candidate"
      break
    fi
  done
  [[ -n "$signing_certificate" ]] || fail \
    "The cached profile does not match Sideloadly's current certificate; renew once with sideloadly-cli.sh"

  certificate_public_key="$(openssl x509 -in "$signing_certificate" -pubkey -noout \
    | openssl pkey -pubin -outform DER 2>/dev/null \
    | openssl dgst -sha256 | awk '{print $2}')"
  private_public_key="$(openssl pkey -in "$key_path" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256 | awk '{print $2}')"
  [[ -n "$certificate_public_key" && "$certificate_public_key" == "$private_public_key" ]] || fail \
    "Sideloadly's certificate and private key no longer match"

  signing_fingerprint="$(openssl x509 -in "$signing_certificate" -noout -fingerprint -sha1 \
    | sed 's/^sha1 Fingerprint=//' | tr -d ':' | tr '[:lower:]' '[:upper:]')"
  [[ ${#signing_fingerprint} == 40 && "$signing_fingerprint" != *[^0-9A-F]* ]] || fail \
    "Could not identify Sideloadly's signing certificate"
  signing_key="$key_path"
}

ensure_issuer_certificate() {
  local leaf_issuer issuer_generation issuer_subject issuer_url issuer_temp
  leaf_issuer="$(openssl x509 -in "$signing_certificate" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=//')"
  issuer_generation="$(print -r -- "$leaf_issuer" | tr ',' '\n' | sed -n 's/^OU=//p' | head -n 1)"
  [[ -n "$issuer_generation" ]] || fail "Could not identify the Apple developer certificate issuer"
  print -r -- "$issuer_generation" | grep -Eq '^[A-Za-z0-9]+$' || fail "Unsupported issuer generation"

  mkdir -p "$fast_ota_support_dir"
  issuer_certificate="$fast_ota_support_dir/AppleWWDRCA${issuer_generation}.cer"
  if [[ -f "$issuer_certificate" ]]; then
    issuer_subject="$(openssl x509 -inform DER -in "$issuer_certificate" -noout -subject -nameopt RFC2253 2>/dev/null \
      | sed 's/^subject=//' || true)"
    [[ "$issuer_subject" == "$leaf_issuer" ]] && return 0
  fi

  issuer_url="https://www.apple.com/certificateauthority/AppleWWDRCA${issuer_generation}.cer"
  issuer_temp="$fast_ota_support_dir/.AppleWWDRCA${issuer_generation}.cer.tmp.$$"
  note "certificate: caching Apple's $issuer_generation signing intermediate"
  curl -fsSL "$issuer_url" -o "$issuer_temp" || fail "Could not download Apple's signing intermediate"
  issuer_subject="$(openssl x509 -inform DER -in "$issuer_temp" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed 's/^subject=//' || true)"
  [[ "$issuer_subject" == "$leaf_issuer" ]] || fail "Apple's downloaded signing intermediate did not match the certificate"
  mv -f -- "$issuer_temp" "$issuer_certificate"
  chmod 644 "$issuer_certificate"
}

create_signing_keychain() {
  local keychain_password p12_password p12_path identity_count
  ensure_work_dir
  read_keychain_search_list
  temporary_keychain="$work_dir/fast-signing.keychain-db"
  p12_path="$work_dir/signing.p12"
  keychain_password="$(openssl rand -hex 24)"
  p12_password="$(openssl rand -hex 24)"

  openssl pkcs12 -export -legacy \
    -in "$signing_certificate" \
    -inkey "$signing_key" \
    -certfile "$issuer_certificate" \
    -out "$p12_path" \
    -passout "pass:$p12_password" >/dev/null 2>&1
  security create-keychain -p "$keychain_password" "$temporary_keychain"
  security set-keychain-settings -lut 21600 "$temporary_keychain"
  security unlock-keychain -p "$keychain_password" "$temporary_keychain"
  security import "$p12_path" \
    -k "$temporary_keychain" \
    -P "$p12_password" \
    -T /usr/bin/codesign >/dev/null
  security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$keychain_password" \
    "$temporary_keychain" >/dev/null
  security list-keychains -d user -s "$temporary_keychain" "${original_keychains[@]}"
  search_list_changed=1

  identity_count="$(security find-identity -v -p codesigning \
    | awk -v fingerprint="$signing_fingerprint" '$2 == fingerprint { count++ } END { print count + 0 }')"
  [[ "$identity_count" == "1" ]] || fail "The temporary Apple signing identity did not validate"
  note "signing: isolated Apple identity is ready"
}

inspect_source_artifacts() {
  local ipa_path="$1" info_entry info_count unpacked_app_count
  local local_watch_config shipped_convex_url shipped_livekit_url
  [[ -f "$ipa_path" ]] || fail "IPA not found: $ipa_path"
  unzip -tq "$ipa_path" >/dev/null || fail "IPA archive validation failed"
  ensure_work_dir
  unzip -Z1 "$ipa_path" > "$work_dir/ipa-entries.txt"
  info_count="$(grep -Ec '^Payload/[^/]+\.app/Info\.plist$' "$work_dir/ipa-entries.txt" || true)"
  [[ "$info_count" == "1" ]] || fail "Expected exactly one application in the IPA"
  info_entry="$(grep -E '^Payload/[^/]+\.app/Info\.plist$' "$work_dir/ipa-entries.txt")"
  unzip -p "$ipa_path" "$info_entry" > "$work_dir/ipa-Info.plist"
  ipa_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$work_dir/ipa-Info.plist")"
  ipa_version="$(plutil -extract CFBundleShortVersionString raw -o - "$work_dir/ipa-Info.plist")"
  ipa_build="$(plutil -extract CFBundleVersion raw -o - "$work_dir/ipa-Info.plist")"
  ipa_name="$(plutil -extract CFBundleName raw -o - "$work_dir/ipa-Info.plist")"
  [[ "$ipa_bundle_id" == "$source_bundle_id" ]] || fail \
    "IPA bundle ID is $ipa_bundle_id; expected $source_bundle_id"

  # WatchTogether.local.xcconfig is intentionally ignored because it is a
  # machine-local endpoint snapshot. Clean build copies must carry that file.
  # Refuse an OTA when this checkout is configured but the supplied IPA lost
  # those values, rather than shipping a Create profile button that can only
  # return early as unconfigured.
  local_watch_config="$repo_root/config/WatchTogether.local.xcconfig"
  if [[ -f "$local_watch_config" ]] \
      && grep -Eq '^[[:space:]]*WATCH_TOGETHER_CONVEX_URL[[:space:]]*=[[:space:]]*https:' \
        "$local_watch_config"; then
    shipped_convex_url="$(plutil -extract WatchTogetherConvexURL raw -o - \
      "$work_dir/ipa-Info.plist" 2>/dev/null || true)"
    [[ "$shipped_convex_url" == https://* ]] || fail \
      "This checkout configures Watch Together, but the IPA is missing its Convex endpoint"

    if grep -Eq '^[[:space:]]*WATCH_TOGETHER_LIVEKIT_URL[[:space:]]*=[[:space:]]*wss:' \
        "$local_watch_config"; then
      shipped_livekit_url="$(plutil -extract WatchTogetherLiveKitURL raw -o - \
        "$work_dir/ipa-Info.plist" 2>/dev/null || true)"
      [[ "$shipped_livekit_url" == wss://* ]] || fail \
        "This checkout configures LiveKit, but the IPA is missing its LiveKit endpoint"
    fi
    note "artifact: Watch Together endpoints are present"
  fi

  # The requested IPA is the release artifact and must also be the exact source
  # that is re-signed. Bundle/version/build metadata is not a content identity:
  # a cached build can legitimately have the same metadata but different code.
  mkdir -p "$work_dir/source"
  ditto -x -k "$ipa_path" "$work_dir/source"
  unpacked_app_count="$(find "$work_dir/source/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' \
    | wc -l | tr -d ' ')"
  [[ "$unpacked_app_count" == "1" ]] || fail "Could not extract exactly one source application"
  source_app="$(find "$work_dir/source/Payload" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print -quit)"

  ipa_absolute_path="${ipa_path:A}"
  ipa_size="$(stat -f '%z' "$ipa_absolute_path")"
  ipa_md5="$(md5 -q "$ipa_absolute_path" | tr '[:upper:]' '[:lower:]')"
  note "artifact: $ipa_name $ipa_version ($ipa_build), $ipa_size bytes"
}

sign_application() {
  local staged_root entitlements_path signed_entitlements nested_app_count code_object signing_log
  local signed_application_id signed_team_id
  local signed_code_objects
  staged_root="$work_dir/staged"
  signed_app="$staged_root/StremioSkeleton.app"
  entitlements_path="$work_dir/signing-entitlements.plist"
  signed_entitlements="$work_dir/signed-entitlements.plist"
  signing_log="$work_dir/codesign.log"
  signed_code_objects=0
  mkdir -p "$staged_root"
  ditto "$source_app" "$signed_app"
  xattr -cr "$signed_app"

  nested_app_count="$(find "$signed_app" -mindepth 1 -type d \( -name '*.app' -o -name '*.appex' \) \
    | wc -l | tr -d ' ')"
  [[ "$nested_app_count" == "0" ]] || fail \
    "Nested app extensions require individual profiles; use sideloadly-cli.sh for this build"

  plutil -replace CFBundleIdentifier -string "$installed_bundle_id" "$signed_app/Info.plist"
  if ! plutil -replace ALTBundleIdentifier -string "$source_bundle_id" "$signed_app/Info.plist" 2>/dev/null; then
    plutil -insert ALTBundleIdentifier -string "$source_bundle_id" "$signed_app/Info.plist"
  fi
  ditto "$profile_cache" "$signed_app/embedded.mobileprovision"
  plutil -extract Entitlements xml1 -o "$entitlements_path" "$profile_plist"

  while IFS= read -r code_object; do
    [[ -n "$code_object" ]] || continue
    if ! codesign --force --timestamp=none \
      --keychain "$temporary_keychain" \
      --sign "$signing_fingerprint" \
      "$code_object" >> "$signing_log" 2>&1; then
      tail -n 40 "$signing_log" >&2
      fail "Could not sign nested dynamic library"
    fi
    signed_code_objects=$((signed_code_objects + 1))
  done < <(find "$signed_app" -depth -type f -name '*.dylib' -print)

  while IFS= read -r code_object; do
    [[ -n "$code_object" ]] || continue
    if ! codesign --force --timestamp=none \
      --keychain "$temporary_keychain" \
      --sign "$signing_fingerprint" \
      "$code_object" >> "$signing_log" 2>&1; then
      tail -n 40 "$signing_log" >&2
      fail "Could not sign nested framework"
    fi
    signed_code_objects=$((signed_code_objects + 1))
  done < <(find "$signed_app" -depth -type d \( -name '*.framework' -o -name '*.xpc' \) -print)

  if ! codesign --force --timestamp=none \
    --keychain "$temporary_keychain" \
    --sign "$signing_fingerprint" \
    --entitlements "$entitlements_path" \
    "$signed_app" >> "$signing_log" 2>&1; then
    tail -n 40 "$signing_log" >&2
    fail "Could not sign the application bundle"
  fi
  if ! codesign --verify --deep --strict --verbose=2 "$signed_app" >> "$signing_log" 2>&1; then
    tail -n 40 "$signing_log" >&2
    fail "The locally signed application failed verification"
  fi
  codesign --display --entitlements :- "$signed_app" > "$signed_entitlements" 2>/dev/null
  signed_application_id="$(plutil -extract application-identifier raw -o - "$signed_entitlements")"
  signed_team_id="$(codesign --display --verbose=4 "$signed_app" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  [[ "$signed_application_id" == "$profile_team_id.$installed_bundle_id" ]] || fail \
    "The signed application identifier does not match the profile"
  [[ "$signed_team_id" == "$profile_team_id" ]] || fail "The signed team identifier does not match the profile"
  note "signing: app and $signed_code_objects nested code objects verified"
  return 0
}

install_application() {
  local install_json="$1" install_log
  install_log="$work_dir/install.log"
  if ! xcrun devicectl device install app \
      --device "$core_device_identifier" \
      --timeout 120 \
      --quiet \
      --json-output "$install_json" \
      "$signed_app" >/dev/null 2>"$install_log"; then
    tail -n 30 "$install_log" >&2
    fail "CoreDevice could not install the signed app. Wake and unlock $device_name, then retry with --skip-build"
  fi
  [[ "$(jq -r '.error // empty' "$install_json")" == "" ]] || fail "CoreDevice reported an install error"
  note "install: CoreDevice accepted the signed app"
}

verify_and_launch() {
  local launch_after_install="$1" apps_json launch_json launch_log
  apps_json="$work_dir/apps-after.json"
  xcrun devicectl device info apps \
    --device "$core_device_identifier" \
    --bundle-id "$installed_bundle_id" \
    --timeout 60 \
    --quiet \
    --json-output "$apps_json" >/dev/null
  installed_version="$(jq -er '.result.apps[0].version' "$apps_json")"
  installed_build="$(jq -er '.result.apps[0].bundleVersion' "$apps_json")"
  [[ "$installed_version" == "$ipa_version" ]] || fail \
    "Device reports version $installed_version; expected $ipa_version"
  [[ "$installed_build" == "$ipa_build" ]] || fail \
    "Device reports build $installed_build; expected $ipa_build"

  launched=0
  launch_status="not-requested"
  if (( launch_after_install == 1 )); then
    launch_json="$work_dir/launch.json"
    launch_log="$work_dir/launch.log"
    if xcrun devicectl device process launch \
        --device "$core_device_identifier" \
        --terminate-existing \
        --activate \
        --timeout 60 \
        --quiet \
        --json-output "$launch_json" \
        "$installed_bundle_id" >/dev/null 2>"$launch_log" \
        && [[ "$(jq -r '.error // empty' "$launch_json" 2>/dev/null)" == "" ]]; then
      launched=1
      launch_status="launched"
      note "launch: $ipa_name $ipa_version ($ipa_build) opened on $device_name"
    elif grep -Eqi 'reason: Locked|device was not, or could not be, unlocked|BSErrorCodeDescription = Locked' \
        "$launch_log" "$launch_json" 2>/dev/null; then
      launch_status="device-locked"
      note "launch: skipped because $device_name locked after installation"
    else
      tail -n 30 "$launch_log" >&2
      fail "The update installed and verified, but CoreDevice could not launch it"
    fi
  fi
  note "verified: $installed_bundle_id is build $installed_build on $device_name"
}

write_receipt() {
  local receipt_path="$1" captured_at="$2" auto_refresh_staged="$3"
  local receipt_temp="$work_dir/receipt.json"
  jq -n \
    --arg capturedAt "$captured_at" \
    --arg device "$device_name" \
    --arg deviceUDID "$device_udid" \
    --arg transport "$device_transport" \
    --arg method "local-codesign+coredevice" \
    --arg sourceIPA "$ipa_absolute_path" \
    --arg sourceMD5 "$ipa_md5" \
    --arg version "$ipa_version" \
    --arg build "$ipa_build" \
    --arg installedBundleID "$installed_bundle_id" \
    --arg profileExpiration "$profile_expiration" \
    --arg launchStatus "$launch_status" \
    --argjson sourceBytes "$ipa_size" \
    --argjson launched "$launched" \
    --argjson autoRefreshStaged "$auto_refresh_staged" \
    --argjson preflight "$preflight_seconds" \
    --argjson buildSeconds "$build_seconds" \
    --argjson signing "$signing_seconds" \
    --argjson install "$install_seconds" \
    --argjson verify "$verify_seconds" \
    --argjson autoRefresh "$stage_seconds" \
    --argjson total "$total_seconds" \
    '{
      schemaVersion: 1,
      capturedAt: $capturedAt,
      status: "complete",
      method: $method,
      device: $device,
      deviceUDID: $deviceUDID,
      transport: $transport,
      installedBundleID: $installedBundleID,
      version: $version,
      build: $build,
      launched: ($launched == 1),
      launchStatus: $launchStatus,
      sourceIPA: $sourceIPA,
      sourceBytes: $sourceBytes,
      sourceMD5: $sourceMD5,
      profileExpiration: $profileExpiration,
      autoRefreshStaged: ($autoRefreshStaged == 1),
      timingsSeconds: {
        preflight: $preflight,
        build: $buildSeconds,
        localSigning: $signing,
        coreDeviceInstall: $install,
        verifyAndLaunch: $verify,
        autoRefreshStage: $autoRefresh,
        total: $total
      }
    }' > "$receipt_temp"
  mkdir -p "${receipt_path:h}"
  mv -f -- "$receipt_temp" "$receipt_path"
  cp "$receipt_path" "${receipt_path:h}/latest.json"
  note "receipt: $receipt_path"
}

for dependency in jq plutil openssl security codesign xcrun ditto unzip curl md5 stat xattr find grep awk sed sort; do
  require_command "$dependency"
done
load_snapshot

command_name="${1:-help}"
if (( $# > 0 )); then shift; fi
seed_ipa=""

case "$command_name" in
  help|-h|--help)
    usage
    ;;
  doctor)
    while (( $# > 0 )); do
      case "$1" in
        --seed-ipa)
          (( $# >= 2 )) || fail "--seed-ipa requires a path"
          seed_ipa="$2"
          shift 2
          ;;
        *)
          fail "Unknown doctor option: $1"
          ;;
      esac
    done
    ensure_work_dir
    preflight_device "$work_dir/device.json"
    load_signing_profile "$seed_ipa"
    locate_signing_material
    ensure_issuer_certificate
    create_signing_keychain
    cleanup_signing_keychain
    note "doctor: direct signing and CoreDevice OTA are ready"
    ;;
  update)
    ipa_path="$default_ipa"
    skip_build=0
    dry_run=0
    launch_after_install=1
    stage_auto_refresh=1
    while (( $# > 0 )); do
      case "$1" in
        --ipa)
          (( $# >= 2 )) || fail "--ipa requires a path"
          ipa_path="$2"
          shift 2
          ;;
        --seed-ipa)
          (( $# >= 2 )) || fail "--seed-ipa requires a path"
          seed_ipa="$2"
          shift 2
          ;;
        --skip-build)
          skip_build=1
          shift
          ;;
        --dry-run)
          dry_run=1
          skip_build=1
          shift
          ;;
        --no-launch)
          launch_after_install=0
          shift
          ;;
        --no-stage)
          stage_auto_refresh=0
          shift
          ;;
        *)
          fail "Unknown update option: $1"
          ;;
      esac
    done

    ensure_work_dir
    run_started=$SECONDS
    phase_started=$SECONDS
    preflight_device "$work_dir/device.json"
    load_signing_profile "$seed_ipa"
    locate_signing_material
    ensure_issuer_certificate
    create_signing_keychain
    preflight_seconds=$((SECONDS - phase_started))

    phase_started=$SECONDS
    if (( skip_build == 0 )); then
      note "build: creating the current unsigned device app and handoff IPA"
      SKELETON_SKIP_DEVICE_ZIP=1 "$repo_root/scripts/build-device.sh"
    fi
    build_seconds=$((SECONDS - phase_started))
    inspect_source_artifacts "$ipa_path"

    if (( dry_run == 1 )); then
      cleanup_signing_keychain
      note "dry-run: device, profile, signing identity, app, and IPA are valid"
      exit 0
    fi

    phase_started=$SECONDS
    sign_application
    cleanup_signing_keychain
    signing_seconds=$((SECONDS - phase_started))
    note "signing: temporary identity released in ${signing_seconds}s"

    phase_started=$SECONDS
    note "install: sending the signed app over CoreDevice"
    install_application "$work_dir/install.json"
    install_seconds=$((SECONDS - phase_started))

    phase_started=$SECONDS
    verify_and_launch "$launch_after_install"
    verify_seconds=$((SECONDS - phase_started))

    phase_started=$SECONDS
    auto_refresh_staged=0
    if (( stage_auto_refresh == 1 )); then
      note "AutoRefresh: staging the verified source IPA without another install"
      if ! "$repo_root/scripts/sideloadly-cli.sh" stage --ipa "$ipa_absolute_path"; then
        fail "build $ipa_build installed and verified, but required Sideloadly AutoRefresh staging failed; rerun with --skip-build after fixing Sideloadly, or explicitly use --no-stage"
      fi
      auto_refresh_staged=1
    fi
    stage_seconds=$((SECONDS - phase_started))
    total_seconds=$((SECONDS - run_started))

    captured_at="$(date -u '+%Y%m%dT%H%M%SZ')"
    receipt_path="$repo_root/build/fast-ota/$captured_at.json"
    write_receipt "$receipt_path" "$captured_at" "$auto_refresh_staged"
    note "complete: build $ipa_build installed in ${total_seconds}s (${build_seconds}s build, ${signing_seconds}s sign, ${install_seconds}s install)"
    ;;
  *)
    usage >&2
    fail "Unknown command: $command_name"
    ;;
esac
