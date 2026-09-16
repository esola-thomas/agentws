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

slot_untracked() { # slot_untracked <slot> -> paths, one per line
  git -C "$(provider_slot_path "$1")" ls-files --others --exclude-standard 2>/dev/null || true
}

# Print the prior default-branch commit whose tree still occupies the index.
# A match proves that every tracked difference is explained by the shared
# default-branch ref advancing in another worktree.
slot_phantom_base() { # slot_phantom_base <slot>
  local s="$1" d target head index_tree commit commit_tree
  provider_slot_exists "$s" || return 1
  [ "$(slot_branch "$s")" = "$AGENTWS_DEFAULT_BRANCH" ] || return 1
  [ "$(slot_dirty_count "$s")" != "0" ] || return 1
  d="$(provider_slot_path "$s")"

  [ -z "$(slot_untracked "$s")" ] || return 1
  git -C "$d" diff --quiet --ignore-submodules=none -- 2>/dev/null || return 1
  target="$(git -C "$d" rev-parse "origin/$AGENTWS_DEFAULT_BRANCH" 2>/dev/null || true)"
  head="$(git -C "$d" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$target" ] && [ "$head" = "$target" ] || return 1
  index_tree="$(git -C "$d" write-tree 2>/dev/null || true)"
  [ -n "$index_tree" ] || return 1
  [ "$index_tree" != "$(git -C "$d" rev-parse "$target^{tree}" 2>/dev/null || true)" ] || return 1

  for commit in $(git -C "$d" rev-list "$target" 2>/dev/null); do
    commit_tree="$(git -C "$d" rev-parse "$commit^{tree}" 2>/dev/null || true)"
    if [ "$commit_tree" = "$index_tree" ]; then
      printf '%s' "$commit"
      return 0
    fi
  done
  return 1
}

# ------------------------------------------------------------- submodules
# `git status --porcelain` collapses everything below a submodule into one
# ' M <path>' line, so a slot can be dirty and unclaimable for three unrelated
# reasons that need three different answers. These probes tell them apart. Each
# is a no-op on a repo without submodules, which is why every one of them opens
# with the .gitmodules test.

# PREDICATE: a populated submodule is checked out at something other than the
# gitlink this slot's index records. `git submodule status` marks exactly that
# with '+'. An uninitialised submodule is '-' and is deliberately NOT stale: a
# slot that never populated its submodules is clean and claimable today, and
# recycle must not start cloning for it. No `grep -q`: under pipefail an early
# grep exit can SIGPIPE git and turn a match into rc 141.
slot_submodule_stale() { # slot_submodule_stale <slot>
  local d
  d="$(provider_slot_path "$1")"
  [ -f "$d/.gitmodules" ] || return 1
  [ -n "$(git -C "$d" submodule status --recursive 2>/dev/null | grep '^+' || true)" ]
}

# PREDICATE: a submodule working tree carries uncommitted tracked changes. That
# is someone's work and recycle refuses it. Note --ignore-submodules=dirty does
# NOT answer this: it still reports a moved gitlink, so it cannot distinguish a
# pointer change from an edit. foreach can.
slot_submodule_modified() { # slot_submodule_modified <slot>
  local d
  d="$(provider_slot_path "$1")"
  [ -f "$d/.gitmodules" ] || return 1
  ! git -C "$d" submodule --quiet foreach --recursive 'git diff --quiet HEAD' >/dev/null 2>&1
}

# Untracked paths inside populated submodules, as <submodule>/<path>. Neither
# `ls-files --others` nor `git clean` descends into a submodule, so these are
# invisible to recycle's untracked gate while still counting as dirt in the
# parent. $displaypath is expanded by the shell foreach spawns, not by us, which
# is why the script is single-quoted.
slot_submodule_untracked() { # slot_submodule_untracked <slot> -> paths, one per line
  local d
  d="$(provider_slot_path "$1")"
  [ -f "$d/.gitmodules" ] || return 0
  # shellcheck disable=SC2016  # $displaypath is foreach's, expanded by the shell it spawns
  git -C "$d" submodule --quiet foreach --recursive \
    'git ls-files --others --exclude-standard | sed "s|^|$displaypath/|"' 2>/dev/null || true
}

# PREDICATE: every difference in this slot is a submodule checkout lagging its
# gitlink. Nothing untracked, no tracked change outside a gitlink, no edit
# inside a submodule: drift the recorded gitlinks repair, not work anyone did.
# Deliberately NOT a fourth slot_dirty_state value; that vocabulary
# (clean|phantom-dirty|dirty) is a published part of the status JSON.
slot_submodule_only_dirt() { # slot_submodule_only_dirt <slot>
  local d
  d="$(provider_slot_path "$1")"
  [ -f "$d/.gitmodules" ] || return 1
  [ -z "$(slot_untracked "$1")" ] || return 1
  [ -z "$(slot_submodule_untracked "$1")" ] || return 1
  git -C "$d" diff --quiet --ignore-submodules=all -- 2>/dev/null || return 1
  git -C "$d" diff --cached --quiet --ignore-submodules=all -- 2>/dev/null || return 1
  slot_submodule_modified "$1" && return 1
  slot_submodule_stale "$1"
}

slot_dirty_state() { # slot_dirty_state <slot> -> clean|phantom-dirty|dirty
  if [ "$(slot_dirty_count "$1")" = "0" ]; then
    printf 'clean'
  elif slot_phantom_base "$1" >/dev/null; then
    printf 'phantom-dirty'
  else
    printf 'dirty'
  fi
}

slot_env_state() { # slot_env_state <slot> -> ready|missing|stale
  local state
  state="$(provider_env_check "$1" "$(provider_slot_path "$1")" 2>/dev/null | head -1 || true)"
  case "$state" in ready|missing|stale) printf '%s' "$state" ;; *) printf 'stale' ;; esac
}

slot_bootstrap_hint() { # slot_bootstrap_hint <slot>
  provider_bootstrap_hint "$1" "$(provider_slot_path "$1")" 2>/dev/null | head -1 || true
}

slot_env_marker() { printf '%s/.agentws/env/%s.ready' "$AGENTWS_ROOT" "$1"; }

slot_env_setup_epoch() {
  local f
  f="$(slot_env_marker "$1")"
  [ -f "$f" ] && sed -n '1p' "$f" || true
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
  printf '{"owner":%s,"reason":%s,"task_id":%s,"branch":%s,"agent":%s,"age_hours":%s,"ttl_hours":%s,"remaining_minutes":%s,"remaining_ttl":%s,"host":%s,"stale":%s,"stale_reason":%s,"mine":%s,"liveness_supported":%s}' \
    "$(jstr "$(lock_read "$s" owner  2>/dev/null || true)")" \
    "$(jstr "$(lock_read "$s" reason 2>/dev/null || true)")" \
    "$(jstr "$(lock_read "$s" task_id 2>/dev/null || true)")" \
    "$(jstr "$(lock_read "$s" branch 2>/dev/null || true)")" \
    "$(jstr "$(lock_read "$s" agent 2>/dev/null || true)")" \
    "$(jnum "$(lock_age_hours "$s" 2>/dev/null || echo 0)")" \
    "$(jnum "$(lock_ttl_hours "$s")")" \
    "$(jnum "$(lock_remaining_minutes "$s")")" \
    "$(jstr "$(lock_remaining_display "$s")")" \
    "$(jstr "$(lock_read "$s" host   2>/dev/null || true)")" \
    "$(jbool "$(if [ -n "$sr" ]; then echo 1; else echo 0; fi)")" \
    "$(if [ -n "$sr" ]; then jstr "$sr"; else printf 'null'; fi)" \
    "$(jbool "$(lock_mine "$s" && echo 1 || echo 0)")" \
    "$(jbool "$(lock_liveness_supported && echo 1 || echo 0)")"
}

# The single per-slot object. wsctl:463.
json_slot_obj() { # json_slot_obj <slot>
  local s="$1" d role br dirty dirty_state env env_epoch hint up ab ahead behind warns
  d="$(provider_slot_path "$s")"
  role="$(slot_role "$s")"
  br="$(slot_branch "$s")"
  dirty="$(slot_dirty_count "$s")"
  dirty_state="$(slot_dirty_state "$s")"
  env="$(slot_env_state "$s")"
  env_epoch="$(slot_env_setup_epoch "$s")"
  hint="$(slot_bootstrap_hint "$s")"
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
  [ "$dirty_state" = "phantom-dirty" ] && warns="$(jjoin "$warns" '"phantom_dirty"')"
  [ "$env" != "ready" ] && warns="$(jjoin "$warns" '"environment_not_ready"')"

  printf '{"slot":%s,"name":%s,"path":%s,"role":%s,"exists":%s,"branch":%s,"dirty":%s,"dirty_state":%s,"env":%s,"env_setup_epoch":%s,"bootstrap_hint":%s,"ahead":%s,"behind":%s,"upstream":%s,"upstream_ref":%s,"free":%s,"claimable":%s,"lock":%s,"warnings":[%s]}' \
    "$(jstr "$s")" "$(jstr "$(slot_name "$s")")" "$(jstr "$d")" "$(jstr "$role")" \
    "$(jbool "$(provider_slot_exists "$s" && echo 1 || echo 0)")" \
    "$(jstr "$br")" "$(jnum "$dirty")" "$(jstr "$dirty_state")" "$(jstr "$env")" \
    "$(if [ -n "$env_epoch" ]; then jnum "$env_epoch"; else printf 'null'; fi)" \
    "$(jstr "$hint")" "$(jnum "$ahead")" "$(jnum "$behind")" \
    "$(jbool "$(if [ -n "$up" ]; then echo 1; else echo 0; fi)")" \
    "$(if [ -n "$up" ]; then jstr "$up"; else printf 'null'; fi)" \
    "$(jbool "$(slot_free "$s" && echo 1 || echo 0)")" \
    "$(jbool "$(slot_claimable "$s" && echo 1 || echo 0)")" \
    "$(json_lock_obj "$s")" "$warns"
}
