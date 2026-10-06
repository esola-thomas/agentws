# worktree.sh - DEFAULT provider. Each slot is a git worktree of one parent
# clone. Cheap and fast: slots share the object store.
#
# provider_opts:
#   source_repo    parent clone the worktrees hang off. Defaults to the
#                  reference slot's path, else {root}/<top>.
#   branch_prefix  opt-in branch namespace, e.g. "agentws/". Unset by default:
#                  a new slot is parked detached at origin/<default_branch>, the
#                  only state slot_claimable (lib/slots.sh) accepts. Setting this
#                  puts each new slot on its own branch, which leaves it
#                  unclaimable until it is recycled.

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

  start="origin/$AGENTWS_DEFAULT_BRANCH"
  git -C "$src" rev-parse --verify --quiet "refs/remotes/$start" >/dev/null 2>&1 \
    || die "$start not found in $src (fetch it first)"

  br="${AGENTWS_P_branch_prefix:-}"
  if [ -z "$br" ]; then
    # Detached, not on default_branch: idle slots that share one branch ref all
    # move whenever any of them moves it.
    run git -C "$src" worktree add --detach "$d" "$start"
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
