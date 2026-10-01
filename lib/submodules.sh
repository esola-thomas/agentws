# submodules.sh - update submodule pointers in a claimed slot and open a PR.
#
#   agentws submodules [--yes] [--push] [--dry-run] [--base BRANCH] [--json]
#
# Runs in a slot of its own: claim, branch off origin/<base>, find each direct
# submodule whose tracking branch has moved ahead of the recorded gitlink, ask
# per submodule, show the staged gitlink diff, ask once more, then commit only
# those gitlinks, git push, and recycle the slot. The PR is opened with `gh`
# when it is installed; otherwise the pushed branch is printed and the forge's
# own push message carries the link. agentws itself never talks to a forge.
#
# Nested submodules are initialised and checked out, but only the gitlinks of
# the repository the farm manages are changed: a nested pointer lives in, and
# is updated through, its own parent repository.
#
# Answers are read from stdin, so `printf 'y\nn\n' | agentws submodules` works
# for scripts; end of input means no. --yes selects every candidate but still
# asks before pushing; --push is the separate, explicit skip of that question.
# --json cannot prompt, so it needs --dry-run or --yes --push.

SM_PATHS=(); SM_NAMES=(); SM_BRANCHES=(); SM_CUR=(); SM_CAND=(); SM_COUNT=(); SM_SEL=()
SM_ERRS=()
SM_SLOT=""; SM_DIR=""; SM_BR=""; SM_BASE=""
SM_PUSHED=0; SM_PR=""; SM_RECYCLED=0; SM_FINISHED=0

_sm_ask() { # _sm_ask <question> -> 0 yes, 1 no
  local reply=""
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r reply || { printf '\n' >&2; return 1; }
  # Piped answers are not echoed by a terminal; echo them for the log.
  [ -t 0 ] || printf '%s\n' "$reply" >&2
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

_sm_err() { # _sm_err <path> <message>
  SM_ERRS+=("$(printf '{"path":%s,"message":%s}' "$(jstr "$1")" "$(jstr "$2")")")
  printf '  %s %s: %s\n' "$(c_red ERROR)" "$1" "$2" >&2
}

# The branch a submodule tracks: .gitmodules `branch`, where "." means the
# superproject's base branch, else the submodule remote's default branch.
_sm_tracking_branch() { # _sm_tracking_branch <slot-dir> <name> <sm-dir> <base>
  local br
  br="$(git -C "$1" config -f .gitmodules --get "submodule.$2.branch" 2>/dev/null || true)"
  case "$br" in
    .) printf '%s' "$4"; return 0 ;;
    ?*) printf '%s' "$br"; return 0 ;;
  esac
  br="$(GIT_TERMINAL_PROMPT=0 git -C "$3" ls-remote --symref origin HEAD 2>/dev/null \
        | sed -n 's|^ref: refs/heads/\(.*\)[[:space:]]HEAD$|\1|p' | head -1)"
  [ -n "$br" ] || return 1
  printf '%s' "$br"
}

# Hand the slot back, once. A pushed branch lives on the remote, so recycle is
# safe right after the push. Gitlinks staged but not pushed are this command's
# own work: unstage them and put the submodules back first, or recycle would
# rightly refuse the slot. On failure the lock is kept and the exact recovery
# command printed, with this run's owner, which may embed a pid.
_sm_finish() {
  [ "$SM_FINISHED" -eq 1 ] && return 0
  SM_FINISHED=1
  # Ignored, not default: the recycle child inherits it, so a second Ctrl-C
  # cannot kill the cleanup halfway and strand the slot.
  trap '' INT TERM HUP
  [ -n "$SM_SLOT" ] || { trap - INT TERM HUP; return 0; }
  if [ -d "$SM_DIR" ] && ! git -C "$SM_DIR" diff --cached --quiet 2>/dev/null; then
    git -C "$SM_DIR" reset --quiet >/dev/null 2>&1
    git -C "$SM_DIR" submodule update --quiet --init --recursive >/dev/null 2>&1 || true
  fi
  if "$AGENTWS_BIN_DIR/agentws" --owner "$OWNER" recycle "$SM_SLOT" --branch "$SM_BR" >/dev/null 2>&1; then
    SM_RECYCLED=1
  else
    printf 'could not recycle slot %s; it stays locked. Run: agentws --owner %s recycle %s\n' \
      "$SM_SLOT" "$(sq "$OWNER")" "$SM_SLOT" >&2
  fi
  trap - INT TERM HUP
}

_sm_interrupted() {
  printf '\ninterrupted; handing the slot back\n' >&2
  _sm_finish
  exit 130
}

# Every path out of cmd_submodules ends here: one envelope shape, always.
_sm_result() { # _sm_result <rc>
  local i=0 n=${#SM_PATHS[@]} cand_json=()
  _sm_finish
  if [ "${JSON:-0}" -eq 1 ]; then
    while [ "$i" -lt "$n" ]; do
      cand_json+=("$(printf '{"path":%s,"name":%s,"branch":%s,"current":%s,"candidate":%s,"commits":%s,"selected":%s}' \
        "$(jstr "${SM_PATHS[$i]}")" "$(jstr "${SM_NAMES[$i]}")" "$(jstr "${SM_BRANCHES[$i]}")" \
        "$(jstr "${SM_CUR[$i]}")" "$(jstr "${SM_CAND[$i]}")" "$(jnum "${SM_COUNT[$i]}")" \
        "$(jbool "${SM_SEL[$i]}")")")
      i=$((i + 1))
    done
    printf '{"slot":%s,"base":%s,"branch":%s,"dry_run":%s,"candidates":[%s],"errors":[%s],"pushed":%s,"pr_url":%s,"recycled":%s}' \
      "$(jstr "$SM_SLOT")" "$(jstr "$SM_BASE")" "$(jstr "$SM_BR")" "$(jbool "${DRY:-0}")" \
      "$(jjoin "${cand_json[@]+"${cand_json[@]}"}")" "$(jjoin "${SM_ERRS[@]+"${SM_ERRS[@]}"}")" \
      "$(jbool "$SM_PUSHED")" "$(if [ -n "$SM_PR" ]; then jstr "$SM_PR"; else printf null; fi)" \
      "$(jbool "$SM_RECYCLED")"
  fi
  # Once a branch is pushed the run succeeded; a failed recycle is reported
  # in the result, not as a failure that would hide the pushed branch.
  [ "$SM_PUSHED" -eq 1 ] && return 0
  return "$1"
}

# Find candidates among the direct submodules of the checked-out slot.
_sm_scan() { # _sm_scan <slot-dir> <base>
  local d="$1" base="$2" rec key name path sm cur br cand cnt
  # -z: "key\nvalue\0", so names and paths with spaces survive.
  while IFS= read -r -d '' rec <&3; do
    key="${rec%%
*}"; path="${rec#*
}"
    name="${key#submodule.}"; name="${name%.path}"
    sm="$d/$path"
    cur="$(git -C "$d" ls-tree HEAD -- "$path" | awk '$2 == "commit" { print $3 }')"
    [ -n "$cur" ] || { _sm_err "$path" "no gitlink recorded in $base"; continue; }
    [ -e "$sm/.git" ] || { _sm_err "$path" "not initialised"; continue; }
    git -C "$sm" cat-file -e "$cur^{commit}" 2>/dev/null \
      || { _sm_err "$path" "recorded commit $(printf '%.7s' "$cur") not found in the submodule"; continue; }
    if ! br="$(_sm_tracking_branch "$d" "$name" "$sm" "$base")"; then
      _sm_err "$path" "cannot determine the tracking branch (no .gitmodules branch, remote HEAD unreadable)"
      continue
    fi
    if ! GIT_TERMINAL_PROMPT=0 git -C "$sm" fetch --quiet origin \
         "+refs/heads/$br:refs/remotes/origin/$br" 2>/dev/null </dev/null; then
      _sm_err "$path" "git fetch of origin/$br failed"
      continue
    fi
    cand="$(git -C "$sm" rev-parse --verify --quiet "refs/remotes/origin/$br^{commit}")"
    [ "$cand" != "$cur" ] || { printf '  %s %s is current on %s\n' "$(c_dim OK)" "$path" "$br" >&2; continue; }
    if ! git -C "$sm" merge-base --is-ancestor "$cur" "$cand" 2>/dev/null; then
      _sm_err "$path" "origin/$br ($(printf '%.7s' "$cand")) does not descend from the recorded $(printf '%.7s' "$cur"); skipped"
      continue
    fi
    cnt="$(git -C "$sm" rev-list --count "$cur..$cand")"
    SM_PATHS+=("$path"); SM_NAMES+=("$name"); SM_BRANCHES+=("$br")
    SM_CUR+=("$cur"); SM_CAND+=("$cand"); SM_COUNT+=("$cnt"); SM_SEL+=(0)
  done 3< <(git -C "$d" config -z -f "$d/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
}

cmd_submodules() {
  local push=0 claim_env d i n path nsel=0 title body="" subj="" want got pr_out
  SM_BASE="$AGENTWS_DEFAULT_BRANCH"
  while [ $# -gt 0 ]; do
    case "$1" in
      --push) push=1; shift ;;
      --base) [ $# -ge 2 ] || { printf 'submodules: --base needs a branch\n' >&2; return 2; }
              SM_BASE="$2"; shift 2 ;;
      *) printf 'submodules: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if [ "${JSON:-0}" -eq 1 ] && [ "${DRY:-0}" -ne 1 ] && { [ "${ASSUME_YES:-0}" -ne 1 ] || [ "$push" -ne 1 ]; }; then
    printf 'submodules: --json cannot prompt; use --dry-run, or --yes --push\n' >&2
    return 2
  fi
  SM_BR="agentws/submodules-$(date +%Y%m%d-%H%M%S)-$$"

  # The lock lives exactly as long as this process unless the caller set a pid.
  claim_env="$(AGENTWS_PID="${AGENTWS_PID:-$$}" "$AGENTWS_BIN_DIR/agentws" --owner "$OWNER" \
    --branch "$SM_BR" claim "submodule pointer update" --print-env)" || return 5
  # claim quotes every value for eval; read them back in a subshell.
  SM_SLOT="$(eval "$claim_env"; printf '%s' "${AGENTWS_SLOT:-}")"
  SM_DIR="$(eval "$claim_env"; printf '%s' "${AGENTWS_WS:-}")"
  trap _sm_interrupted INT TERM HUP
  if [ -z "$SM_SLOT" ] || [ ! -d "$SM_DIR" ]; then
    printf 'submodules: could not read the claimed slot\n' >&2
    _sm_result 5; return $?
  fi
  d="$SM_DIR"
  printf 'working in slot %s (%s)\n' "$SM_SLOT" "$d" >&2

  if ! git -C "$d" fetch --quiet origin >&2 \
     || ! git -C "$d" rev-parse --verify --quiet "origin/$SM_BASE^{commit}" >/dev/null; then
    printf 'submodules: cannot fetch origin/%s\n' "$SM_BASE" >&2
    _sm_result 8; return $?
  fi
  git -C "$d" checkout --quiet -b "$SM_BR" "origin/$SM_BASE" >&2 || { _sm_result 8; return $?; }
  if [ ! -f "$d/.gitmodules" ]; then
    printf 'no submodules in %s\n' "$SM_BASE" >&2
    _sm_result 0; return $?
  fi
  GIT_TERMINAL_PROMPT=0 git -C "$d" submodule update --quiet --init --recursive >&2 </dev/null \
    || _sm_err "." "git submodule update --init --recursive failed"
  _sm_scan "$d" "$SM_BASE"

  n=${#SM_PATHS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    path="${SM_PATHS[$i]}"
    printf '\n%s  %.7s -> %.7s  (%s commits on %s)\n' "$path" "${SM_CUR[$i]}" "${SM_CAND[$i]}" \
      "${SM_COUNT[$i]}" "${SM_BRANCHES[$i]}" >&2
    git -C "$d/$path" log --oneline --no-decorate -n 10 "${SM_CUR[$i]}..${SM_CAND[$i]}" 2>/dev/null \
      | sed 's/^/    /' >&2
    [ "${SM_COUNT[$i]}" -gt 10 ] && printf '    ... and %s more\n' "$((SM_COUNT[i] - 10))" >&2
    if [ "${DRY:-0}" -eq 1 ]; then
      :
    elif [ "${ASSUME_YES:-0}" -eq 1 ] || _sm_ask "Update $path?"; then
      SM_SEL[$i]=1; nsel=$((nsel + 1))
    fi
    i=$((i + 1))
  done

  if [ "$n" -eq 0 ]; then
    printf '\nno submodule has a newer commit to take\n' >&2
    _sm_result 0; return $?
  elif [ "${DRY:-0}" -eq 1 ]; then
    printf '\ndry run: %s candidate(s), nothing changed\n' "$n" >&2
    _sm_result 0; return $?
  elif [ "$nsel" -eq 0 ]; then
    printf '\nnothing selected\n' >&2
    _sm_result 0; return $?
  fi

  i=0; want=""
  while [ "$i" -lt "$n" ]; do
    if [ "${SM_SEL[$i]}" = 1 ]; then
      path="${SM_PATHS[$i]}"
      if ! git -C "$d/$path" checkout --quiet --detach "${SM_CAND[$i]}" >&2 \
         || ! git -C "$d" add -- "$path"; then
        _sm_err "$path" "could not move to ${SM_CAND[$i]}"
        _sm_result 8; return $?
      fi
      want="${want}${path}
"
      subj="${subj:+$subj, }$path"
      body="${body}$(printf -- '- %s: %.7s..%.7s (%s commits on %s)' "$path" "${SM_CUR[$i]}" \
        "${SM_CAND[$i]}" "${SM_COUNT[$i]}" "${SM_BRANCHES[$i]}")
"
    fi
    i=$((i + 1))
  done
  printf '\nPointer changes for %s:\n' "$SM_BASE" >&2
  git -C "$d" --no-pager diff --cached --submodule=log >&2
  git -C "$d" --no-pager diff --cached --stat >&2

  if [ "$push" -ne 1 ] && ! _sm_ask "Commit, push $SM_BR, and open a PR into $SM_BASE?"; then
    printf 'not pushed; the slot is reset\n' >&2
    _sm_result 0; return $?
  fi

  title="Update submodule pointers: $subj"
  git -C "$d" commit --quiet -m "$title" -m "$body" >&2 || {
    printf 'commit failed; nothing was pushed\n' >&2
    _sm_result 8; return $?
  }
  # The commit must hold exactly the selected gitlinks, whatever a hook did.
  want="$(printf '%s' "$want" | LC_ALL=C sort)"
  got="$(git -c core.quotePath=false -C "$d" diff-tree --no-commit-id --name-only -r HEAD | LC_ALL=C sort)"
  if [ "$got" != "$want" ]; then
    _sm_err "." "the commit contains files other than the selected gitlinks; nothing was pushed"
    _sm_result 8; return $?
  fi
  if ! GIT_TERMINAL_PROMPT=0 git -C "$d" push --quiet -u origin "$SM_BR" >&2; then
    printf 'push failed; the commit is discarded with the slot\n' >&2
    _sm_result 8; return $?
  fi
  SM_PUSHED=1
  printf 'pushed %s\n' "$SM_BR" >&2
  if command -v "${AGENTWS_GH:-gh}" >/dev/null 2>&1; then
    pr_out="$(cd "$d" && "${AGENTWS_GH:-gh}" pr create --base "$SM_BASE" --head "$SM_BR" \
      --title "$title" --body "$body" 2>&1 </dev/null)" || true
    pr_out="$(printf '%s\n' "$pr_out" | tail -1)"
    case "$pr_out" in
      http://*|https://*) SM_PR="$pr_out" ;;
      *) printf 'gh pr create failed: %s\n' "$pr_out" >&2 ;;
    esac
  fi
  if [ -n "$SM_PR" ]; then
    printf 'opened %s\n' "$SM_PR" >&2
  else
    printf 'Open a pull request from %s into %s on your forge.\n' "$SM_BR" "$SM_BASE" >&2
  fi
  _sm_result 0
}
