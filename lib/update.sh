# update.sh - version, self-update of a managed install, throttled background check.
#
# A managed install is a clone made by install.sh; it carries a marker file in
# its git dir holding the update channel. A developer checkout has no marker
# and is never moved: update tells you to git pull instead.
#
# Channels: "stable" follows the newest v* tag, "main" follows origin/main.
# Updates only ever fast-forward (the target must descend from HEAD), so an
# install never downgrades and never jumps to an unrelated history.
#
# Replacing the scripts under a running bash is safe: git unlinks and recreates
# each file, and a running process keeps reading the inode it opened.

AGENTWS_HOME_DIR="$(cd "$AGENTWS_BIN_DIR/.." && pwd -P)"
AGENTWS_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/agentws"

agentws_version() {
  local v rev
  v="$(cat "$AGENTWS_HOME_DIR/VERSION" 2>/dev/null || echo unknown)"
  rev="$(git -C "$AGENTWS_HOME_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  printf '%s%s' "$v" "${rev:+ ($rev)}"
}

cmd_version() {
  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"version":%s,"home":%s,"managed":%s,"channel":%s}' \
      "$(jstr "$(cat "$AGENTWS_HOME_DIR/VERSION" 2>/dev/null)")" "$(jstr "$AGENTWS_HOME_DIR")" \
      "$(jbool "$(update_managed && echo 1)")" "$(jstr "$(update_channel)")"
  else
    printf 'agentws %s\n' "$(agentws_version)"
  fi
}

update_marker() {
  local gd
  gd="$(git -C "$AGENTWS_HOME_DIR" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf '%s/agentws-managed' "$gd"
}

update_managed() { local m; m="$(update_marker)" && [ -f "$m" ]; }

update_channel() {
  local c="${AGENTWS_UPDATE_CHANNEL:-}" m
  if [ -z "$c" ] && m="$(update_marker)" && [ -f "$m" ]; then
    c="$(sed -n 's/^channel=//p' "$m" | head -1)"
  fi
  printf '%s' "${c:-stable}"
}

# Newest commit the channel points at, after a fetch. Empty when the stable
# channel has no release yet.
update_target() { # update_target <channel>
  local h="$AGENTWS_HOME_DIR" tag
  case "$1" in
    main) git -C "$h" rev-parse --verify --quiet origin/main ;;
    stable)
      tag="$(git -C "$h" tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
      [ -n "$tag" ] && git -C "$h" rev-parse --verify --quiet "$tag^{commit}" ;;
    *) return 1 ;;
  esac
}

# update [--check]. With AUTO=1 (background run) it stays quiet on no-ops.
cmd_update() {
  local h="$AGENTWS_HOME_DIR" ch target head lockd rc=0 check=0 a
  for a in "$@"; do
    case "$a" in
      --check) check=1 ;;
      *) printf 'update: unknown argument %s\n' "$a" >&2; return 2 ;;
    esac
  done
  ch="$(update_channel)"
  if ! update_managed; then
    printf '%s is a development checkout, not an install; update it with git pull\n' "$h" >&2
    [ "${JSON:-0}" -eq 1 ] && printf '{"updated":false,"reason":"unmanaged","home":%s}' "$(jstr "$h")"
    return 0
  fi
  case "$ch" in stable|main) ;; *) printf 'unknown update channel %s (stable or main)\n' "$ch" >&2; return 2 ;; esac
  if [ -n "$(git -C "$h" status --porcelain 2>/dev/null)" ]; then
    printf '%s has local changes; refusing to update\n' "$h" >&2
    return 1
  fi

  mkdir -p "$AGENTWS_STATE_DIR"
  lockd="$AGENTWS_STATE_DIR/update.lock"
  # A lock left by a killed update is ignored after an hour.
  if [ -d "$lockd" ] && [ -n "$(find "$lockd" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then
    rmdir "$lockd" 2>/dev/null || true
  fi
  mkdir "$lockd" 2>/dev/null || { printf 'another update is running\n' >&2; return 0; }

  GIT_TERMINAL_PROMPT=0 git -C "$h" fetch --quiet --tags --prune origin >&2 || rc=$?
  if [ $rc -ne 0 ]; then
    rmdir "$lockd"
    printf 'update: git fetch failed (rc %s)\n' "$rc" >&2
    return 1
  fi
  : > "$AGENTWS_STATE_DIR/last-check"
  head="$(git -C "$h" rev-parse HEAD)"
  target="$(update_target "$ch" || true)"

  if [ -z "$target" ] || [ "$target" = "$head" ] \
     || ! git -C "$h" merge-base --is-ancestor "$head" "$target" 2>/dev/null; then
    rmdir "$lockd"
    [ "${AUTO:-0}" -eq 1 ] || printf 'agentws %s is up to date (channel %s)\n' "$(agentws_version)" "$ch" >&2
    [ "${JSON:-0}" -eq 1 ] && printf '{"updated":false,"version":%s,"channel":%s}' \
      "$(jstr "$(cat "$h/VERSION" 2>/dev/null)")" "$(jstr "$ch")"
    return 0
  fi

  if [ "$check" -eq 1 ]; then
    rmdir "$lockd"
    printf 'update available: %s -> %s (run: agentws update)\n' \
      "$(git -C "$h" rev-parse --short HEAD)" "$(git -C "$h" describe --tags --always "$target" 2>/dev/null)" >&2
    [ "${JSON:-0}" -eq 1 ] && printf '{"updated":false,"available":true,"channel":%s}' "$(jstr "$ch")"
    return 0
  fi

  local from; from="$(agentws_version)"
  git -C "$h" -c advice.detachedHead=false checkout --quiet --detach "$target" >&2 || rc=$?
  rmdir "$lockd"
  [ $rc -eq 0 ] || { printf 'update: checkout of %s failed\n' "$target" >&2; return 1; }

  # Re-apply harness wiring with the new code, only where it is already set up.
  "$h/bin/agentws" setup --refresh >&2 || true
  printf 'agentws updated: %s -> %s\n' "$from" "$(agentws_version)" >&2
  [ "${JSON:-0}" -eq 1 ] && printf '{"updated":true,"version":%s,"channel":%s}' \
    "$(jstr "$(cat "$h/VERSION" 2>/dev/null)")" "$(jstr "$ch")"
  return 0
}

# Spawn a detached update when the last check is older than the interval.
# Every fd is redirected so a caller reading our stdout through a pipe never
# waits on the background child.
update_maybe_background() {
  case "${AGENTWS_NO_AUTO_UPDATE:-0}" in 1|true|yes) return 0 ;; esac
  local stamp="$AGENTWS_STATE_DIR/last-check" hours="${AGENTWS_UPDATE_INTERVAL_HOURS:-24}"
  case "$hours" in ''|*[!0-9]*) hours=24 ;; esac
  # Cheapest test first: this runs on every command.
  if [ -f "$stamp" ] && [ -z "$(find "$stamp" -mmin +"$((hours * 60))" 2>/dev/null)" ]; then
    return 0
  fi
  update_managed || return 0
  mkdir -p "$AGENTWS_STATE_DIR" 2>/dev/null || return 0
  : > "$stamp"
  ( AUTO=1 nohup "$AGENTWS_HOME_DIR/bin/agentws" update \
      >"$AGENTWS_STATE_DIR/update.log" 2>&1 </dev/null & ) >/dev/null 2>&1
  return 0
}
