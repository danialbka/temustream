#!/bin/zsh
set -euo pipefail

repo_root="${0:A:h:h}"
backend_env="$repo_root/Backend/watch-together/.env.local"
local_config="$repo_root/config/WatchTogether.local.xcconfig"

convex_url="${WATCH_TOGETHER_CONVEX_URL:-}"
if [[ -z "$convex_url" && -f "$backend_env" ]]; then
  convex_url="$(sed -n 's/^CONVEX_URL=//p' "$backend_env" | tail -1)"
fi
livekit_url="${WATCH_TOGETHER_LIVEKIT_URL:-${LIVEKIT_URL:-}}"

if [[ -z "$convex_url" ]]; then
  print -u2 "Missing WATCH_TOGETHER_CONVEX_URL and no Backend/watch-together/.env.local was found."
  exit 1
fi

escape_xcconfig_url() {
  print -r -- "$1" | sed 's#://#:/$()/#'
}

tmp_config="$(mktemp "$repo_root/config/.WatchTogether.local.XXXXXX")"
{
  print -r -- "// Generated locally; contains endpoints only, never server credentials."
  print -r -- "WATCH_TOGETHER_CONVEX_URL = $(escape_xcconfig_url "$convex_url")"
  print -r -- "WATCH_TOGETHER_LIVEKIT_URL = $(escape_xcconfig_url "$livekit_url")"
} > "$tmp_config"
mv "$tmp_config" "$local_config"
print "Configured Watch Together endpoints in $local_config"
