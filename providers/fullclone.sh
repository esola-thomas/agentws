# fullclone.sh - one independent clone per slot. Required wherever the
# toolchain needs untracked per-slot state that a worktree cannot carry.
#
# provider_opts:
#   source_repo    clone source. URL or local path. Required.
#   clone_flags    extra flags passed to git clone (e.g. --depth 1).

provider_api_version() { printf '1'; }

# A real clone has a .git directory.
provider_slot_exists() { [ -d "$(provider_slot_path "$1")/.git" ]; }

provider_slot_create() { # <slot> <abs-path>
  local d="$2" src
  src="${AGENTWS_P_source_repo:-}"
  [ -n "$src" ] || die "fullclone requires provider_opts.source_repo"
  [ -e "$d" ] && die "$d already exists"
  # Unquoted on purpose: clone_flags is a caller-supplied flag list.
  run git clone --branch "$AGENTWS_DEFAULT_BRANCH" ${AGENTWS_P_clone_flags:-} "$src" "$d"
}

provider_slot_destroy() { # <slot> <abs-path>
  local d="$2"
  [ -n "$d" ] || die "fullclone slot_destroy called with no path"
  case "$d" in
    /|"$AGENTWS_ROOT") die "refusing to delete $d" ;;
    /*) ;;
    *) die "refusing to delete a non-absolute path '$d'" ;;
  esac
  # A full clone can be many GB, so deletion is deliberate only.
  if [ "${ASSUME_YES:-0}" -ne 1 ]; then
    die "refusing to delete full clone $d without --yes"
  fi
  run rm -rf -- "$d"
}

provider_slot_doctor() { # <slot> <abs-path>
  local d="$2" bad=0 br
  if [ -d "$d/.git" ]; then
    printf 'OK clone %s\n' "$d"
  else
    printf 'FAIL clone no clone at %s\n' "$d"
    return 1
  fi

  br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ -n "$br" ]; then
    printf 'OK branch %s\n' "$br"
  else
    printf 'FAIL branch HEAD unresolvable in %s\n' "$d"
    bad=1
  fi

  if git -C "$d" remote get-url origin >/dev/null 2>&1; then
    printf 'OK remote origin %s\n' "$(git -C "$d" remote get-url origin 2>/dev/null)"
  else
    printf 'WARN remote no origin configured\n'
  fi

  if [ -n "$(git -C "$d" status --porcelain 2>/dev/null)" ]; then
    printf 'WARN worktree uncommitted changes present\n'
  else
    printf 'OK worktree clean\n'
  fi

  return $bad
}
