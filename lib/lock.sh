# lock.sh - THE LOCK LADDER. Ported semantically verbatim from wsctl:166-399.
#
# Do not "improve" the liveness ladder. Exit 0 = alive OR unknowable. Exit 1 =
# definitively dead. A false "dead" verdict puts two agents in one workspace,
# which is the exact failure this tool exists to prevent.
#
# Locks live in a central registry outside the workspaces, so that cleaning a
# workspace cannot destroy them. Format: one file per slot, KEY=VALUE lines,
# byte-compatible with wsctl so both tools can share a lock dir.

# Test seam: point at a fake proc tree in tests. Never set in production.
AGENTWS_PROC="${AGENTWS_PROC:-/proc}"

lock_file() { printf '%s/%s.lock' "$AGENTWS_LOCK_DIR" "$1"; }

lock_read() { # lock_read <slot> <key> -> value on stdout
  local f; f="$(lock_file "$1")"
  [ -f "$f" ] || return 1
  sed -n "s/^$2=//p" "$f" | head -1
}

lock_age_hours() { # lock_age_hours <slot> -> integer hours, or empty
  local f ts now; f="$(lock_file "$1")"
  [ -f "$f" ] || return 1
  ts="$(lock_read "$1" epoch 2>/dev/null)"
  [ -n "$ts" ] || return 1
  now="$(date +%s)"
  printf '%d' $(( (now - ts) / 3600 ))
}

# Effective TTL, floored at 1 hour. A TTL of 0 would make every lock stale the
# instant it is written, overriding a positive liveness verdict and handing a
# running agent's workspace to a second one. Reachable via --ttl 0, AGENTWS_TTL=0
# and ttl_hours: 0, none of which require --force.
lock_ttl_hours() {
  case "${AGENTWS_TTL_HOURS:-}" in
    ''|*[!0-9]*) printf '12'; return 0 ;;
  esac
  if [ "$AGENTWS_TTL_HOURS" -lt 1 ]; then printf '1'; else printf '%s' "$AGENTWS_TTL_HOURS"; fi
}

# Strip anything that could forge a KEY=VALUE record in the lock file. lock_read
# takes the first match, so an injected line ahead of the real one wins.
lock_sanitize() { printf '%s' "$1" | tr '\n\r' '  '; }

# True when this platform can answer the liveness question at all.
lock_liveness_supported() { [ -d "$AGENTWS_PROC" ]; }

# Is the process that took the lock still running?
#
# Exit 0 = alive, OR we cannot tell (conservative: keep the lock).
# Exit 1 = definitively dead.
#
# Every uncertain case - lock taken on another host, no pid recorded, no /proc,
# unreadable /proc - returns "alive".
lock_owner_alive() { # lock_owner_alive <slot>
  [ "${IGNORE_PID:-0}" -eq 1 ] && return 0

  local h p st cur me
  h="$(lock_read "$1" host        2>/dev/null || true)"
  p="$(lock_read "$1" owner_pid   2>/dev/null || true)"
  st="$(lock_read "$1" owner_start 2>/dev/null || true)"

  # Different host (or host not recorded): the pid refers to another machine's
  # process table and means nothing here. Cannot verify.
  me="$(hostname -s 2>/dev/null || true)"
  [ -n "$h" ] && [ -n "$me" ] && [ "$h" = "$me" ] || return 0

  # No owner_pid recorded. The plain pid= field is deliberately NOT used here -
  # it is the agentws process itself, which has already exited, and testing it
  # would mark every lock dead.
  [ -n "$p" ] && [[ "$p" =~ ^[0-9]+$ ]] || return 0

  # No /proc to consult. Cannot verify.
  [ -d "$AGENTWS_PROC" ] || return 0

  # Same host, /proc present, pid absent -> definitively dead.
  [ -e "$AGENTWS_PROC/$p" ] || return 1

  # The pid exists, but it may be a different process that reused the number.
  # stat field 22 is the process start time in clock ticks since boot; it is
  # stable for the life of a process and differs across reuse.
  if [ -n "$st" ]; then
    cur="$(awk '{print $22}' "$AGENTWS_PROC/$p/stat" 2>/dev/null || true)"
    if [ -n "$cur" ] && [ "$cur" != "$st" ]; then
      return 1
    fi
  fi
  return 0
}

# Why is this lock stale? -> "" (not stale) | "process_dead" | "ttl"
lock_stale_reason() { # lock_stale_reason <slot>
  [ -f "$(lock_file "$1")" ] || return 0
  if ! lock_owner_alive "$1"; then printf 'process_dead'; return 0; fi
  local age; age="$(lock_age_hours "$1" 2>/dev/null || true)"
  [ -n "$age" ] || return 0
  [ "$age" -ge "$(lock_ttl_hours)" ] && printf 'ttl'
  return 0
}

lock_is_stale() { # lock_is_stale <slot>
  [ -n "$(lock_stale_reason "$1")" ]
}

lock_active() { # lock_active <slot> - true if locked and not stale
  [ -f "$(lock_file "$1")" ] || return 1
  lock_is_stale "$1" && return 1
  return 0
}

lock_mine() { # lock_mine <slot>
  local o; o="$(lock_read "$1" owner 2>/dev/null)" || return 1
  [ "$o" = "$OWNER" ]
}

# Refuse to mutate a workspace someone else holds. Returns 1 to skip.
lock_guard() { # lock_guard <slot> <action-description>
  lock_active "$1" || return 0
  lock_mine "$1"   && return 0
  local o r age
  o="$(lock_read "$1" owner)"; r="$(lock_read "$1" reason)"; age="$(lock_age_hours "$1")"
  if [ "${FORCE:-0}" -eq 1 ]; then
    printf '  %s %s is locked by %s (%sh ago): %s - proceeding due to --force\n' \
      "$(c_yel WARN)" "$(slot_name "$1")" "$o" "$age" "$r"
    return 0
  fi
  printf '  %s %s is locked by %s (%sh ago): %s\n' \
    "$(c_red SKIP)" "$(slot_name "$1")" "$o" "$age" "$r"
  printf '        %s\n' "$(c_dim "$2 skipped. Use --force to override.")"
  return 1
}

# Warn once per day, per portability contract, when liveness cannot be judged.
lock_warn_no_liveness() {
  lock_liveness_supported && return 0
  local stampdir stampfile
  stampdir="$AGENTWS_LOCK_DIR/.warn"
  stampfile="$stampdir/noliveness.$(date '+%Y%m%d')"
  [ -f "$stampfile" ] && return 0
  mkdir -p "$stampdir" 2>/dev/null
  : > "$stampfile" 2>/dev/null || true
  printf 'agentws: no %s on this platform; locks expire by TTL only (ttl_hours=%s). To reclaim early: agentws unlock <slot> --force\n' \
    "$AGENTWS_PROC" "$(lock_ttl_hours)" >&2
}

cmd_lock() {
  [ $# -ge 1 ] || die "lock needs a slot, e.g. agentws lock 1 \"fp migration\""
  local slot="$1"; shift
  local reason; reason="$(lock_sanitize "${*:-unspecified}")"
  local d f; d="$(provider_slot_path "$slot")"; f="$(lock_file "$slot")"
  provider_slot_exists "$slot" || die "$(slot_name "$slot") does not exist"

  mkdir -p "$AGENTWS_LOCK_DIR" 2>/dev/null
  lock_warn_no_liveness

  if [ -f "$f" ]; then
    if lock_is_stale "$slot"; then
      printf '%s stale lock from %s (%sh old), taking over\n' \
        "$(c_yel NOTE)" "$(lock_read "$slot" owner)" "$(lock_age_hours "$slot")"
      run rm -f "$f"
    elif lock_mine "$slot"; then
      printf '%s you already hold %s\n' "$(c_grn OK)" "$(slot_name "$slot")"
      return 0
    else
      printf '%s %s is held by %s: %s\n' "$(c_red BUSY)" "$(slot_name "$slot")" \
        "$(lock_read "$slot" owner)" "$(lock_read "$slot" reason)"
      return 1
    fi
  fi

  if [ "${DRY:-0}" -eq 1 ]; then
    printf '  [dry-run] would lock %s as %s\n' "$(slot_name "$slot")" "$OWNER"
    return 0
  fi

  # atomic create: noclobber makes a concurrent second writer fail rather than win
  #
  # pid= is the short-lived agentws process, kept for forensics only.
  # owner_pid=/owner_start= describe the LONG-LIVED session and are the only
  # fields liveness is judged on. They are written only when the caller exports
  # AGENTWS_PID (or legacy WSCTL_PID); without it the lock falls back to TTL
  # expiry, because the agentws process itself exits immediately and must never
  # be used as a liveness proxy.
  local opid ostart extra
  opid="${AGENTWS_PID:-${WSCTL_PID:-}}"
  extra=""
  if [ -n "$opid" ] && [[ "$opid" =~ ^[0-9]+$ ]] && [ -e "$AGENTWS_PROC/$opid" ]; then
    ostart="$(awk '{print $22}' "$AGENTWS_PROC/$opid/stat" 2>/dev/null || true)"
    extra="$(printf 'owner_pid=%s\nowner_start=%s' "$opid" "$ostart")"
  fi

  if ( set -o noclobber; printf 'owner=%s\nreason=%s\nepoch=%s\nstamp=%s\nhost=%s\npid=%s\n%s\n' \
        "$(lock_sanitize "$OWNER")" "$reason" "$(date +%s)" "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$(hostname -s 2>/dev/null)" "$$" "$extra" > "$f" ) 2>/dev/null; then
    printf '%s locked %s as %s\n' "$(c_grn OK)" "$(slot_name "$slot")" "$OWNER"
    printf '   reason: %s\n' "$reason"
  else
    printf '%s lost race for %s, now held by %s\n' "$(c_red BUSY)" "$(slot_name "$slot")" \
      "$(lock_read "$slot" owner 2>/dev/null)"
    return 1
  fi
}

cmd_unlock() {
  [ $# -ge 1 ] || die "unlock needs a slot"
  local slot="$1"; local f; f="$(lock_file "$slot")"
  [ -f "$f" ] || { printf '%s is not locked\n' "$(slot_name "$slot")"; return 0; }
  if ! lock_mine "$slot" && [ "${FORCE:-0}" -eq 0 ]; then
    printf '%s %s is held by %s, not you (%s).\n' "$(c_red REFUSE)" "$(slot_name "$slot")" \
      "$(lock_read "$slot" owner)" "$OWNER"
    printf '   Use --force if you are certain that agent is gone.\n'
    return 1
  fi
  run rm -f "$f" && printf '%s unlocked %s\n' "$(c_grn OK)" "$(slot_name "$slot")"
}

cmd_locks() {
  mkdir -p "$AGENTWS_LOCK_DIR" 2>/dev/null
  local live
  if lock_liveness_supported; then live=1; else live=0; fi
  if [ "${JSON:-0}" -eq 1 ]; then
    local s sr objs=()
    for s in $AGENTWS_SLOTS; do
      [ -f "$(lock_file "$s")" ] || continue
      sr="$(lock_stale_reason "$s")"
      objs+=("$(printf '{"slot":%s,"name":%s,"owner":%s,"reason":%s,"age_hours":%s,"epoch":%s,"host":%s,"stale":%s,"stale_reason":%s,"mine":%s,"liveness_supported":%s}' \
        "$(jstr "$s")" "$(jstr "$(slot_name "$s")")" \
        "$(jstr "$(lock_read "$s" owner  2>/dev/null || true)")" \
        "$(jstr "$(lock_read "$s" reason 2>/dev/null || true)")" \
        "$(jnum "$(lock_age_hours "$s" 2>/dev/null || echo 0)")" \
        "$(jnum "$(lock_read "$s" epoch 2>/dev/null || echo 0)")" \
        "$(jstr "$(lock_read "$s" host   2>/dev/null || true)")" \
        "$(jbool "$(if [ -n "$sr" ]; then echo 1; else echo 0; fi)")" \
        "$(if [ -n "$sr" ]; then jstr "$sr"; else printf 'null'; fi)" \
        "$(jbool "$(lock_mine "$s" && echo 1 || echo 0)")" \
        "$(jbool "$live")")")
    done
    printf '{"ttl_hours":%s,"owner":%s,"liveness_supported":%s,"locks":[%s]}\n' \
      "$(jnum "$(lock_ttl_hours)")" "$(jstr "$OWNER")" "$(jbool "$live")" \
      "$(jjoin "${objs[@]+"${objs[@]}"}")"
    return 0
  fi
  local found=0 s f age state
  printf '%-12s %-28s %-6s %s\n' "WORKSPACE" "OWNER" "AGE" "REASON"
  printf '%s\n' "-------------------------------------------------------------------------------"
  for s in $AGENTWS_SLOTS; do
    f="$(lock_file "$s")"
    [ -f "$f" ] || continue
    found=1
    age="$(lock_age_hours "$s")"
    if lock_is_stale "$s"; then state="${age}h STALE"; else state="${age}h"; fi
    printf '%-12s %-28s %-6s %s\n' "$(slot_name "$s")" "$(lock_read "$s" owner)" \
      "$state" "$(lock_read "$s" reason)"
  done
  [ $found -eq 0 ] && printf '%s\n' "$(c_dim 'no active locks')"
  printf '\n%s\n' "$(c_dim "ttl $(lock_ttl_hours)h; locks older than that are stale and can be taken over")"
  return 0
}
