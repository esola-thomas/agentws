# commands.sh - status, claim, refresh, recycle, environment, maintenance, and
# lifecycle command implementations.
#
# Ported from wsctl: claim 388-428, status 512-570, sync 573-601,
# prune 604-616, create 640-664, free 667-704, doctor 707-762.
#
# Contract for every function here: under --json, human narrative goes to
# stderr via say/sayf and the single JSON value goes to stdout, where
# envelope_run picks it up as the envelope's `data`.

# ------------------------------------------------------------------- status
cmd_status() {
  local s objs=() missing=()

  if [ "${JSON:-0}" -eq 1 ]; then
    for s in $AGENTWS_SLOTS; do
      if provider_slot_exists "$s"; then
        objs+=("$(json_slot_obj "$s")")
      else
        missing+=("$(jstr "$(slot_name "$s")")")
      fi
    done
    printf '{"root":%s,"top":%s,"provider":%s,"default_branch":%s,"ttl_hours":%s,"owner":%s,"liveness_supported":%s,"slots":[%s],"missing":[%s]}' \
      "$(jstr "$AGENTWS_ROOT")" "$(jstr "$AGENTWS_TOP")" "$(jstr "$AGENTWS_PROVIDER")" \
      "$(jstr "$AGENTWS_DEFAULT_BRANCH")" "$(jnum "$AGENTWS_TTL_HOURS")" "$(jstr "$OWNER")" \
      "$(jbool "$(lock_liveness_supported && echo 1 || echo 0)")" \
      "$(jjoin "${objs[@]+"${objs[@]}"}")" "$(jjoin "${missing[@]+"${missing[@]}"}")"
    return 0
  fi

  local d br dirty dirty_state env ab ahead behind note dirty_disp missing_names=""
  printf '%-16s %-28s %-14s %-8s %-7s %s\n' "WORKSPACE" "BRANCH" "DIRTY" "ENV" "AHEAD" "NOTE"
  printf '%s\n' "------------------------------------------------------------------------------------------------"
  for s in $AGENTWS_SLOTS; do
    if ! provider_slot_exists "$s"; then
      missing_names="${missing_names:+$missing_names }$(slot_name "$s")"
      continue
    fi
    d="$(provider_slot_path "$s")"
    br="$(slot_branch "$s")"; [ -n "$br" ] || br="?"
    dirty="$(slot_dirty_count "$s")"
    dirty_state="$(slot_dirty_state "$s")"
    env="$(slot_env_state "$s")"
    ab="$(slot_ahead_behind "$s")"; ahead="${ab%% *}"; behind="${ab##* }"
    note=""
    [ -z "$(slot_upstream "$s")" ] && note="no upstream"

    if slot_is_reference "$s"; then
      note="reference (read-only)"
      [ "$br" != "$AGENTWS_DEFAULT_BRANCH" ] && note="$(c_red 'OFF DEFAULT BRANCH')"
      [ "$dirty" != "0" ]                    && note="$(c_red 'REFERENCE IS DIRTY')"
    fi
    [ "$behind" != "0" ] && note="${note:+$note, }${behind} behind"

    if lock_active "$s"; then
      note="${note:+$note, }$(c_yel "LOCKED by $(lock_read "$s" owner), $(lock_remaining_display "$s") left")"
    elif [ -f "$(lock_file "$s")" ]; then
      note="${note:+$note, }$(c_dim "stale lock ($(lock_read "$s" owner))")"
    fi

    if [ "$dirty_state" = "clean" ]; then dirty_disp="clean"
    elif [ "$dirty_state" = "phantom-dirty" ]; then dirty_disp="phantom-dirty"
    else dirty_disp="${dirty} files"; fi
    printf '%-16s %-28s %-14s %-8s %-7s %s\n' "$(slot_name "$s")" "$br" "$dirty_disp" "$env" "$ahead" "$note"
  done
  [ -n "$missing_names" ] && printf '\n%s\n' "$(c_dim "not created: $missing_names")"
  return 0
}

# --------------------------------------------------------------------- free
# Idle slots: exists, unlocked, clean, on the default branch. Skips only the
# reference slot. `claimable` is the stricter set that also skips
# exclude_from_claim; the two lists differ on purpose.
cmd_free() {
  local s objs=() free=() claim=()

  if [ "${JSON:-0}" -eq 1 ]; then
    for s in $AGENTWS_SLOTS; do
      provider_slot_exists "$s" || continue
      slot_is_reference "$s" && continue
      objs+=("$(json_slot_obj "$s")")
      slot_free "$s"      && free+=("$(jstr "$(slot_name "$s")")")
      slot_claimable "$s" && claim+=("$(jstr "$(slot_name "$s")")")
    done
    printf '{"free":[%s],"claimable":[%s],"slots":[%s]}' \
      "$(jjoin "${free[@]+"${free[@]}"}")" \
      "$(jjoin "${claim[@]+"${claim[@]}"}")" \
      "$(jjoin "${objs[@]+"${objs[@]}"}")"
    return 0
  fi

  local any=0 br dirty env
  for s in $AGENTWS_SLOTS; do
    provider_slot_exists "$s" || continue
    slot_is_reference "$s" && continue
    br="$(slot_branch "$s")"
    dirty="$(slot_dirty_count "$s")"
    env="$(slot_env_state "$s")"
    if lock_active "$s"; then
      printf '%s  %-16s locked by %s: %s\n' "$(c_red HELD)" "$(slot_name "$s")" \
        "$(lock_read "$s" owner)" "$(lock_read "$s" reason)"
    elif slot_free "$s"; then
      if slot_claimable "$s"; then
        printf '%s  %-16s env: %s\n' "$(c_grn FREE)" "$(slot_name "$s")" "$env"
      else
        printf '%s  %-16s idle, excluded from claim\n' "$(c_grn FREE)" "$(slot_name "$s")"
      fi
      any=1
    else
      if [ "$dirty" != "0" ]; then
        printf '%s  %-16s %s (%s dirty)\n' "$(c_yel BUSY)" "$(slot_name "$s")" "$br" "$dirty"
      else
        printf '%s  %-16s %s\n' "$(c_yel BUSY)" "$(slot_name "$s")" "$br"
      fi
    fi
  done
  [ $any -eq 0 ] && printf '\n%s\n' "$(c_yel 'no free slots - finish or stash something first')"
  return 0
}

# -------------------------------------------------------------------- claim
# Lock the first claimable slot and report which one.
#
# stdout by default is the workspace path. With --print-env it is shell
# assignments for eval; with --json it is the slot object. Human confirmation
# always goes to stderr in those two modes so stdout stays machine-readable.
# On failure stdout is empty and the exit code is ENOSLOT, so a bare
# eval of empty output is harmless.
cmd_claim() {
  local reason="${*:-unspecified}"
  local s d pass env

  if [ "${AGENTWS_AUTO_REFRESH:-0}" -eq 1 ]; then
    for s in $AGENTWS_SLOTS; do
      [ "$(slot_role "$s")" = "work" ] || continue
      lock_active "$s" && continue
      if slot_phantom_base "$s" >/dev/null; then
        _refresh_slot "$s" auto >/dev/null 2>&1 || true
      fi
    done
  fi

  for pass in ready fallback; do
    [ "$pass" = "fallback" ] && [ "${REQUIRE_ENV:-0}" -eq 1 ] && break
    for s in $AGENTWS_SLOTS; do
      slot_claimable "$s" || continue
      env="$(slot_env_state "$s")"
      if [ "$pass" = "ready" ]; then
        [ "$env" = "ready" ] || continue
      else
        [ "$env" != "ready" ] || continue
      fi
      d="$(provider_slot_path "$s")"

      if [ "${PRINT_ENV:-0}" -eq 1 ] || [ "${JSON:-0}" -eq 1 ]; then
        cmd_lock "$s" "$reason" >&2 || continue
      else
        cmd_lock "$s" "$reason" || continue
      fi

      if [ "${JSON:-0}" -eq 1 ]; then
        json_slot_obj "$s"
      elif [ "${PRINT_ENV:-0}" -eq 1 ]; then
        printf 'export AGENTWS_SLOT=%s\n' "$(sq "$s")"
        printf 'export AGENTWS_OWNER=%s\n' "$(sq "$OWNER")"
        printf 'export AGENTWS_WS=%s\n'    "$(sq "$d")"
        printf 'export WS=%s\n'            "$(sq "$d")"
        provider_claim_env "$s" "$d"
      else
        printf '%s\n' "$d"
      fi
      return 0
    done
  done

  if [ "${JSON:-0}" -ne 1 ]; then
    if [ "${REQUIRE_ENV:-0}" -eq 1 ]; then
      printf '%s\n' "$(c_red 'no environment-ready free slot on the default branch')" >&2
    else
      printf '%s\n' "$(c_red 'no free unlocked slot on the default branch')" >&2
    fi
    printf '%s\n' "$(c_dim 'try: agentws status / agentws locks')" >&2
  else
    printf 'no free unlocked slot on the default branch\n' >&2
  fi
  return 5
}

# -------------------------------------------------------------- environment
_env_setup_slot() { # _env_setup_slot <slot>
  local s="$1" d rc=0 state marker
  d="$(provider_slot_path "$s")"
  if [ "${JSON:-0}" -eq 1 ]; then
    provider_env_setup "$s" "$d" >&2 || rc=$?
  else
    provider_env_setup "$s" "$d" || rc=$?
  fi
  [ "$rc" -eq 0 ] || { printf 'environment setup failed for %s (rc %s)\n' "$(slot_name "$s")" "$rc" >&2; return 7; }
  state="$(slot_env_state "$s")"
  [ "$state" = "ready" ] || {
    printf 'environment check for %s returned %s after setup\n' "$(slot_name "$s")" "$state" >&2
    return 7
  }
  if [ "${DRY:-0}" -ne 1 ]; then
    marker="$(slot_env_marker "$s")"
    mkdir -p "$(dirname "$marker")" 2>/dev/null || return 7
    date +%s > "$marker"
  fi
  return 0
}

# ------------------------------------------------------- post-reset hook
# Both repair paths (recycle and refresh) end by moving a slot's working tree
# and must then bring the rest of the slot to the same revision. Shared so the
# stdout discipline and the post-condition cannot drift apart.
#
# Under --json the hook's output goes to stderr: envelope_run captures a command
# function's stdout as `data`, so one chatty provider line would replace the
# whole payload with null and nobody would see an error.
#
# Sets SLOT_RESET_DETAIL and returns 7 on failure. The caller decides how to
# report it; the caller still holds the lock at this point and must keep it.
SLOT_RESET_DETAIL=""

_slot_reset_hook() { # _slot_reset_hook <slot> <abs-path> <ref>
  local s="$1" d="$2" ref="$3" rc=0
  SLOT_RESET_DETAIL=""
  if [ "${JSON:-0}" -eq 1 ]; then
    provider_slot_reset "$s" "$d" "$ref" >&2 || rc=$?
  else
    provider_slot_reset "$s" "$d" "$ref" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    SLOT_RESET_DETAIL="provider $AGENTWS_PROVIDER could not sync the slot to $ref (rc $rc)"
    return 7
  fi
  # Verify rather than trust: a provider that returns 0 without doing the work
  # would otherwise release a slot that status reports as dirty. Only a
  # populated submodule counts; an uninitialised one is not stale and never was.
  if [ "${DRY:-0}" -ne 1 ] && slot_submodule_stale "$s"; then
    SLOT_RESET_DETAIL="submodules still do not match $ref, so the slot would not be claimable"
    return 7
  fi
  return 0
}

# ------------------------------------------------------------------ refresh
REFRESH_STATUS=""
REFRESH_DETAIL=""
REFRESH_BASE=""

_refresh_slot() { # _refresh_slot <slot> <manual|auto>
  local s="$1" mode="${2:-manual}" d state
  REFRESH_STATUS="refused"; REFRESH_DETAIL=""; REFRESH_BASE=""
  d="$(provider_slot_path "$s")"
  provider_slot_exists "$s" || { REFRESH_DETAIL="not created"; return 6; }
  if lock_active "$s"; then
    REFRESH_DETAIL="locked by $(lock_read "$s" owner)"
    return 4
  fi
  if [ "$(slot_branch "$s")" != "$AGENTWS_DEFAULT_BRANCH" ]; then
    REFRESH_DETAIL="not on $AGENTWS_DEFAULT_BRANCH"
    return 8
  fi
  if [ "$mode" = "manual" ]; then
    if ! run git -C "$d" fetch origin --prune --quiet; then
      REFRESH_DETAIL="git fetch failed"
      return 8
    fi
  fi
  state="$(slot_dirty_state "$s")"
  if [ "$state" = "clean" ]; then
    REFRESH_STATUS="unchanged"; REFRESH_DETAIL="already clean"
    return 0
  fi
  if [ "$state" != "phantom-dirty" ]; then
    # A slot whose only dirt is a submodule lagging its gitlink is not phantom
    # dirt: the index already agrees with origin/<default>, only the submodule
    # checkout lags. There is no phantom base commit to name, and the repair is
    # the hook rather than a reset.
    if slot_submodule_only_dirt "$s"; then
      _slot_reset_hook "$s" "$d" "origin/$AGENTWS_DEFAULT_BRANCH" \
        || { REFRESH_DETAIL="$SLOT_RESET_DETAIL"; return 7; }
      if [ "${DRY:-0}" -eq 1 ]; then
        REFRESH_STATUS="would-refresh"; REFRESH_DETAIL="submodules lag origin/$AGENTWS_DEFAULT_BRANCH"
      else
        REFRESH_STATUS="refreshed"; REFRESH_DETAIL="synced submodules to origin/$AGENTWS_DEFAULT_BRANCH"
      fi
      return 0
    fi
    REFRESH_DETAIL="dirty content is not fully explained by a default-branch advance"
    return 8
  fi
  REFRESH_BASE="$(slot_phantom_base "$s")"
  if ! run git -C "$d" reset --hard "origin/$AGENTWS_DEFAULT_BRANCH" >/dev/null; then
    REFRESH_DETAIL="git reset failed"
    return 8
  fi
  # The reset moved the gitlinks; it did not move the submodule working trees.
  _slot_reset_hook "$s" "$d" "origin/$AGENTWS_DEFAULT_BRANCH" \
    || { REFRESH_DETAIL="$SLOT_RESET_DETAIL"; return 7; }
  if [ "${DRY:-0}" -eq 1 ]; then
    REFRESH_STATUS="would-refresh"; REFRESH_DETAIL="verified phantom dirt"
  else
    REFRESH_STATUS="refreshed"; REFRESH_DETAIL="reset verified phantom dirt to origin/$AGENTWS_DEFAULT_BRANCH"
  fi
  return 0
}

_refresh_rec() { # _refresh_rec <slot>
  printf '{"slot":%s,"name":%s,"status":%s,"detail":%s,"phantom_base":%s}' \
    "$(jstr "$1")" "$(jstr "$(slot_name "$1")")" "$(jstr "$REFRESH_STATUS")" \
    "$(jstr "$REFRESH_DETAIL")" \
    "$(if [ -n "$REFRESH_BASE" ]; then jstr "$REFRESH_BASE"; else printf 'null'; fi)"
}

cmd_refresh() {
  local targets s rc=0 recs=()
  if [ $# -gt 0 ]; then targets="$(_cmd_resolve_targets "$@")" || return 6
  else targets="$(slot_list_existing)"; fi

  for s in $targets; do
    if _refresh_slot "$s" manual; then
      sayf '%s: %s\n' "$(slot_name "$s")" "$REFRESH_DETAIL"
    else
      rc=$?
      sayf '%s: REFUSE %s\n' "$(slot_name "$s")" "$REFRESH_DETAIL"
    fi
    recs+=("$(_refresh_rec "$s")")
  done
  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"slots":[%s]}' "$(jjoin "${recs[@]+"${recs[@]}"}")"
  fi
  return "$rc"
}

# ------------------------------------------------------------------ recycle
cmd_recycle() {
  [ $# -ge 1 ] || { printf 'recycle needs a slot\n' >&2; return 2; }
  local s d current target delete_branch untracked sub_untracked tracked_dirty=0 deleted="" released=0 rc=0
  local removed=()
  s="$(slot_resolve "$1")" || { printf 'unknown slot %s\n' "$1" >&2; return 6; }
  slot_is_reference "$s" && { printf '%s is the reference slot; refusing to recycle it\n' "$(slot_name "$s")" >&2; return 2; }
  d="$(provider_slot_path "$s")"
  provider_slot_exists "$s" || { printf '%s does not exist\n' "$(slot_name "$s")" >&2; return 6; }

  if [ -f "$(lock_file "$s")" ] && ! lock_mine "$s"; then
    printf '%s is held by %s, not you (%s)\n' "$(slot_name "$s")" "$(lock_read "$s" owner)" "$OWNER" >&2
    return 4
  fi
  current="$(slot_branch "$s")"
  delete_branch="${CLAIM_BRANCH:-$current}"
  target="origin/$AGENTWS_DEFAULT_BRANCH"

  run git -C "$d" fetch origin --prune --quiet || { printf 'git fetch failed in %s\n' "$d" >&2; return 8; }
  git -C "$d" rev-parse --verify --quiet "$target" >/dev/null || {
    printf '%s is unavailable in %s\n' "$target" "$d" >&2; return 8;
  }

  # Refused before anything is touched, and named, because an edit inside a
  # submodule is invisible in the parent's own diff and shows up only as one
  # ' M <path>' line that reads like a moved pointer.
  if slot_submodule_modified "$s"; then
    printf '%s has uncommitted changes inside a submodule that recycle will not discard\n' \
      "$(slot_name "$s")" >&2
    return 8
  fi

  # Untracked files inside a submodule are invisible to `ls-files --others` but
  # still make the parent dirty, so they go through the same consent gate.
  untracked="$(slot_untracked "$s")"
  sub_untracked="$(slot_submodule_untracked "$s")"
  if [ -n "$untracked" ] && [ -n "$sub_untracked" ]; then
    untracked="$untracked
$sub_untracked"
  elif [ -n "$sub_untracked" ]; then
    untracked="$sub_untracked"
  fi
  if [ -n "$untracked" ] && [ "${CLEAN_UNTRACKED:-0}" -ne 1 ]; then
    printf '%s has untracked files; rerun with --clean-untracked to remove them:\n%s\n' \
      "$(slot_name "$s")" "$untracked" >&2
    return 8
  fi
  if [ -n "$untracked" ]; then
    while IFS= read -r path; do [ -n "$path" ] && removed+=("$(jstr "$path")"); done <<EOF
$untracked
EOF
    run git -C "$d" clean -fd -- >/dev/null || { printf 'could not clean untracked files in %s\n' "$d" >&2; return 8; }
    if [ -f "$d/.gitmodules" ]; then
      # `git clean` does not descend into a submodule, so it needs its own pass.
      run git -C "$d" submodule --quiet foreach --recursive 'git clean -fd' >/dev/null \
        || { printf 'could not clean untracked files inside submodules in %s\n' "$d" >&2; return 8; }
    fi
  fi

  # Superproject changes are user work and are refused. A gitlink that merely
  # points elsewhere is NOT: the post-reset hook restores it, and refusing it
  # here is what left a slot the old recycle had already broken impossible to
  # recycle again.
  git -C "$d" diff --quiet --ignore-submodules=all -- 2>/dev/null || tracked_dirty=1
  git -C "$d" diff --cached --quiet --ignore-submodules=all -- 2>/dev/null || tracked_dirty=1
  if [ "$tracked_dirty" -eq 1 ] && ! slot_phantom_base "$s" >/dev/null; then
    printf '%s has tracked changes that recycle will not discard\n' "$(slot_name "$s")" >&2
    return 8
  fi

  if [ "$current" = "$AGENTWS_DEFAULT_BRANCH" ]; then
    if ! git -C "$d" merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
      printf '%s has default-branch commits not contained in %s\n' "$(slot_name "$s")" "$target" >&2
      return 8
    fi
  fi
  run git -C "$d" checkout --ignore-other-worktrees -B "$AGENTWS_DEFAULT_BRANCH" "$target" --quiet || {
    printf 'could not return %s to %s\n' "$(slot_name "$s")" "$AGENTWS_DEFAULT_BRANCH" >&2
    return 8
  }

  if [ -n "$delete_branch" ] && [ "$delete_branch" != "$AGENTWS_DEFAULT_BRANCH" ] && \
     git -C "$d" show-ref --verify --quiet "refs/heads/$delete_branch"; then
    if run git -C "$d" branch -D -- "$delete_branch" >/dev/null; then
      deleted="$delete_branch"
    else
      printf 'could not delete local branch %s\n' "$delete_branch" >&2
      rc=8
    fi
  fi
  [ "$rc" -eq 0 ] || return "$rc"

  # The parent is on the default branch now, but a checkout does not move a
  # submodule working tree. Let the provider bring the rest of the slot to the
  # same revision while the lock is still held: everything below this point
  # hands the slot to someone else.
  if ! _slot_reset_hook "$s" "$d" "$target"; then
    printf '%s: %s; lock kept\n' "$(slot_name "$s")" "$SLOT_RESET_DETAIL" >&2
    return 7
  fi

  if [ -f "$(lock_file "$s")" ]; then
    if [ "${JSON:-0}" -eq 1 ]; then cmd_unlock "$s" >&2 || return 4
    else cmd_unlock "$s" || return 4; fi
    released=1
  fi

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"slot":%s,"name":%s,"path":%s,"branch":%s,"deleted_branch":%s,"removed_untracked":[%s],"released":%s}' \
      "$(jstr "$s")" "$(jstr "$(slot_name "$s")")" "$(jstr "$d")" \
      "$(jstr "$AGENTWS_DEFAULT_BRANCH")" \
      "$(if [ -n "$deleted" ]; then jstr "$deleted"; else printf 'null'; fi)" \
      "$(jjoin "${removed[@]+"${removed[@]}"}")" "$(jbool "$released")"
  else
    printf '%s recycled %s on %s\n' "$(c_grn OK)" "$(slot_name "$s")" "$AGENTWS_DEFAULT_BRANCH"
  fi
  return 0
}

cmd_done() { cmd_recycle "$@"; }

# --------------------------------------------------------------------- sync
# Fetch and prune remote-tracking refs in every slot, then fast-forward the
# reference slot when it is clean and on the default branch. Work slots are
# never merged into: they may carry a feature branch mid-task.
cmd_sync() {
  local targets s d br dirty results=() rc st detail

  if [ $# -gt 0 ]; then
    targets="$(_cmd_resolve_targets "$@")" || return 6
  else
    targets="$(slot_list_existing)"
  fi

  for s in $targets; do
    d="$(provider_slot_path "$s")"
    if ! provider_slot_exists "$s"; then
      sayf '%s: not created, skipping\n' "$(slot_name "$s")"
      results+=("$(_sync_rec "$s" skipped 'not created')")
      continue
    fi
    sayf '\n=== %s ===\n' "$(slot_name "$s")"
    if ! lock_guard "$s" "sync" >&2; then
      results+=("$(_sync_rec "$s" skipped 'locked by another owner')")
      continue
    fi

    st="ok"; detail="fetched and pruned"
    if ! run git -C "$d" fetch --all --prune --quiet; then
      st="fail"; detail="git fetch failed"
      sayf '  %s git fetch failed\n' "$(c_red FAIL)"
      results+=("$(_sync_rec "$s" "$st" "$detail")")
      continue
    fi
    sayf '  fetched + pruned remote-tracking refs\n'

    if slot_is_reference "$s"; then
      br="$(slot_branch "$s")"
      dirty="$(slot_dirty_count "$s")"
      if [ "$br" != "$AGENTWS_DEFAULT_BRANCH" ]; then
        detail="reference on $br, not $AGENTWS_DEFAULT_BRANCH; not touched"
        sayf '  %s reference is on %s, not %s. Not touching it.\n' \
          "$(c_red SKIP)" "$br" "$AGENTWS_DEFAULT_BRANCH"
      elif [ "$dirty" != "0" ]; then
        detail="reference has $dirty uncommitted file(s); not touched"
        sayf '  %s reference has %s uncommitted file(s). Not touching it.\n' "$(c_red SKIP)" "$dirty"
        git -C "$d" status --short 2>/dev/null | sed 's/^/    /' >&2
      else
        # --ff-only: never creates a merge commit, never rewrites history.
        if run git -C "$d" merge --ff-only "origin/${AGENTWS_DEFAULT_BRANCH}" --quiet; then
          detail="fast-forwarded to origin/$AGENTWS_DEFAULT_BRANCH"
          sayf '  fast-forwarded to origin/%s\n' "$AGENTWS_DEFAULT_BRANCH"
        else
          st="fail"; detail="fast-forward to origin/$AGENTWS_DEFAULT_BRANCH failed"
          sayf '  %s could not fast-forward\n' "$(c_yel WARN)"
        fi
      fi
    fi
    results+=("$(_sync_rec "$s" "$st" "$detail")")
  done

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"synced":[%s]}' "$(jjoin "${results[@]+"${results[@]}"}")"
  fi
  return 0
}

_sync_rec() { # _sync_rec <slot> <status> <detail>
  printf '{"slot":%s,"name":%s,"status":%s,"detail":%s}' \
    "$(jstr "$1")" "$(jstr "$(slot_name "$1")")" "$(jstr "$2")" "$(jstr "$3")"
}

# -------------------------------------------------------------------- prune
# Delete local branches that are BOTH safe to lose and no longer wanted:
# upstream gone or already merged into origin/<default>, AND merged.
#
# Divergence from wsctl:604-616, which deleted upstream-gone branches with
# `branch -D` whether or not they were merged. Here an unmerged branch is
# never deleted, only reported. Also never touched: the checked-out branch,
# the default branch, and any slot locked by someone else.
cmd_prune() {
  local targets s d cur gone merged b victims=() kept=() recs=()

  if [ $# -gt 0 ]; then
    targets="$(_cmd_resolve_targets "$@")" || return 6
  else
    targets="$(slot_list_existing)"
  fi

  for s in $targets; do
    provider_slot_exists "$s" || continue
    # The reference slot carries no local work branches by policy.
    slot_is_reference "$s" && continue
    d="$(provider_slot_path "$s")"
    sayf '\n=== %s ===\n' "$(slot_name "$s")"
    if ! lock_guard "$s" "prune" >&2; then
      recs+=("$(_prune_rec "$s" "" "")")
      continue
    fi
    run git -C "$d" fetch --prune --quiet || true

    gone="$(git -C "$d" for-each-ref --format '%(refname:short) %(upstream:track)' refs/heads 2>/dev/null \
            | awk '$2=="[gone]" {print $1}')"
    merged="$(git -C "$d" branch --merged "origin/${AGENTWS_DEFAULT_BRANCH}" --format '%(refname:short)' 2>/dev/null \
            | grep -vxF "$AGENTWS_DEFAULT_BRANCH" || true)"

    cur="$(slot_branch "$s")"
    victims=(); kept=()
    for b in $gone $merged; do
      [ -n "$b" ] || continue
      [ "$b" = "$cur" ] && continue
      [ "$b" = "$AGENTWS_DEFAULT_BRANCH" ] && continue
      case " ${victims[*]+${victims[*]}} " in *" $b "*) continue ;; esac
      case " ${kept[*]+${kept[*]}} " in *" $b "*) continue ;; esac
      # Unmerged branches hold work that exists nowhere else. Report, never delete.
      if git -C "$d" merge-base --is-ancestor "$b" "origin/${AGENTWS_DEFAULT_BRANCH}" 2>/dev/null; then
        victims+=("$b")
      else
        kept+=("$b")
      fi
    done

    if [ ${#kept[@]} -gt 0 ]; then
      sayf '  kept (unmerged, never auto-deleted):\n'
      for b in "${kept[@]+"${kept[@]}"}"; do sayf '    %s\n' "$b"; done
    fi

    if [ ${#victims[@]} -eq 0 ]; then
      sayf '  nothing to prune\n'
      recs+=("$(_prune_rec "$s" "" "$(_jstr_list "${kept[@]+"${kept[@]}"}")")")
      continue
    fi

    # The exact list is always printed before anything is deleted.
    sayf '  candidates:\n'
    for b in "${victims[@]+"${victims[@]}"}"; do sayf '    %s\n' "$b"; done

    if [ "${JSON:-0}" -eq 1 ] && [ "${ASSUME_YES:-0}" -ne 1 ] && [ "${DRY:-0}" -ne 1 ]; then
      sayf '  %s refusing to delete without --yes under --json\n' "$(c_yel SKIP)"
      recs+=("$(_prune_rec "$s" "" "$(_jstr_list "${victims[@]+"${victims[@]}"}" "${kept[@]+"${kept[@]}"}")")")
      continue
    fi

    if confirm "  delete ${#victims[@]} local branch(es) in $(slot_name "$s")?"; then
      local deleted=()
      for b in "${victims[@]+"${victims[@]}"}"; do
        # -d, not -D: git refuses if the branch turns out to be unmerged.
        if run git -C "$d" branch -d "$b" >/dev/null 2>&1; then
          sayf '    deleted %s\n' "$b"
          deleted+=("$b")
        else
          sayf '    %s git refused to delete %s\n' "$(c_yel WARN)" "$b"
          kept+=("$b")
        fi
      done
      recs+=("$(_prune_rec "$s" "$(_jstr_list "${deleted[@]+"${deleted[@]}"}")" "$(_jstr_list "${kept[@]+"${kept[@]}"}")")")
    else
      sayf '  skipped\n'
      recs+=("$(_prune_rec "$s" "" "$(_jstr_list "${victims[@]+"${victims[@]}"}" "${kept[@]+"${kept[@]}"}")")")
    fi
  done

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"pruned":[%s]}' "$(jjoin "${recs[@]+"${recs[@]}"}")"
  fi
  return 0
}

_jstr_list() { # _jstr_list [items...] -> comma-joined JSON strings
  local out="" x
  for x in "$@"; do
    [ -n "$x" ] || continue
    out="${out:+$out,}$(jstr "$x")"
  done
  printf '%s' "$out"
}

_prune_rec() { # _prune_rec <slot> <deleted-json-list> <kept-json-list>
  printf '{"slot":%s,"name":%s,"deleted":[%s],"kept":[%s]}' \
    "$(jstr "$1")" "$(jstr "$(slot_name "$1")")" "${2-}" "${3-}"
}

# ------------------------------------------------------------------- create
cmd_create() {
  [ $# -ge 1 ] || { printf 'create needs a slot, e.g. agentws create 4\n' >&2; return 2; }
  local slot="$1" d rc=0
  slot_known "$slot" || {
    printf 'slot %s is not in the configured slot list (%s)\n' "$slot" "$AGENTWS_SLOTS" >&2
    return 2
  }
  d="$(provider_slot_path "$slot")"
  if provider_slot_exists "$slot"; then
    printf '%s already exists\n' "$d" >&2
    return 2
  fi
  sayf 'creating %s\n' "$d"

  if [ "${JSON:-0}" -eq 1 ]; then
    provider_slot_create "$slot" "$d" >&2 || rc=$?
  else
    provider_slot_create "$slot" "$d" || rc=$?
  fi
  if [ $rc -ne 0 ]; then
    printf 'provider %s failed to create %s (rc %s)\n' "$AGENTWS_PROVIDER" "$d" "$rc" >&2
    return 7
  fi

  if [ "${WITH_ENV:-0}" -eq 1 ]; then
    sayf 'provisioning environment in %s\n' "$d"
    _env_setup_slot "$slot" || return $?
  fi

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"slot":%s,"name":%s,"path":%s,"created":%s,"env":%s}' \
      "$(jstr "$slot")" "$(jstr "$(slot_name "$slot")")" "$(jstr "$d")" \
      "$(jbool "$(if [ "${DRY:-0}" -eq 1 ]; then echo 0; else echo 1; fi)")" \
      "$(jstr "$(slot_env_state "$slot")")"
  else
    printf '%s created. Run: agentws doctor %s\n' "$(c_grn OK)" "$slot"
  fi
  return 0
}

# ------------------------------------------------------------------ destroy
# Remove a slot's checkout. Refuses on someone else's lock without --force,
# refuses on the reference slot outright, and refuses on a dirty tree unless
# --force. Deletion itself is the provider's job.
cmd_destroy() {
  [ $# -ge 1 ] || { printf 'destroy needs a slot\n' >&2; return 2; }
  local slot d rc=0
  slot="$(slot_resolve "$1")" || { printf 'unknown slot %s\n' "$1" >&2; return 6; }
  d="$(provider_slot_path "$slot")"

  if slot_is_reference "$slot" && [ "${FORCE:-0}" -ne 1 ]; then
    printf '%s is the reference slot; refusing to destroy it (use --force)\n' "$(slot_name "$slot")" >&2
    return 2
  fi
  provider_slot_exists "$slot" || { printf '%s does not exist\n' "$(slot_name "$slot")" >&2; return 6; }

  if lock_active "$slot" && ! lock_mine "$slot" && [ "${FORCE:-0}" -ne 1 ]; then
    printf '%s is locked by %s; refusing to destroy it\n' \
      "$(slot_name "$slot")" "$(lock_read "$slot" owner)" >&2
    return 4
  fi
  if [ "$(slot_dirty_count "$slot")" != "0" ] && [ "${FORCE:-0}" -ne 1 ]; then
    printf '%s has uncommitted changes; refusing to destroy it (use --force)\n' \
      "$(slot_name "$slot")" >&2
    return 2
  fi

  sayf 'destroying %s\n' "$d"
  if [ "${JSON:-0}" -ne 1 ] && [ "${ASSUME_YES:-0}" -ne 1 ]; then
    confirm "  delete $d?" || { printf '  skipped\n'; return 0; }
  elif [ "${JSON:-0}" -eq 1 ] && [ "${ASSUME_YES:-0}" -ne 1 ] && [ "${DRY:-0}" -ne 1 ]; then
    printf 'refusing to destroy %s without --yes under --json\n' "$d" >&2
    return 2
  fi

  if [ "${JSON:-0}" -eq 1 ]; then
    provider_slot_destroy "$slot" "$d" >&2 || rc=$?
  else
    provider_slot_destroy "$slot" "$d" || rc=$?
  fi
  if [ $rc -ne 0 ]; then
    printf 'provider %s failed to destroy %s (rc %s)\n' "$AGENTWS_PROVIDER" "$d" "$rc" >&2
    return 7
  fi

  # The lock outlives the checkout otherwise, and would block the next create.
  if [ -f "$(lock_file "$slot")" ] && { lock_mine "$slot" || [ "${FORCE:-0}" -eq 1 ]; }; then
    run rm -f "$(lock_file "$slot")"
  fi

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"slot":%s,"name":%s,"path":%s,"destroyed":%s}' \
      "$(jstr "$slot")" "$(jstr "$(slot_name "$slot")")" "$(jstr "$d")" \
      "$(jbool "$(if [ "${DRY:-0}" -eq 1 ]; then echo 0; else echo 1; fi)")"
  else
    printf '%s destroyed %s\n' "$(c_grn OK)" "$(slot_name "$slot")"
  fi
  return 0
}

# ------------------------------------------------------------------- doctor
AUTO_RELEASE_STATUS=""
AUTO_RELEASE_DETAIL=""

_auto_release_check() { # _auto_release_check <slot>
  local s="$1" d marker head seen_head seen_epoch now elapsed threshold
  AUTO_RELEASE_STATUS="skipped"; AUTO_RELEASE_DETAIL="not a finished locked slot"
  [ "${AGENTWS_AUTO_RELEASE:-0}" -eq 1 ] || return 0
  marker="$AGENTWS_ROOT/.agentws/activity/$s"
  if ! lock_active "$s" || [ "$(slot_branch "$s")" != "$AGENTWS_DEFAULT_BRANCH" ] || \
     [ "$(slot_dirty_count "$s")" != "0" ]; then
    [ "${DRY:-0}" -eq 1 ] || rm -f "$marker" 2>/dev/null || true
    return 0
  fi

  d="$(provider_slot_path "$s")"
  head="$(git -C "$d" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$head" ] || return 0
  seen_head="$(sed -n 's/^head=//p' "$marker" 2>/dev/null | head -1)"
  seen_epoch="$(sed -n 's/^epoch=//p' "$marker" 2>/dev/null | head -1)"
  now="$(date +%s)"; threshold=$((AGENTWS_AUTO_RELEASE_MINUTES * 60))

  if [ "$threshold" -eq 0 ]; then
    if run rm -f "$(lock_file "$s")"; then
      [ "${DRY:-0}" -eq 1 ] || rm -f "$marker" 2>/dev/null || true
      AUTO_RELEASE_STATUS="pass"
      AUTO_RELEASE_DETAIL="released finished slot after 0 quiet minute(s)"
    fi
    return 0
  fi

  if [ "$seen_head" = "$head" ] && [[ "$seen_epoch" =~ ^[0-9]+$ ]]; then
    elapsed=$((now - seen_epoch))
    if [ "$elapsed" -ge "$threshold" ]; then
      if run rm -f "$(lock_file "$s")"; then
        [ "${DRY:-0}" -eq 1 ] || rm -f "$marker" 2>/dev/null || true
        AUTO_RELEASE_STATUS="pass"
        AUTO_RELEASE_DETAIL="released finished slot after $AGENTWS_AUTO_RELEASE_MINUTES quiet minute(s)"
      fi
      return 0
    fi
    AUTO_RELEASE_STATUS="pass"
    AUTO_RELEASE_DETAIL="finished state observed; release eligible in $(( (threshold - elapsed + 59) / 60 )) minute(s)"
    return 0
  fi

  if [ "${DRY:-0}" -ne 1 ]; then
    mkdir -p "$(dirname "$marker")" 2>/dev/null || return 0
    printf 'head=%s\nepoch=%s\n' "$head" "$now" > "$marker"
  fi
  AUTO_RELEASE_STATUS="pass"
  AUTO_RELEASE_DETAIL="started finished-state quiet period"
  return 0
}

# Core checks first, then the provider's. The provider emits one record per
# line as "status<TAB>..." or "STATUS check detail"; both forms are normalised
# by _doctor_norm.
cmd_doctor() {
  local targets s d ok line recs env_state objs=() anybad=0

  if [ $# -gt 0 ]; then
    targets="$(_cmd_resolve_targets "$@")" || return 6
  else
    targets="$(slot_list_existing)"
  fi

  for s in $targets; do
    d="$(provider_slot_path "$s")"
    ok=1; recs=""

    if provider_slot_exists "$s"; then
      recs="$(jjoin "$recs" "$(_doctor_rec exists pass "$d")")"
    else
      recs="$(jjoin "$recs" "$(_doctor_rec exists fail "no checkout at $d")")"
      ok=0
    fi

    if [ -n "$(slot_branch "$s")" ]; then
      recs="$(jjoin "$recs" "$(_doctor_rec branch pass "$(slot_branch "$s")")")"
    else
      recs="$(jjoin "$recs" "$(_doctor_rec branch fail 'HEAD unresolvable')")"
      ok=0
    fi

    if [ -n "$(slot_upstream "$s")" ]; then
      recs="$(jjoin "$recs" "$(_doctor_rec upstream pass "$(slot_upstream "$s")")")"
    else
      recs="$(jjoin "$recs" "$(_doctor_rec upstream warn 'no upstream branch configured')")"
    fi

    if [ "$(slot_dirty_count "$s")" = "0" ]; then
      recs="$(jjoin "$recs" "$(_doctor_rec worktree pass clean)")"
    else
      recs="$(jjoin "$recs" "$(_doctor_rec worktree warn "$(slot_dirty_count "$s") uncommitted file(s)")")"
    fi

    if [ "${AGENTWS_AUTO_RELEASE:-0}" -eq 1 ]; then
      _auto_release_check "$s"
      recs="$(jjoin "$recs" "$(_doctor_rec auto_release "$AUTO_RELEASE_STATUS" "$AUTO_RELEASE_DETAIL")")"
    fi

    if [ -f "$(lock_file "$s")" ]; then
      if lock_is_stale "$s"; then
        recs="$(jjoin "$recs" "$(_doctor_rec lock warn "stale ($(lock_stale_reason "$s")) held by $(lock_read "$s" owner)")")"
      else
        recs="$(jjoin "$recs" "$(_doctor_rec lock pass "held by $(lock_read "$s" owner)")")"
      fi
    else
      recs="$(jjoin "$recs" "$(_doctor_rec lock pass unlocked)")"
    fi

    if ! lock_liveness_supported; then
      recs="$(jjoin "$recs" "$(_doctor_rec liveness warn "no $AGENTWS_PROC on this platform; locks expire by TTL only (ttl_hours=$AGENTWS_TTL_HOURS). To reclaim early: agentws unlock <slot> --force")")"
    fi

    env_state="$(slot_env_state "$s")"
    if [ "${FIX_ENV:-0}" -eq 1 ] && [ "$env_state" != "ready" ]; then
      if lock_guard "$s" "environment repair" >&2; then
        if _env_setup_slot "$s"; then env_state="ready"
        else ok=0; env_state="$(slot_env_state "$s")"; fi
      else
        recs="$(jjoin "$recs" "$(_doctor_rec env skipped "locked by another owner; environment is $env_state")")"
      fi
    fi
    case "$env_state" in
      ready) recs="$(jjoin "$recs" "$(_doctor_rec env pass ready)")" ;;
      *)     recs="$(jjoin "$recs" "$(_doctor_rec env warn "$env_state")")" ;;
    esac

    # Provider checks. stderr is left alone so a provider can narrate.
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      recs="$(jjoin "$recs" "$(_doctor_norm "$line")")"
      case "$line" in FAIL*|*"	fail	"*) ok=0 ;; esac
    done <<EOF
$(provider_slot_doctor "$s" "$d" 2>/dev/null || true)
EOF

    [ "$ok" -eq 1 ] || anybad=1
    objs+=("$(printf '{"slot":%s,"name":%s,"path":%s,"ok":%s,"checks":[%s]}' \
      "$(jstr "$s")" "$(jstr "$(slot_name "$s")")" "$(jstr "$d")" "$(jbool "$ok")" "$recs")")

    if [ "${JSON:-0}" -ne 1 ]; then
      printf '\n=== %s ===\n' "$(slot_name "$s")"
      _doctor_print "$recs"
    fi
  done

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"ok":%s,"slots":[%s]}' \
      "$(jbool "$(if [ $anybad -eq 0 ]; then echo 1; else echo 0; fi)")" \
      "$(jjoin "${objs[@]+"${objs[@]}"}")"
  fi
  return 0
}

_doctor_rec() { # _doctor_rec <id> <pass|warn|fail|skipped> <detail>
  printf '{"id":%s,"status":%s,"detail":%s}' "$(jstr "$1")" "$(jstr "$2")" "$(jstr "${3-}")"
}

# Accept either "id<TAB>status<TAB>detail" (a provider that emits tabular
# doctor output) or "STATUS id detail" (_contract.sh / worktree.sh).
_doctor_norm() { # _doctor_norm <line>
  local l="$1" id st detail
  case "$l" in
    *"	"*)
      id="${l%%	*}"; l="${l#*	}"
      st="${l%%	*}"
      if [ "$st" = "$l" ]; then detail=""; else detail="${l#*	}"; fi
      ;;
    *)
      st="$(lower "${l%% *}")"; l="${l#* }"
      id="${l%% *}"
      if [ "$id" = "$l" ]; then detail=""; else detail="${l#* }"; fi
      case "$st" in ok) st="pass" ;; esac
      ;;
  esac
  _doctor_rec "$id" "$st" "$detail"
}

_doctor_print() { # _doctor_print <json check array body>
  local id st detail rest="$1"
  # Re-render without jq so the human path keeps jq optional.
  printf '%s' "$rest" | sed 's/},{/}\n{/g' | while IFS= read -r one; do
    [ -n "$one" ] || continue
    id="$(printf '%s' "$one"     | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
    st="$(printf '%s' "$one"     | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
    detail="$(printf '%s' "$one" | sed -n 's/.*"detail":"\(.*\)"}*$/\1/p')"
    case "$st" in
      pass)    printf '  %s %-12s %s\n' "$(c_grn PASS)" "$id" "$detail" ;;
      warn)    printf '  %s %-12s %s\n' "$(c_yel WARN)" "$id" "$detail" ;;
      fail)    printf '  %s %-12s %s\n' "$(c_red FAIL)" "$id" "$detail" ;;
      *)       printf '  %s %-12s %s\n' "$(c_dim SKIP)" "$id" "$detail" ;;
    esac
  done
}

# ------------------------------------------------- lock / unlock / locks JSON
# lock.sh's cmd_lock and cmd_unlock print a narrative. These wrappers add the
# --json form that wsctl:797 refused.
cmd_lock_json() {
  [ $# -ge 1 ] || { printf 'lock needs a slot and a reason\n' >&2; return 2; }
  local slot reason rc=0
  slot="$(slot_resolve "$1")" || { printf 'unknown slot %s\n' "$1" >&2; return 6; }
  shift
  reason="${*:-unspecified}"
  cmd_lock "$slot" "$reason" >&2 || rc=$?
  if [ $rc -ne 0 ]; then
    printf 'could not lock %s\n' "$(slot_name "$slot")" >&2
    return 4
  fi
  json_slot_obj "$slot"
}

cmd_unlock_json() {
  [ $# -ge 1 ] || { printf 'unlock needs a slot\n' >&2; return 2; }
  local slot rc=0
  slot="$(slot_resolve "$1")" || { printf 'unknown slot %s\n' "$1" >&2; return 6; }
  cmd_unlock "$slot" >&2 || rc=$?
  if [ $rc -ne 0 ]; then
    printf 'could not unlock %s\n' "$(slot_name "$slot")" >&2
    return 4
  fi
  json_slot_obj "$slot"
}

# ------------------------------------------------------------------ helpers
# Map command arguments to slot ids, or fail with a message on stderr.
_cmd_resolve_targets() {
  local a s out=""
  for a in "$@"; do
    if s="$(slot_resolve "$a")"; then
      out="${out:+$out }$s"
    else
      printf 'unknown slot %s (configured: %s)\n' "$a" "$AGENTWS_SLOTS" >&2
      return 1
    fi
  done
  printf '%s' "$out"
}
