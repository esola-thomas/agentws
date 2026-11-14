# checkpoint.sh - per-slot task checkpoints and claim notices, kept beside the lock.
#
# Advisory data only. No liveness, staleness, or claimability decision reads
# any file written here; see docs/LOCKING.md, "Checkpoints and notices".
#
# Files, all in the lock dir and written by core only:
#   <slot>.checkpoint       KEY=VALUE: phase pr next note branch owner updated
#   <slot>.checkpoint.md    optional free-text body
#   <slot>.checkpoint.prev  (and .prev.md) the last checkpoint a different
#                           owner left behind when its stale lock was taken over
#   <slot>.checkpoint.log   the last CHECKPOINT_LOG_LINES set/clear calls
#   <slot>.notice           the claim notice for the agent working in the slot

CHECKPOINT_FIELDS="phase pr next note"
CHECKPOINT_LOG_LINES=50
CHECKPOINT_BODY_MAX=65536

checkpoint_path() { # checkpoint_path <slot> [suffix] -> <lock_dir>/<slot>.checkpoint<suffix>
  printf '%s/%s.checkpoint%s' "$AGENTWS_LOCK_DIR" "$1" "${2-}"
}

# A symlink is never read: these files are ours, and a link means someone else
# put it there.
_cp_regular() { [ -f "$1" ] && [ ! -L "$1" ]; }

_cp_read() { # _cp_read <file> <key> -> value
  _cp_regular "$1" || return 0
  sed -n "s/^$2=//p" "$1" | head -1
}

checkpoint_exists() { _cp_regular "$(checkpoint_path "$1" "${2-}")"; }

# mv onto a directory, or a link to one, moves into it: remove a link, refuse a directory.
_cp_clear_dest() { # _cp_clear_dest <dest>
  [ ! -L "$1" ] || rm -f "$1"
  [ ! -d "$1" ]
}

# Write the producer's output to <dest> by rename, so a reader sees the old file
# or the new one, never half of either, and never writes through a link.
_cp_install() { # _cp_install <dest> <producer-cmd...>
  local dest="$1" tmp; shift
  _cp_clear_dest "$dest" || return 1
  tmp="$(mktemp "$AGENTWS_LOCK_DIR/.cp.XXXXXX")" || return 1
  if "$@" > "$tmp" && mv -f "$tmp" "$dest"; then return 0; fi
  rm -f "$tmp"
  return 1
}

_cp_log_lines() { # _cp_log_lines <slot> <line>: the capped log plus one line
  local log
  log="$(checkpoint_path "$1" .log)"
  if _cp_regular "$log"; then tail -n "$((CHECKPOINT_LOG_LINES - 1))" "$log"; fi
  printf '%s\n' "$2"
}

checkpoint_log() { # checkpoint_log <slot> <line>
  _cp_install "$(checkpoint_path "$1" .log)" _cp_log_lines "$1" "$2"
}

# Remove the current task's checkpoint, body, previous generation, and claim
# notice. Called when a lock is released. CHECKPOINT_HOLD=1 (tend's maintenance
# lock) leaves them for the stale lock tend puts back.
checkpoint_drop() { # checkpoint_drop <slot>
  [ "${CHECKPOINT_HOLD:-0}" -eq 1 ] && return 0
  [ "${DRY:-0}" -eq 1 ] && return 0
  _cp_remove "$1"
  rm -f "$AGENTWS_LOCK_DIR/$1.notice" 2>/dev/null
  return 0
}

_cp_remove() { # _cp_remove <slot>: checkpoint, body, and previous generation
  rm -f "$(checkpoint_path "$1")" "$(checkpoint_path "$1" .md)" \
        "$(checkpoint_path "$1" .prev)" "$(checkpoint_path "$1" .prev.md)" 2>/dev/null
}

# A new lock was just written. A checkpoint some other owner left becomes the
# previous generation, so the new holder can read where the old task stopped.
# The same owner taking its own stale lock back keeps everything.
checkpoint_on_acquire() { # checkpoint_on_acquire <slot> <previous-lock-owner>
  local s="$1" prev="${2-}" cp
  [ "${CHECKPOINT_HOLD:-0}" -eq 1 ] && return 0
  [ "${DRY:-0}" -eq 1 ] && return 0
  [ -n "$prev" ] && [ "$prev" = "$OWNER" ] && return 0
  rm -f "$AGENTWS_LOCK_DIR/$s.notice" 2>/dev/null
  checkpoint_exists "$s" || return 0
  cp="$(checkpoint_path "$s")"
  [ "$(_cp_read "$cp" owner)" = "$OWNER" ] && return 0
  rm -f "$cp.prev.md"
  _cp_clear_dest "$cp.prev.md" && { [ ! -e "$cp.md" ] || mv -f "$cp.md" "$cp.prev.md"; }
  _cp_clear_dest "$cp.prev" && mv -f "$cp" "$cp.prev"
  return 0
}

_cp_age() { # _cp_age <seconds> -> 5m | 3h | 2d
  local a="$1"
  if [ "$a" -lt 3600 ]; then printf '%sm' "$((a / 60))"
  elif [ "$a" -lt 172800 ]; then printf '%sh' "$((a / 3600))"
  else printf '%sd' "$((a / 86400))"; fi
}

checkpoint_age_seconds() { # checkpoint_age_seconds <slot> [suffix]
  local u
  u="$(_cp_read "$(checkpoint_path "$1" "${2-}")" updated)"
  case "$u" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$(( $(date +%s) - u ))"
}

# "phase · PR" for the status note, empty when there is neither.
checkpoint_summary() { # checkpoint_summary <slot> [second-field]
  local f out="" v
  f="$(checkpoint_path "$1")"
  _cp_regular "$f" || return 0
  for v in "$(_cp_read "$f" phase)" "$(_cp_read "$f" "${2:-pr}")"; do
    [ -n "$v" ] && out="${out:+$out · }$v"
  done
  printf '%s' "$out"
}

json_checkpoint_obj() { # json_checkpoint_obj <slot> [suffix] [with_body 0|1] -> object or null
  local s="$1" sfx="${2-}" f body="null" age
  f="$(checkpoint_path "$s" "$sfx")"
  _cp_regular "$f" || { printf 'null'; return 0; }
  if [ "${3:-0}" -eq 1 ] && _cp_regular "$f.md"; then body="$(jstr "$(cat "$f.md")")"; fi
  age="$(checkpoint_age_seconds "$s" "$sfx" || true)"
  printf '{"phase":%s,"pr":%s,"next":%s,"note":%s,"branch":%s,"owner":%s,"updated":%s,"age_seconds":%s,"has_body":%s%s}' \
    "$(jstr "$(_cp_read "$f" phase)")" "$(jstr "$(_cp_read "$f" pr)")" \
    "$(jstr "$(_cp_read "$f" next)")" "$(jstr "$(_cp_read "$f" note)")" \
    "$(jstr "$(_cp_read "$f" branch)")" "$(jstr "$(_cp_read "$f" owner)")" \
    "$(if [ -n "$age" ]; then jnum "$(_cp_read "$f" updated)"; else printf 'null'; fi)" \
    "$(if [ -n "$age" ]; then jnum "$age"; else printf 'null'; fi)" \
    "$(jbool "$(_cp_regular "$f.md" && echo 1 || echo 0)")" \
    "$(if [ "${3:-0}" -eq 1 ]; then printf ',"body":%s' "$body"; fi)"
}

# ----------------------------------------------------------------- command
# The slot a checkpoint command acts on: the named one, else the one holding
# the current directory.
_checkpoint_slot() { # _checkpoint_slot <action> [slot]
  local s
  if [ -n "${2-}" ]; then
    s="$(slot_resolve "$2")" || { printf 'unknown slot %s\n' "$2" >&2; return 6; }
  else
    s="$(slot_from_dir "$(pwd -P)")" || {
      printf 'the current directory is not inside a slot; name one: agentws checkpoint %s <slot>\n' "$1" >&2
      return 6
    }
  fi
  printf '%s' "$s"
}

# set and clear: the slot is locked, and the caller is inside it or holds it.
# A worker is usually not the lock owner (its orchestrator claimed), so being
# inside the slot is the practical rule.
_checkpoint_may_write() { # _checkpoint_may_write <slot>
  local s="$1" here
  if [ ! -f "$(lock_file "$s")" ]; then
    printf '%s is not locked; a checkpoint records the task that holds a slot\n' "$(slot_name "$s")" >&2
    return 4
  fi
  if lock_format_unsupported "$s"; then
    printf '%s\n' "$(lock_format_refusal "$s")" >&2
    return 9
  fi
  here="$(slot_from_dir "$(pwd -P)" || true)"
  [ "$here" = "$s" ] && return 0
  lock_mine "$s" && return 0
  printf '%s is held by %s; only a session inside it or its lock holder (%s) may checkpoint it\n' \
    "$(slot_name "$s")" "$(lock_read "$s" owner)" "$OWNER" >&2
  return 4
}

_checkpoint_record() { # _checkpoint_record <slot>: the merged record on stdout
  local s="$1" f k v
  f="$(checkpoint_path "$s")"
  for k in $CHECKPOINT_FIELDS; do
    case "$k" in
      phase) if [ "${CP_PHASE_SET:-0}" -eq 1 ]; then v="$CP_PHASE"; else v="$(_cp_read "$f" phase)"; fi ;;
      pr)    if [ "${CP_PR_SET:-0}" -eq 1 ];    then v="$CP_PR";    else v="$(_cp_read "$f" pr)"; fi ;;
      next)  if [ "${CP_NEXT_SET:-0}" -eq 1 ];  then v="$CP_NEXT";  else v="$(_cp_read "$f" next)"; fi ;;
      note)  if [ "${CP_NOTE_SET:-0}" -eq 1 ];  then v="$CP_NOTE";  else v="$(_cp_read "$f" note)"; fi ;;
    esac
    printf '%s=%s\n' "$k" "$(lock_sanitize "$v")"
  done
  printf 'branch=%s\nowner=%s\nupdated=%s\n' "$(lock_sanitize "$(slot_branch "$s")")" \
    "$(lock_sanitize "$(lock_read "$s" owner)")" "$(date +%s)"
}

_checkpoint_set() { # _checkpoint_set <slot>
  local s="$1" f line k
  f="$(checkpoint_path "$s")"
  if [ "${CP_GIVEN:-0}" -ne 1 ]; then
    printf 'checkpoint set needs at least one of --phase, --pr, --next, --note, --body-file\n' >&2
    return 2
  fi
  if [ -n "${CP_BODY_FILE:-}" ] && { [ ! -f "$CP_BODY_FILE" ] || [ ! -r "$CP_BODY_FILE" ]; }; then
    printf 'cannot read --body-file %s\n' "$CP_BODY_FILE" >&2
    return 2
  fi
  [ "${DRY:-0}" -eq 1 ] && { sayf '  [dry-run] would checkpoint %s\n' "$(slot_name "$s")"; return 0; }
  _cp_install "$f" _checkpoint_record "$s" || { printf 'could not write %s\n' "$f" >&2; return 1; }
  if [ -n "${CP_BODY_FILE:-}" ]; then
    _cp_install "$f.md" head -c "$CHECKPOINT_BODY_MAX" "$CP_BODY_FILE" \
      || { printf 'could not write %s\n' "$f.md" >&2; return 1; }
  fi
  line="$(_cp_read "$f" updated) set owner=$(_cp_read "$f" owner)"
  for k in $CHECKPOINT_FIELDS; do line="$line $k=$(_cp_read "$f" "$k")"; done
  checkpoint_log "$s" "$line" || true
  return 0
}

_checkpoint_print() { # _checkpoint_print <slot> <suffix> <heading>
  local f k v age
  f="$(checkpoint_path "$1" "$2")"
  _cp_regular "$f" || return 1
  age="$(checkpoint_age_seconds "$1" "$2" || true)"
  printf '%s, by %s on %s%s:\n' "$3" "$(_cp_read "$f" owner)" "$(_cp_read "$f" branch)" \
    "$(if [ -n "$age" ]; then printf ', updated %s ago' "$(_cp_age "$age")"; fi)"
  for k in $CHECKPOINT_FIELDS; do
    v="$(_cp_read "$f" "$k")"
    [ -z "$v" ] || printf '  %-6s %s\n' "$k:" "$v"
  done
  if _cp_regular "$f.md"; then sed 's/^/  | /' "$f.md"; fi
  return 0
}

cmd_checkpoint() {
  local action="${1:-}" s rc=0
  case "$action" in
    set|show|clear) shift ;;
    *) printf 'checkpoint needs set, show, or clear\n' >&2; return 2 ;;
  esac
  [ $# -le 1 ] || { printf 'checkpoint %s takes at most one slot\n' "$action" >&2; return 2; }
  if [ "${CP_GIVEN:-0}" -eq 1 ] && [ "$action" != set ]; then
    printf '%s\n' '--phase, --pr, --next, --note and --body-file apply only to checkpoint set' >&2
    return 2
  fi
  s="$(_checkpoint_slot "$action" "${1-}")" || return $?

  case "$action" in
    set)   _checkpoint_may_write "$s" && _checkpoint_set "$s" || return $? ;;
    clear)
      _checkpoint_may_write "$s" || return $?
      if [ "${DRY:-0}" -ne 1 ]; then
        _cp_remove "$s" || rc=1
        checkpoint_log "$s" "$(date +%s) clear owner=$(lock_sanitize "$(lock_read "$s" owner)")" || true
      fi
      [ "$rc" -eq 0 ] || return 1 ;;
  esac

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"slot":%s,"name":%s,"checkpoint":%s,"previous":%s}' \
      "$(jstr "$s")" "$(jstr "$(slot_name "$s")")" \
      "$(json_checkpoint_obj "$s" "" 1)" "$(json_checkpoint_obj "$s" .prev 1)"
    return 0
  fi
  case "$action" in
    set)   printf '%s checkpointed %s\n' "$(c_grn OK)" "$(slot_name "$s")" ;;
    clear) printf '%s cleared the checkpoint of %s\n' "$(c_grn OK)" "$(slot_name "$s")" ;;
    show)
      _checkpoint_print "$s" "" "$(slot_name "$s") checkpoint" \
        || printf '%s has no checkpoint\n' "$(slot_name "$s")"
      _checkpoint_print "$s" .prev "previous task" || true ;;
  esac
  return 0
}

# ------------------------------------------------------------ claim notice
# What a claim tells the agent that will work in the slot. Stored as
# <lock_dir>/<slot>.notice so a worker that never claimed sees it at session
# start. Released with the lock.
claim_notice() { # claim_notice <slot> <env-lines> <provider-lines>
  local s="$1" label
  label="$(slot_label "$s")"
  printf 'agentws: you hold slot %s (%s) for "%s".\n' "$s" "$label" "$(lock_read "$s" reason 2>/dev/null || true)"
  printf 'Label everything you create outside this checkout with %s\n' "$label"
  case "$s" in
    *[!0-9]*) printf '(databases, containers, temp dirs).\n' ;;
    *) printf '(databases, containers, temp dirs). Ports: base + %s.\n' "$s" ;;
  esac
  if [ -n "$2" ]; then
    printf 'Slot environment:\n'
    printf '%s\n' "$2" | sed 's/^/  /'
  fi
  [ -z "$3" ] || printf '%s\n' "$3"
  printf 'Checkpoint with: agentws checkpoint set --phase ... --pr ... --next ...\n'
}

# `export K=V` lines as a JSON object. A value in sq-style single quotes or in
# plain double quotes is unquoted; anything else is taken literally. Lines that
# are not an export of a valid name are skipped. Never evaluated.
claim_env_json() { # claim_env_json <lines>
  local line k v out=""
  while IFS= read -r line; do
    case "$line" in 'export '*) line="${line#export }" ;; *) continue ;; esac
    k="${line%%=*}"
    [ "$k" != "$line" ] || continue
    case "$k" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;; esac
    v="${line#*=}"
    case "$v" in
      "'"*"'") v="${v#?}"; v="${v%?}"; v="$(printf '%s' "$v" | sed "s/'\\\\''/'/g")" ;;
      '"'*'"') v="${v#?}"; v="${v%?}" ;;
    esac
    out="${out:+$out,}$(jstr "$k"):$(jstr "$v")"
  done <<EOF2
$1
EOF2
  printf '{%s}' "$out"
}

# Session-start context for a session whose cwd is inside a locked slot: the
# claim notice and the checkpoint. rc 1 when the cwd is in no locked slot.
slot_context() {
  local s n
  s="$(slot_from_dir "$(pwd -P)")" || return 1
  [ -f "$(lock_file "$s")" ] || return 1
  n="$AGENTWS_LOCK_DIR/$s.notice"
  if _cp_regular "$n"; then
    cat "$n"
  else
    printf 'agentws: you are in slot %s (%s), locked by %s for "%s". Label shared resources with %s.\n' \
      "$s" "$(slot_name "$s")" "$(lock_read "$s" owner)" "$(lock_read "$s" reason)" "$(slot_label "$s")"
  fi
  _checkpoint_print "$s" "" "Checkpoint" \
    || printf 'No checkpoint yet. Record one at each milestone: agentws checkpoint set --phase ... --next ...\n'
  _checkpoint_print "$s" .prev "Previous owner's checkpoint" || true
  return 0
}
