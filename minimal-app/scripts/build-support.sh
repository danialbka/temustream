#!/bin/sh

# Shared, dependency-free helpers for build scripts. This file is sourced; it
# deliberately does not change the caller's shell options or traps.

stremio_acquire_lock() {
  lock_dir="$1"
  lock_label="$2"
  lock_timeout="${3:-300}"
  lock_started="$(date +%s)"

  mkdir -p "$(dirname "$lock_dir")"
  while ! mkdir "$lock_dir" 2>/dev/null; do
    lock_owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
    case "$lock_owner" in
      ''|*[!0-9]*) ;;
      *)
        if ! kill -0 "$lock_owner" 2>/dev/null; then
          rm -f "$lock_dir/pid" 2>/dev/null || true
          rmdir "$lock_dir" 2>/dev/null || true
          continue
        fi
        ;;
    esac

    lock_now="$(date +%s)"
    if [ $((lock_now - lock_started)) -ge "$lock_timeout" ]; then
      echo "Timed out waiting for $lock_label (owner pid ${lock_owner:-unknown})" >&2
      return 1
    fi
    sleep 1
  done

  printf '%s\n' "$$" > "$lock_dir/pid"
  STREMIO_HELD_LOCK="$lock_dir"
  export STREMIO_HELD_LOCK
}

stremio_release_lock() {
  lock_dir="${1:-${STREMIO_HELD_LOCK:-}}"
  [ -n "$lock_dir" ] || return 0
  lock_owner="$(cat "$lock_dir/pid" 2>/dev/null || true)"
  if [ -z "$lock_owner" ] || [ "$lock_owner" = "$$" ]; then
    rm -f "$lock_dir/pid" 2>/dev/null || true
    rmdir "$lock_dir" 2>/dev/null || true
  fi
  if [ "${STREMIO_HELD_LOCK:-}" = "$lock_dir" ]; then
    STREMIO_HELD_LOCK=""
    export STREMIO_HELD_LOCK
  fi
}

stremio_run_bounded() {
  stremio_timeout="$1"
  stremio_label="$2"
  shift 2

  if /usr/bin/perl -e '
    use POSIX qw(:sys_wait_h);
    my $seconds = shift @ARGV;
    my $pid = fork();
    exit 127 unless defined $pid;
    if ($pid == 0) {
      exec @ARGV;
      exit 127;
    }
    my $timed_out = 0;
    $SIG{ALRM} = sub {
      $timed_out = 1;
      kill "TERM", $pid;
      select undef, undef, undef, 0.5;
      kill "KILL", $pid;
    };
    alarm $seconds;
    while (waitpid($pid, 0) == -1) {
      next if $!{EINTR};
      exit 127;
    }
    alarm 0;
    exit 124 if $timed_out;
    exit WEXITSTATUS($?) if WIFEXITED($?);
    exit 128 + WTERMSIG($?) if WIFSIGNALED($?);
    exit 127;
  ' "$stremio_timeout" "$@"; then
    return 0
  else
    stremio_result=$?
    if [ "$stremio_result" -eq 124 ]; then
      echo "Timed out after ${stremio_timeout}s: $stremio_label" >&2
    fi
    return "$stremio_result"
  fi
}

stremio_register_build_cache() {
  cache_tool="$1"
  cache_kind="$2"
  cache_directory="$3"
  "$cache_tool" register \
    --kind "$cache_kind" \
    --path "$cache_directory" \
    --pid "$$" >/dev/null
}

stremio_release_build_cache() {
  cache_tool="$1"
  cache_directory="$2"
  "$cache_tool" release --path "$cache_directory" --pid "$$" \
    >/dev/null 2>&1 || true
}

stremio_prune_build_caches() {
  cache_tool="$1"
  shift
  "$cache_tool" prune --apply --quiet "$@"
}
