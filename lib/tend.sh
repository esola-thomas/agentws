# tend.sh - one-shot farm maintenance. Scheduling lives in tend_schedule.sh.

tend_notice() {
  local state="$AGENTWS_ROOT/.agentws/tend.json" last count age interval
  interval="${AGENTWS_TEND_INTERVAL_MINUTES:-15}"
  last=0; count=0
  if [ -f "$state" ]; then
    last="$(sed -n 's/.*"last_run":\([0-9][0-9]*\).*/\1/p' "$state")"
    count="$(sed -n 's/.*"problem_count":\([0-9][0-9]*\).*/\1/p' "$state")"
  fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  age=$(( ($(date +%s) - last) / 60 ))
  if [ -f "$AGENTWS_ROOT/.agentws/tend-schedule" ] && \
     { [ "$last" -eq 0 ] || awk -v age="$age" -v interval="$interval" \
       'BEGIN { exit !(age > interval * 3) }'; }; then
    say "tend: schedule overdue (agentws tend --status)"
  elif [ "$count" -gt 0 ]; then
    say "tend: $count problems (agentws tend --status)"
  elif [ "$last" -gt 0 ]; then
    say "tended ${age}m ago"
  fi
}

_tend_cleanup() {
  if [ -n "${TEND_HELD:-}" ]; then
    cmd_unlock "$TEND_HELD" >/dev/null 2>&1 || true
  fi
  rmdir "$AGENTWS_LOCK_DIR/tend.mutex" 2>/dev/null || true
}

_tend_problem() {
  TEND_PROBLEMS+=("$(jstr "$1")")
}

_tend_record() {
  TEND_RECORDS+=("$(printf '{"slot":%s,"action":%s,"detail":%s,"env":%s}' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$3")" "$(jstr "$4")")")
}

_tend_milliseconds() {
  local now
  now="$(date +%s%3N)"
  case "$now" in *[!0-9]*) printf '%s000' "$(date +%s)" ;; *) printf '%s' "$now" ;; esac
}

_tend_health() {
  local s="$1" d="$2" top epoch
  TEND_HEALTH=""
  if ! provider_slot_exists "$s"; then
    TEND_HEALTH="checkout missing"
  else
    top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [ "$top" != "$d" ] || ! git -C "$d" rev-parse --verify HEAD >/dev/null 2>&1; then
      TEND_HEALTH="unreadable git state or missing worktree administration"
    elif [ "$AGENTWS_PROVIDER" = worktree ]; then
      if [ -z "$TEND_SOURCE_OK" ]; then
        TEND_HEALTH="reference clone missing or unreadable"
      elif [ ! -d "$d/.git" ] && \
           ! printf '%s\n' "$TEND_WORKTREES" | grep -Fx "worktree $d" >/dev/null; then
        TEND_HEALTH="reference does not list worktree"
      fi
    fi
  fi
  if [ -f "$(lock_file "$s")" ]; then
    epoch="$(lock_read "$s" epoch)"
    if lock_format_unsupported "$s"; then
      TEND_HEALTH="${TEND_HEALTH:+$TEND_HEALTH; }unsupported lock format"
    elif [ -z "$(lock_read "$s" owner)" ]; then
      TEND_HEALTH="${TEND_HEALTH:+$TEND_HEALTH; }invalid lock owner"
    else
      case "$epoch" in ''|*[!0-9]*) TEND_HEALTH="${TEND_HEALTH:+$TEND_HEALTH; }invalid lock epoch" ;; esac
    fi
  fi
}

_tend_park_reference() {
  local s="$1" d="$2" target="origin/$AGENTWS_DEFAULT_BRANCH" dirty br
  TEND_ACTION="unchanged"; TEND_DETAIL="already parked at $target"
  dirty="$(slot_dirty_count "$s")"
  br="$(slot_current_branch "$s")"
  if [ "$dirty" = "-1" ]; then
    TEND_ACTION="broken:git"; TEND_DETAIL="unreadable git state"
    return 8
  fi
  if [ "$dirty" != 0 ] && ! slot_submodule_only_dirt "$s"; then
    TEND_ACTION="skipped:dirty"
    TEND_DETAIL="$(git -C "$d" status --short 2>/dev/null)"
    return 0
  fi
  if [ -n "$(slot_submodule_unsafe "$s")" ]; then
    TEND_ACTION="skipped:submodules"; TEND_DETAIL="reference submodules contain work"
    return 0
  fi
  if [ -n "$br" ] && [ "$br" != "$AGENTWS_DEFAULT_BRANCH" ]; then
    TEND_ACTION="skipped:task-branch"; TEND_DETAIL="$br"
    return 0
  fi
  if ! git -C "$d" merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
    TEND_ACTION="skipped:unmerged"; TEND_DETAIL="detached commits not in $target"
    return 0
  fi
  if [ "$dirty" = 0 ] && [ -z "$br" ] && \
     [ "$(git -C "$d" rev-parse HEAD)" = "$(git -C "$d" rev-parse "$target")" ]; then
    return 0
  fi
  if ! git -C "$d" checkout --quiet --no-overwrite-ignore --detach "$target" >&2 || \
     ! _slot_reset_hook "$s" "$d" "$target" >&2; then
    TEND_ACTION="broken:reset"; TEND_DETAIL="${SLOT_RESET_DETAIL:-reference checkout failed}"
    return 8
  fi
  TEND_ACTION="refreshed"; TEND_DETAIL="parked at $target"
}

_tend_move() {
  local s="$1" d="$2" action="$3" br target="origin/$AGENTWS_DEFAULT_BRANCH"
  TEND_ACTION="skipped:race"; TEND_DETAIL="claim won the slot lock"
  cmd_lock "$s" maintenance >/dev/null 2>&1 || return 0
  TEND_HELD="$s"
  if [ "$action" = reference ]; then
    _tend_park_reference "$s" "$d" || TEND_RC=8
  elif [ "$action" = reap ]; then
    # Recheck after acquisition; gone upstream alone never proves work is safe.
    br="$(slot_current_branch "$s")"
    TEND_ACTION="skipped:unmerged"; TEND_DETAIL="$br"
    if [ "$(slot_dirty_count "$s")" = 0 ] && [ -z "$(slot_submodule_unsafe "$s")" ] && \
       git -C "$d" merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
      if git -C "$d" checkout --quiet --no-overwrite-ignore --detach "$target" >&2 && \
         _slot_reset_hook "$s" "$d" "$target" >&2; then
        TEND_ACTION="reaped"; TEND_DETAIL="parked at $target"
        if [ -n "$br" ] && [ "$br" != "$AGENTWS_DEFAULT_BRANCH" ]; then
          git -C "$d" branch -d "$br" >&2 || true
        fi
      else
        TEND_ACTION="broken:reset"; TEND_DETAIL="${SLOT_RESET_DETAIL:-checkout failed}"; TEND_RC=8
      fi
    fi
  elif [ "$action" != env ]; then
    if [ "$(slot_dirty_count "$s")" != 0 ]; then
      TEND_ACTION="skipped:dirty"; TEND_DETAIL="tree changed before maintenance acquired it"
    elif [ -n "$(slot_current_branch "$s")" ] || ! slot_parked "$s"; then
      TEND_ACTION="skipped:task-branch"; TEND_DETAIL="slot changed before maintenance acquired it"
    elif [ -n "$(slot_submodule_unsafe "$s")" ]; then
      TEND_ACTION="skipped:submodules"; TEND_DETAIL="submodules contain work"
    elif _refresh_slot "$s" tend; then
      TEND_ACTION="$REFRESH_STATUS"; TEND_DETAIL="$REFRESH_DETAIL"
    else
      TEND_ACTION="broken:refresh"; TEND_DETAIL="$REFRESH_DETAIL"; TEND_RC=8
    fi
  fi
  if [ "$AGENTWS_TEND_FIX_ENV" -eq 1 ] && \
     [ "$(slot_dirty_count "$s")" = 0 ] && slot_parked "$s"; then
    case "$(slot_env_state "$s")" in
      missing|stale) _env_setup_slot "$s" >&2 || _tend_problem "$s: environment provisioning failed" ;;
    esac
  fi
  if [ "$action" = env ]; then
    TEND_ACTION=unchanged; TEND_DETAIL="environment checked"
  fi
  cmd_unlock "$s" >/dev/null 2>&1 || { TEND_RC=8; _tend_problem "$s: could not release maintenance lock"; }
  TEND_HELD=""
}

_tend_pass() (
  local check="$1" end s d source="" fetch=ok env br dirty action state payload temp signature="" probe=""
  local fingerprint="" previous="" cached_rc=0 start_ms
  local TEND_HELD="" TEND_SOURCE_OK="" TEND_WORKTREES="" TEND_HEALTH=""
  local TEND_ACTION="" TEND_DETAIL="" TEND_RC=0
  local TEND_PROBLEMS=() TEND_RECORDS=() health=() statuses=() branches=() environments=()
  export GIT_OPTIONAL_LOCKS=0
  OWNER=agentws-tend
  AGENTWS_PID=$$
  TTL_OVERRIDE=1
  FORCE=0
  start_ms="$(_tend_milliseconds)"
  state="$AGENTWS_ROOT/.agentws"
  if [ "$check" -eq 0 ]; then
    mkdir -p "$AGENTWS_LOCK_DIR" "$state" || return 1
    mkdir "$AGENTWS_LOCK_DIR/tend.mutex" 2>/dev/null || {
      [ -d "$AGENTWS_LOCK_DIR/tend.mutex" ] || return 1
      [ "${JSON:-0}" -eq 1 ] && printf '{"skipped":"overlapping pass"}'
      return 0
    }
    trap '_tend_cleanup' EXIT
    trap 'exit 130' INT TERM HUP
  fi
  local source_problem=""
  if [ "$AGENTWS_PROVIDER" = worktree ]; then
    source="$(_wt_source)"
    TEND_WORKTREES="$(git -C "$source" worktree list --porcelain 2>/dev/null)" && \
      git -C "$source" rev-parse --verify HEAD >/dev/null 2>&1 && TEND_SOURCE_OK=1
    if [ -z "$TEND_SOURCE_OK" ]; then
      _tend_problem "reference clone missing or unreadable: $source"; TEND_RC=8
    fi
    if [ -n "$TEND_SOURCE_OK" ] && [ -z "$AGENTWS_REFERENCE_SLOT" ]; then
      source_problem="$(git -C "$source" status --porcelain 2>/dev/null)" || source_problem="unreadable reference state"
      [ -z "$source_problem" ] || _tend_problem "reference needs manual sync: $source_problem"
    fi
  elif [ -n "$AGENTWS_REFERENCE_SLOT" ]; then
    source="$(provider_slot_path "$AGENTWS_REFERENCE_SLOT")"
  fi
  for s in $AGENTWS_SLOTS; do
    d="$(provider_slot_path "$s")"
    _tend_health "$s" "$d"
    health+=("$TEND_HEALTH")
    br=""; probe=""; env=unknown
    if [ -z "$TEND_HEALTH" ] && ! lock_active "$s" && ! slot_is_excluded "$s"; then
      br="$(slot_current_branch "$s")"
      env="$(slot_env_state "$s")"
      if [ -z "$br" ] || slot_is_reference "$s" || [ "$AGENTWS_TEND_REAP" -eq 1 ]; then
        probe="$(git -C "$d" status --porcelain 2>/dev/null)" || probe="-1"
      fi
    fi
    statuses+=("$probe"); branches+=("$br"); environments+=("$env")
    signature="$signature
$s:$TEND_HEALTH:$br:$probe:$env:$(git -C "$d" rev-parse HEAD 2>/dev/null):$(lock_stale_reason "$s"):$(if [ -f "$(lock_file "$s")" ]; then cksum < "$(lock_file "$s")"; fi):$(if [ -d "$AGENTWS_LOCK_DIR/$s.acquire" ]; then printf acquiring; fi)"
  done
  if [ "$check" -eq 0 ]; then
    if [ "$AGENTWS_PROVIDER" = worktree ] && [ -n "$TEND_SOURCE_OK" ]; then
      git -C "$source" fetch origin --prune --quiet >&2 || fetch=offline
    fi
  else
    fetch=unchecked
  fi
  if [ "$check" -eq 0 ] && [ "$AGENTWS_PROVIDER" = worktree ] && \
     [ "$AGENTWS_TEND_FIX_ENV" -eq 0 ] && [ "$AGENTWS_TEND_SELF_UPDATE" -eq 0 ]; then
    fingerprint="$(printf '%s\n%s\n%s:%s:%s:%s:%s\n' "$signature" \
      "$(git -C "$source" rev-parse "origin/$AGENTWS_DEFAULT_BRANCH" 2>/dev/null)" \
      "$AGENTWS_TEND_REFRESH" "$AGENTWS_TEND_REAP" "$fetch" "$source_problem" "$(cksum < "$AGENTWS_CONFIG_FILE")" | cksum)"
    [ ! -f "$state/tend.fingerprint" ] || previous="$(cat "$state/tend.fingerprint")"
    if [ "$fingerprint" = "$previous" ] && [ -f "$state/tend.json" ]; then
      end="$(date +%s)"
      payload="$(sed -e "s/\"last_run\":[0-9]*/\"last_run\":$end/" \
        -e "s/\"duration_ms\":[0-9]*/\"duration_ms\":$(( $(_tend_milliseconds) - start_ms ))/" \
        -e 's/"action":"refreshed"/"action":"unchanged"/g' \
        -e 's/"action":"reaped"/"action":"unchanged"/g' \
        -e "s/\"fetch\":\"[^\"]*\"/\"fetch\":\"$fetch\"/" "$state/tend.json")"
      cached_rc="$(printf '%s' "$payload" | sed -n 's/.*"exit_code":\([0-9][0-9]*\).*/\1/p')"
      case "$cached_rc" in ''|*[!0-9]*) cached_rc=8 ;; esac
      _tend_write "$state" "$payload" || return 1
      if [ "${JSON:-0}" -eq 1 ]; then printf '%s' "$payload"; else tend_notice; fi
      return "$cached_rc"
    fi
  fi
  local i=0
  for s in $AGENTWS_SLOTS; do
    d="$(provider_slot_path "$s")"; TEND_HEALTH="${health[$i]}"
    env="${environments[$i]}"; br="${branches[$i]}"; probe="${statuses[$i]}"; i=$((i + 1))
    TEND_ACTION=""; TEND_DETAIL=""
    if [ -n "$TEND_HEALTH" ]; then
      TEND_ACTION="broken:health"; TEND_DETAIL="$TEND_HEALTH"; TEND_RC=8
    elif lock_active "$s"; then
      TEND_ACTION="skipped:locked"; TEND_DETAIL="$(lock_read "$s" owner)"
    elif slot_is_excluded "$s"; then
      TEND_ACTION="skipped:excluded"
    elif [ -d "$AGENTWS_LOCK_DIR/$s.acquire" ]; then
      TEND_ACTION="skipped:acquisition"; TEND_DETAIL="lock acquisition in progress; if abandoned, agentws unlock $s --force"
      _tend_problem "$s: $TEND_DETAIL"
    else
      dirty=0
      [ -z "$probe" ] || dirty=1
      [ "$probe" != "-1" ] || dirty=-1
      if [ "$dirty" = "-1" ]; then
        TEND_ACTION="broken:git"; TEND_DETAIL="unreadable git state"; TEND_RC=8
      elif [ "$dirty" != 0 ] && \
           { ! slot_is_reference "$s" || ! slot_submodule_only_dirt "$s"; }; then
        TEND_ACTION="skipped:dirty"
        TEND_DETAIL="$probe"
      elif [ "$check" -eq 1 ]; then
        TEND_ACTION="skipped:check"
      else
        action=""
        if [ "$AGENTWS_PROVIDER" != worktree ] && \
           { slot_is_reference "$s" || [ -z "$br" ] || [ "$AGENTWS_TEND_REAP" -eq 1 ]; }; then
          cmd_lock "$s" maintenance >/dev/null 2>&1 || {
            _tend_record "$s" skipped:race "claim won the slot lock" "$env"; continue;
          }
          TEND_HELD="$s"
          git -C "$d" fetch origin --prune --quiet >&2 || fetch=offline
        fi
        if slot_is_reference "$s"; then
          [ "$AGENTWS_TEND_REFRESH" -eq 1 ] && action=reference
        elif [ -n "$br" ]; then
          if [ "$br" != "$AGENTWS_DEFAULT_BRANCH" ] && [ "$AGENTWS_TEND_REAP" -eq 1 ] && \
             git -C "$d" merge-base --is-ancestor HEAD "origin/$AGENTWS_DEFAULT_BRANCH" 2>/dev/null; then
            action=reap
          else
            TEND_ACTION="skipped:task-branch"; TEND_DETAIL="$br"
          fi
        elif ! slot_parked "$s"; then
          TEND_ACTION="skipped:unmerged"; TEND_DETAIL="detached commits not in origin/$AGENTWS_DEFAULT_BRANCH"
        elif [ "$AGENTWS_TEND_REFRESH" -eq 1 ]; then
          action=refresh
        fi
        if [ -z "$action" ] && [ "$AGENTWS_TEND_FIX_ENV" -eq 1 ] && \
           [ -z "$br" ] && [ "$dirty" = 0 ] && slot_parked "$s"; then
          action="env"
        fi
        if [ -n "$action" ]; then
          if [ "$fetch" = offline ]; then
            TEND_ACTION="skipped:offline"; TEND_DETAIL="fetch failed; local checks completed"
          elif { [ "$action" = refresh ] || [ "$action" = reference ]; } && \
               [ "$dirty" = 0 ] && [ -z "$br" ] && [ "$AGENTWS_TEND_FIX_ENV" -eq 0 ] && \
               [ "$(git -C "$d" rev-parse HEAD)" = "$(git -C "$d" rev-parse "origin/$AGENTWS_DEFAULT_BRANCH")" ]; then
            TEND_ACTION="unchanged"; TEND_DETAIL="already parked"
          else
            _tend_move "$s" "$d" "$action"
            [ "$AGENTWS_TEND_FIX_ENV" -eq 0 ] || env="$(slot_env_state "$s")"
          fi
        fi
        if [ -n "$TEND_HELD" ]; then
          cmd_unlock "$s" >/dev/null 2>&1 || TEND_RC=8
          TEND_HELD=""
        fi
        [ -n "$TEND_ACTION" ] || TEND_ACTION="skipped:disabled"
      fi
    fi
    if [ -z "$TEND_HEALTH" ] && ! lock_active "$s"; then
      case "$TEND_ACTION" in
        skipped:*)
          if [ -f "$(lock_file "$s")" ] && lock_is_stale "$s"; then
            _tend_problem "$s: stale lock left for manual review"
          fi ;;
      esac
    fi
    case "$TEND_ACTION" in
      broken:*) _tend_problem "$s: $TEND_DETAIL" ;;
      skipped:dirty|skipped:submodules)
        slot_is_reference "$s" && _tend_problem "$s: dirty reference: $TEND_DETAIL" ;;
    esac
    case "$env" in missing|stale) _tend_problem "$s: environment $env" ;; esac
    _tend_record "$s" "$TEND_ACTION" "$TEND_DETAIL" "$env"
  done
  if [ "$check" -eq 0 ] && [ "$AGENTWS_TEND_SELF_UPDATE" -eq 1 ]; then
    cmd_update --check >&2 || _tend_problem "managed-install update check failed"
  fi
  end="$(date +%s)"
  payload="$(printf '{"last_run":%s,"duration_ms":%s,"fetch":%s,"slots":[%s],"problems":[%s],"problem_count":%s,"exit_code":%s}' \
    "$end" "$(( $(_tend_milliseconds) - start_ms ))" "$(jstr "$fetch")" \
    "$(jjoin "${TEND_RECORDS[@]+"${TEND_RECORDS[@]}"}")" \
    "$(jjoin "${TEND_PROBLEMS[@]+"${TEND_PROBLEMS[@]}"}")" "${#TEND_PROBLEMS[@]}" "$TEND_RC")"
  if [ "$check" -eq 0 ]; then
    _tend_write "$state" "$payload" || return 1
    if [ -n "$fingerprint" ]; then
      printf '%s\n' "$fingerprint" > "$state/tend.fingerprint" || return 1
    fi
  fi
  if [ "${JSON:-0}" -eq 1 ]; then printf '%s' "$payload"
  else
    say "tend: fetch $fetch, ${#TEND_PROBLEMS[@]} problems"
    for temp in "${TEND_PROBLEMS[@]+"${TEND_PROBLEMS[@]}"}"; do say "$temp"; done
  fi
  return "$TEND_RC"
)

_tend_write() {
  local state="$1" payload="$2" temp bytes
  temp="$(mktemp "$state/tend.json.XXXXXX")" || return 1
  printf '%s\n' "$payload" > "$temp" && mv "$temp" "$state/tend.json" || { rm -f "$temp"; return 1; }
  printf '%s\n' "$payload" >> "$state/tend.log" || return 1
  bytes="$(wc -c < "$state/tend.log")"
  if [ "$bytes" -gt 262144 ]; then
    temp="$(mktemp "$state/tend.log.XXXXXX")" || return 1
    tail -c 131072 "$state/tend.log" > "$temp" && mv "$temp" "$state/tend.log" || return 1
  fi
}

cmd_tend() {
  if [ "${1:-}" = schedule ]; then
    shift
    tend_schedule "$@"
    return $?
  fi
  local check="${DRY:-0}" mode=run arg
  for arg in "$@"; do
    case "$arg" in
      --check) check=1 ;;
      --install) mode=install ;;
      --uninstall) mode=uninstall ;;
      --status) mode=status ;;
      --refresh) AGENTWS_TEND_REFRESH=1 ;;
      --no-refresh) AGENTWS_TEND_REFRESH=0 ;;
      --reap) AGENTWS_TEND_REAP=1 ;;
      --no-reap) AGENTWS_TEND_REAP=0 ;;
      --no-fix-env) AGENTWS_TEND_FIX_ENV=0 ;;
      --self-update) AGENTWS_TEND_SELF_UPDATE=1 ;;
      --no-self-update) AGENTWS_TEND_SELF_UPDATE=0 ;;
      *) printf 'unknown tend argument: %s\n' "$arg" >&2; return 2 ;;
    esac
  done
  [ "${FIX_ENV:-0}" -eq 0 ] || AGENTWS_TEND_FIX_ENV=1
  if [ "$mode" = status ]; then
    local schedule state="$AGENTWS_ROOT/.agentws/tend.json"
    schedule="$(tend_schedule_status)" || return $?
    if [ "${JSON:-0}" -eq 1 ]; then
      printf '{"schedule":%s,"last":%s}' "$schedule" "$(if [ -f "$state" ]; then cat "$state"; else printf null; fi)"
    else
      say "$schedule"
      tend_notice
      [ ! -f "$state" ] || cat "$state"
    fi
  elif [ "$mode" != run ]; then
    tend_schedule "$mode"
  else
    _tend_pass "$check"
  fi
}
