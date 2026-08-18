# helper.bash - sandbox construction shared by every test file.
#
# Nothing here touches a real workspace, a real lock dir, or the real /proc.
# Liveness is driven entirely through the AGENTWS_PROC seam, so the 6-case
# matrix is deterministic and runs identically on Linux and macOS.

AGENTWS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AGENTWS_REPO_ROOT="$(cd "$AGENTWS_TEST_DIR/.." && pwd -P)"
AGENTWS_BIN="$AGENTWS_REPO_ROOT/bin/agentws"

# bats runs each test in its own process; SANDBOX is per-test.
setup_sandbox() { # setup_sandbox [slots...]
  local slots="${*:-1 2 3}" s

  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-test.XXXXXX")"
  ROOT="$SANDBOX/ws"
  LOCKS="$SANDBOX/locks"
  PROC="$SANDBOX/proc"
  mkdir -p "$ROOT" "$LOCKS" "$PROC"

  for s in $slots; do
    make_slot_repo "$s"
  done

  CONFIG="$SANDBOX/.agentws.yml"
  {
    printf 'version: 1\n'
    printf 'root: %s\n' "$ROOT"
    printf 'top: proj\n'
    printf 'provider: worktree\n'
    printf 'default_branch: main\n'
    printf 'slots: [%s]\n' "$(printf '%s' "$slots" | tr ' ' ',')"
    printf 'slot_name_format: "{slot}_{top}"\n'
    printf 'ttl_hours: 12\n'
    printf 'lock_dir: %s\n' "$LOCKS"
  } > "$CONFIG"

  export AGENTWS_CONFIG="$CONFIG"
  export AGENTWS_PROC="$PROC"
  export AGENTWS_OWNER="tester"
  unset AGENTWS_PID WSCTL_PID WSCTL_OWNER AGENTWS_TTL WSCTL_TTL

  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"
}

teardown_sandbox() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
  return 0
}

make_slot_repo() { # make_slot_repo <slot>
  local d="$ROOT/${1}_proj"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" symbolic-ref HEAD refs/heads/main
  git -C "$d" config user.email t@example.invalid
  git -C "$d" config user.name tester
  : > "$d/README"
  git -C "$d" add README
  git -C "$d" commit -q -m init
}

agentws() { "$AGENTWS_BIN" "$@"; }

lock_path() { printf '%s/%s.lock' "$LOCKS" "$1"; }

# A fake /proc entry. Field 22 of stat is the process start time; everything
# else is filler that the ladder never reads.
mkproc() { # mkproc <pid> <starttime>
  local p="$PROC/$1" i line=""
  mkdir -p "$p"
  for i in $(seq 1 30); do
    if [ "$i" -eq 22 ]; then line="${line}${2} "; else line="${line}0 "; fi
  done
  printf '%s\n' "$line" > "$p/stat"
}

rmproc() { rm -rf "${PROC:?}/$1"; }

# Write a lock file field by field. Callers pass "key=value" pairs so a test
# can express exactly the on-disk state the ladder must judge.
write_lock() { # write_lock <slot> <key=value>...
  local slot="$1"; shift
  local f kv
  f="$(lock_path "$slot")"
  mkdir -p "$LOCKS"
  : > "$f"
  for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done
}

# Default: a same-host lock held by "other", taken now. Any key passed as an
# override replaces the default rather than being appended, because lock_read
# takes the FIRST match and a duplicated key would silently win.
write_lock_default() { # write_lock_default <slot> [extra key=value...]
  local slot="$1"; shift
  local d kv k out=() keep
  for d in "owner=other" "reason=testing" "epoch=$(date +%s)" \
           "stamp=$(date '+%Y-%m-%d %H:%M:%S')" "host=$HOSTNAME_SHORT" "pid=99999"; do
    keep=1
    for kv in "$@"; do
      k="${kv%%=*}"
      [ "$k" = "${d%%=*}" ] && keep=0
    done
    [ "$keep" -eq 1 ] && out+=("$d")
  done
  write_lock "$slot" "${out[@]+"${out[@]}"}" "$@"
}

set_lock_age_hours() { # set_lock_age_hours <slot> <hours>
  local f e
  f="$(lock_path "$1")"
  e=$(( $(date +%s) - $2 * 3600 ))
  sed -e "s/^epoch=.*/epoch=$e/" "$f" > "$f.new" && mv "$f.new" "$f"
}

# The verdict the whole design rests on: alive or dead, read back out of the
# machine-readable surface rather than out of prose.
lock_verdict() { # lock_verdict <slot> [extra agentws flags...] -> alive|dead
  local slot="$1"; shift
  local out sr
  out="$(agentws locks --json "$@" 2>/dev/null)"
  sr="$(printf '%s' "$out" | jq -r --arg s "$slot" \
    '.data.locks[] | select(.slot==$s) | if .stale then .stale_reason else "" end')"
  if [ -z "$sr" ] || [ "$sr" = "null" ]; then printf 'alive'; else printf 'dead'; fi
}

lock_reason() { # lock_reason <slot> [extra flags...] -> "" | process_dead | ttl
  local slot="$1"; shift
  agentws locks --json "$@" 2>/dev/null | jq -r --arg s "$slot" \
    '.data.locks[] | select(.slot==$s) | if .stale then .stale_reason else "" end'
}
