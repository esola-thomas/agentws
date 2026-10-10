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

# Existence is separate from health: core reports unreadable checkouts as broken.
provider_slot_exists() { [ -e "$(provider_slot_path "$1")/.git" ]; }

_wt_gitdir() { # <abs-path> -> admin path, including when it no longer exists
  local d="$1" admin
  [ -f "$d/.git" ] || return 1
  IFS= read -r admin < "$d/.git" || return 1
  case "$admin" in
    'gitdir: '*) admin="${admin#gitdir: }" ;;
    *) return 1 ;;
  esac
  case "$admin" in
    /*) printf '%s' "$admin" ;;
    '') return 1 ;;
    *) printf '%s/%s' "$d" "$admin" ;;
  esac
}

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
  local slot="$1" d="$2" src br start s admin dependents=""
  src="$(_wt_source)"
  [ -e "$d" ] && die "$d already exists"
  if [ ! -e "$src/.git" ]; then
    for s in $AGENTWS_SLOTS; do
      admin="$(_wt_gitdir "$(provider_slot_path "$s")")" || continue
      case "$admin" in "$src"/.git/worktrees/*) dependents="${dependents:+$dependents }$(slot_name "$s")" ;; esac
    done
    if [ -n "$dependents" ]; then
      printf 'WARNING: re-cloning %s can orphan existing slots: %s; restore the original clone and its worktree administration if possible\n' "$src" "$dependents" >&2
    fi
    die "source repo $src not found; the reference clone must exist first. Restore it or clone it by hand before creating worktree slots"
  fi

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
  local d="$2" src admin snapshot backup rc=0
  src="$(_wt_source)"
  [ -e "$src/.git" ] || die "source repo $src not found; cannot remove worktree $d"

  if [ "$(slot_dirty_count "$1")" = "-1" ]; then
    [ "${FORCE:-0}" -eq 1 ] || {
      printf 'unreadable git state in %s; refusing removal\n' "$d" >&2
      return 1
    }
    admin="$(_wt_gitdir "$d")" || {
      printf 'cannot identify the worktree admin dir for %s; refusing removal\n' "$d" >&2
      return 1
    }
    if [ -e "$admin" ]; then
      printf 'worktree admin dir %s still exists; try git -C "%s" worktree repair "%s" before removal\n' "$admin" "$src" "$d" >&2
      return 1
    fi
    if [ "$d" = "$src" ] || slot_is_reference "$1" || [ -L "$d" ]; then
      printf 'refusing orphan recovery of a reference clone or symlink\n' >&2
      return 1
    fi

    # The index and local commits are lost with the admin dir. Keep every file.
    snapshot="$(mktemp -d "${TMPDIR:-/tmp}/agentws-orphan.XXXXXX")" || return 1
    mkdir "$snapshot/tree" && \
      git -C "$src" archive --format=tar --output="$snapshot/base.tar" "origin/$AGENTWS_DEFAULT_BRANCH" && \
      tar -xf "$snapshot/base.tar" -C "$snapshot/tree" || {
        rm -rf "$snapshot"
        return 1
      }
    printf 'Orphaned files compared with an archive of origin/%s (including ignored files and .git; archive export attributes apply):\n' "$AGENTWS_DEFAULT_BRANCH" >&2
    git diff --no-index --stat -- "$snapshot/tree" "$d" >&2 || rc=$?
    rm -rf "$snapshot"
    [ "$rc" -le 1 ] || return "$rc"
    if [ "${DRY:-0}" -eq 1 ]; then
      printf 'would preserve %s in %s.orphaned.*/checkout, then prune; recreate with agentws create %s\n' "$d" "$d" "$1" >&2
      return 0
    fi
    backup="$(mktemp -d "$d.orphaned.XXXXXX")" || return 1
    if ! mv "$d" "$backup/checkout"; then
      rmdir "$backup"
      return 1
    fi
    SLOT_DESTROY_BACKUP="$backup/checkout"
    printf 'Preserved orphaned files at %s; local commits and index cannot be recovered from a missing admin dir. Recreate with agentws create %s\n' "$SLOT_DESTROY_BACKUP" "$1" >&2
    run git -C "$src" worktree prune
    return $?
  fi

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
  local d="$2" common admin bad=0
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
    admin="$(_wt_gitdir "$d")" || admin=""
    if [ -n "$admin" ] && [ ! -e "$admin" ]; then
      printf 'FAIL common-dir worktree admin dir %s is missing; the reference clone may have been replaced. Restore the original clone or use agentws destroy %s --force --yes, then agentws create %s\n' "$admin" "$1" "$1"
    else
      printf 'FAIL common-dir unresolvable from %s; try git worktree repair from the reference clone\n' "$d"
    fi
    bad=1
  fi
  # branch, upstream, and worktree are core doctor checks.
  return $bad
}
