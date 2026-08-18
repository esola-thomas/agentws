# slots.sh - slot enumeration, roles, status probing, and the shared per-slot
# JSON object.
#
# Ported from wsctl:431-510 and 667-704. status and free both build on
# json_slot_obj so the two can never disagree, which is the reason wsctl:463
# exists.
#
# Every `[[ -d $d/.git ]]` in wsctl (138, 283, 438, 552, 579, 719) is replaced
# here by provider_slot_exists. A git worktree's .git is a file, so the -d test
# reported zero slots under the default provider.

slot_is_reference() { # slot_is_reference <slot>
  [ -n "${AGENTWS_REFERENCE_SLOT:-}" ] && [ "$1" = "$AGENTWS_REFERENCE_SLOT" ]
}

slot_is_excluded() { # slot_is_excluded <slot>
  local x
  for x in ${AGENTWS_EXCLUDE_FROM_CLAIM:-}; do
    [ "$x" = "$1" ] && return 0
  done
  return 1
}

# reference | excluded | work
slot_role() { # slot_role <slot>
  if slot_is_reference "$1"; then printf 'reference'
  elif slot_is_excluded "$1"; then printf 'excluded'
  else printf 'work'
  fi
}

slot_known() { # slot_known <slot>
  local s
  for s in $AGENTWS_SLOTS; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# Resolve a user-supplied argument to a slot id. Accepts the bare slot ("1"),
# the rendered name ("1_myproj"), or an absolute path to the slot directory.
slot_resolve() { # slot_resolve <arg> -> slot id, rc 1 if no match
  local want="$1" s
  for s in $AGENTWS_SLOTS; do
    [ "$s" = "$want" ] && { printf '%s' "$s"; return 0; }
  done
  for s in $AGENTWS_SLOTS; do
    [ "$(slot_name "$s")" = "$want" ] && { printf '%s' "$s"; return 0; }
    [ "$(provider_slot_path "$s")" = "$want" ] && { printf '%s' "$s"; return 0; }
  done
  return 1
}

# ------------------------------------------------------------------- probes
# Each returns a value with a safe default, never an error, so a slot with a
# broken checkout still produces a complete status row.

slot_branch() { # slot_branch <slot>
  git -C "$(provider_slot_path "$1")" branch --show-current 2>/dev/null || true
}

slot_dirty_count() { # slot_dirty_count <slot> -> integer
  local n
  n="$(git -C "$(provider_slot_path "$1")" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  [ -n "$n" ] || n=0
  printf '%s' "$n"
}

slot_upstream() { # slot_upstream <slot>
  git -C "$(provider_slot_path "$1")" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true
}

slot_ahead_behind() { # slot_ahead_behind <slot> -> "<ahead> <behind>"
  local d up a b
  d="$(provider_slot_path "$1")"
  up="$(slot_upstream "$1")"
  if [ -z "$up" ]; then printf '0 0'; return 0; fi
  a="$(git -C "$d" rev-list --count "${up}..HEAD" 2>/dev/null || echo 0)"
  b="$(git -C "$d" rev-list --count "HEAD..${up}" 2>/dev/null || echo 0)"
  printf '%s %s' "${a:-0}" "${b:-0}"
}

# --------------------------------------------------------------- claimable
# THE policy, in one place. status, free, and claim all read it, so they cannot
# drift. A slot is claimable when it is:
#   a work slot (not the reference slot, not in exclude_from_claim),
#   it exists, it is not actively locked, its tree is clean,
#   and it is on the default branch.
slot_claimable() { # slot_claimable <slot>
  [ "$(slot_role "$1")" = "work" ] || return 1
  provider_slot_exists "$1" || return 1
  lock_active "$1" && return 1
  [ "$(slot_dirty_count "$1")" = "0" ] || return 1
  [ "$(slot_branch "$1")" = "$AGENTWS_DEFAULT_BRANCH" ] || return 1
  return 0
}

# The weaker predicate `free` reports on. Deliberately NOT the same as
# slot_claimable: free skips only the reference slot, so an excluded-but-idle
# slot such as lab still shows as free and can be locked explicitly. claim
# additionally skips excluded slots. wsctl had this split at 434-435 versus
# 671; it is intentional and must not be unified.
slot_free() { # slot_free <slot>
  slot_is_reference "$1" && return 1
  provider_slot_exists "$1" || return 1
  lock_active "$1" && return 1
  [ "$(slot_dirty_count "$1")" = "0" ] || return 1
  [ "$(slot_branch "$1")" = "$AGENTWS_DEFAULT_BRANCH" ] || return 1
  return 0
}

# ------------------------------------------------------------------- json
json_lock_obj() { # json_lock_obj <slot> -> object or null
  local s="$1" sr
  [ -f "$(lock_file "$s")" ] || { printf 'null'; return 0; }
  sr="$(lock_stale_reason "$s")"
  printf '{"owner":%s,"reason":%s,"age_hours":%s,"host":%s,"stale":%s,"stale_reason":%s,"mine":%s,"liveness_supported":%s}' \
    "$(jstr "$(lock_read "$s" owner  2>/dev/null || true)")" \
    "$(jstr "$(lock_read "$s" reason 2>/dev/null || true)")" \
    "$(jnum "$(lock_age_hours "$s" 2>/dev/null || echo 0)")" \
    "$(jstr "$(lock_read "$s" host   2>/dev/null || true)")" \
    "$(jbool "$(if [ -n "$sr" ]; then echo 1; else echo 0; fi)")" \
    "$(if [ -n "$sr" ]; then jstr "$sr"; else printf 'null'; fi)" \
    "$(jbool "$(lock_mine "$s" && echo 1 || echo 0)")" \
    "$(jbool "$(lock_liveness_supported && echo 1 || echo 0)")"
}

# The single per-slot object. wsctl:463.
json_slot_obj() { # json_slot_obj <slot>
  local s="$1" d role br dirty up ab ahead behind warns
  d="$(provider_slot_path "$s")"
  role="$(slot_role "$s")"
  br="$(slot_branch "$s")"
  dirty="$(slot_dirty_count "$s")"
  up="$(slot_upstream "$s")"
  ab="$(slot_ahead_behind "$s")"
  ahead="${ab%% *}"; behind="${ab##* }"

  warns=""
  if [ "$role" = "reference" ]; then
    [ "$br" != "$AGENTWS_DEFAULT_BRANCH" ] && warns="$(jjoin "$warns" '"reference_off_default"')"
    [ "$dirty" != "0" ]                    && warns="$(jjoin "$warns" '"reference_dirty"')"
  fi
  [ -z "$up" ] && warns="$(jjoin "$warns" '"no_upstream"')"
  [ "$behind" != "0" ] && warns="$(jjoin "$warns" '"behind_upstream"')"

  printf '{"slot":%s,"name":%s,"path":%s,"role":%s,"exists":%s,"branch":%s,"dirty":%s,"ahead":%s,"behind":%s,"upstream":%s,"upstream_ref":%s,"free":%s,"claimable":%s,"lock":%s,"warnings":[%s]}' \
    "$(jstr "$s")" "$(jstr "$(slot_name "$s")")" "$(jstr "$d")" "$(jstr "$role")" \
    "$(jbool "$(provider_slot_exists "$s" && echo 1 || echo 0)")" \
    "$(jstr "$br")" "$(jnum "$dirty")" "$(jnum "$ahead")" "$(jnum "$behind")" \
    "$(jbool "$(if [ -n "$up" ]; then echo 1; else echo 0; fi)")" \
    "$(if [ -n "$up" ]; then jstr "$up"; else printf 'null'; fi)" \
    "$(jbool "$(slot_free "$s" && echo 1 || echo 0)")" \
    "$(jbool "$(slot_claimable "$s" && echo 1 || echo 0)")" \
    "$(json_lock_obj "$s")" "$warns"
}
