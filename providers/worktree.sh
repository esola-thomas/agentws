# worktree.sh - DEFAULT provider. Each slot is a git worktree of one parent
# clone. Cheap and fast: slots share the object store.
#
# provider_opts:
#   source_repo    parent clone the worktrees hang off. Defaults to the
#                  reference slot's path, else {root}/<top>.
#   branch_prefix  opt-in branch namespace, e.g. "agentws/". Unset by default:
#                  a new slot is checked out on default_branch, because
#                  slot_claimable (lib/slots.sh) only claims a slot that is on
#                  it. Setting this puts each new slot on its own branch, which
#                  leaves it unclaimable until it is returned to default_branch.

provider_api_version() { printf '1'; }

# A worktree's .git is a FILE, so this must be -e.
provider_slot_exists() { [ -e "$(provider_slot_path "$1")/.git" ]; }

_wt_source() {
  if [ -n "${AGENTWS_P_source_repo:-}" ]; then
    printf '%s' "$AGENTWS_P_source_repo"
  elif [ -n "${AGENTWS_REFERENCE_SLOT:-}" ]; then
    provider_slot_path "$AGENTWS_REFERENCE_SLOT"
  elif [ -e "$AGENTWS_ROOT/.git" ]; then
    printf '%s' "$AGENTWS_ROOT"
  else
    printf '%s/%s' "$AGENTWS_ROOT" "$AGENTWS_TOP"
  fi
}

provider_slot_create() { # <slot> <abs-path>
  local slot="$1" d="$2" src br start
  src="$(_wt_source)"
  [ -e "$d" ] && die "$d already exists"
  [ -e "$src/.git" ] || die "source repo $src not found (set provider_opts.source_repo)"

  if [ -n "${AGENTWS_REFERENCE_SLOT:-}" ] && [ "$slot" = "$AGENTWS_REFERENCE_SLOT" ] \
     && [ "$d" = "$src" ]; then
    die "refusing to create the reference slot $slot as a worktree of itself"
  fi

  local has_local=0 has_remote=0
  git -C "$src" rev-parse --verify --quiet "refs/heads/$AGENTWS_DEFAULT_BRANCH"          >/dev/null 2>&1 && has_local=1
  git -C "$src" rev-parse --verify --quiet "refs/remotes/origin/$AGENTWS_DEFAULT_BRANCH" >/dev/null 2>&1 && has_remote=1
  [ $has_local -eq 1 ] || [ $has_remote -eq 1 ] \
    || die "default branch '$AGENTWS_DEFAULT_BRANCH' not found in $src"

  # Prefer the remote-tracking tip so a slot starts from what the forge has;
  # fall back to the local branch on a repo with no remote.
  if [ $has_remote -eq 1 ]; then
    start="origin/$AGENTWS_DEFAULT_BRANCH"
  else
    start="$AGENTWS_DEFAULT_BRANCH"
  fi

  br="${AGENTWS_P_branch_prefix:-}"
  if [ -z "$br" ]; then
    # Default: land the slot ON default_branch, the only state slot_claimable
    # accepts. --force because git otherwise refuses a second checkout of a
    # branch already out in the source repo or in a sibling idle slot.
    if [ $has_local -eq 1 ]; then
      run git -C "$src" worktree add --force "$d" "$AGENTWS_DEFAULT_BRANCH"
    else
      run git -C "$src" worktree add --force -b "$AGENTWS_DEFAULT_BRANCH" "$d" "$start"
    fi
    return $?
  fi

  br="${br}slot-${slot}"
  if git -C "$src" rev-parse --verify --quiet "refs/heads/$br" >/dev/null 2>&1; then
    run git -C "$src" worktree add --force "$d" "$br"
  else
    run git -C "$src" worktree add -b "$br" "$d" "$start"
  fi
}

provider_slot_destroy() { # <slot> <abs-path>. Core already checked the lock.
  local d="$2" src rc=0
  src="$(_wt_source)"
  [ -e "$src/.git" ] || die "source repo $src not found; cannot remove worktree $d"

  if [ "${FORCE:-0}" -eq 1 ]; then
    run git -C "$src" worktree remove --force "$d" || rc=$?
  else
    run git -C "$src" worktree remove "$d" || rc=$?
  fi
  # A plain rm -rf would leave a stale admin entry behind in .git/worktrees.
  run git -C "$src" worktree prune
  return $rc
}

provider_slot_doctor() { # <slot> <abs-path>
  local d="$2" common bad=0
  if [ -e "$d/.git" ]; then
    printf 'OK checkout %s\n' "$d"
  else
    printf 'FAIL checkout no worktree at %s\n' "$d"
    return 1
  fi

  common="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null || true)"
  if [ -n "$common" ]; then
    printf 'OK common-dir %s\n' "$common"
  else
    printf 'FAIL common-dir unresolvable from %s\n' "$d"
    bad=1
  fi

  if git -C "$d" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    printf 'OK upstream %s\n' "$(git -C "$d" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
  else
    printf 'WARN upstream no upstream branch configured\n'
  fi

  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    printf 'WARN worktree uncommitted changes present\n'
  else
    printf 'OK worktree clean\n'
  fi

  return $bad
}
