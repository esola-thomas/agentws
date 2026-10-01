# submodules.sh - update submodule pointers in a claimed slot and open a PR.
#
#   agentws submodules [--yes] [--push] [--dry-run] [--base BRANCH]
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

SM_PATHS=(); SM_NAMES=(); SM_BRANCHES=(); SM_CUR=(); SM_CAND=(); SM_COUNT=(); SM_SEL=()
SM_ERRS=()

_sm_ask() { # _sm_ask <question> -> 0 yes, 1 no
  local reply=""
  printf '%s [y/N] ' "$1" >&2
  IFS= read -r reply || { printf '\n' >&2; return 1; }
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

# Hand the slot back. A pushed branch lives on the remote, so recycle is safe
# right after the push. Gitlinks staged but not pushed are this command's own
# work: unstage them and put the submodules back first, or recycle would
# rightly refuse the slot. On failure the lock is kept and the user told.
_sm_recycle() { # _sm_recycle <slot> <branch> [slot-dir]
  if [ -n "${3:-}" ] && ! git -C "$3" diff --cached --quiet 2>/dev/null; then
    git -C "$3" reset --quiet >/dev/null 2>&1
    git -C "$3" submodule update --quiet --init --recursive >/dev/null 2>&1 || true
  fi
  if ! "$AGENTWS_BIN_DIR/agentws" --owner "$OWNER" recycle "$1" --branch "$2" >/dev/null 2>&1; then
    printf 'could not recycle slot %s; it stays locked. Run: agentws recycle %s\n' "$1" "$1" >&2
    return 8
  fi
}

cmd_submodules() {
  local push=0 base="$AGENTWS_DEFAULT_BRANCH" a claim_env slot d br i n sm name path
  local cur cand cnt nsel=0 title body subj pr_url="" pushed=0 cand_json=() rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --push) push=1; shift ;;
      --base) [ $# -ge 2 ] || { printf 'submodules: --base needs a branch\n' >&2; return 2; }
              base="$2"; shift 2 ;;
      *) printf 'submodules: unknown argument %s\n' "$1" >&2; return 2 ;;
    esac
  done
  br="agentws/submodules-$(date +%Y%m%d-%H%M%S)"

  # The lock lives exactly as long as this process unless the caller set a pid.
  claim_env="$(AGENTWS_PID="${AGENTWS_PID:-$$}" "$AGENTWS_BIN_DIR/agentws" --owner "$OWNER" \
    --branch "$br" claim "submodule pointer update" --print-env)" || return 5
  # claim quotes every value for eval; read them back in a subshell.
  slot="$(eval "$claim_env"; printf '%s' "${AGENTWS_SLOT:-}")"
  d="$(eval "$claim_env"; printf '%s' "${AGENTWS_WS:-}")"
  [ -n "$slot" ] && [ -d "$d" ] || { printf 'submodules: could not read the claimed slot\n' >&2; return 5; }
  printf 'working in slot %s (%s)\n' "$slot" "$d" >&2

  if ! git -C "$d" fetch --quiet origin >&2 \
     || ! git -C "$d" rev-parse --verify --quiet "origin/$base^{commit}" >/dev/null; then
    printf 'submodules: cannot fetch origin/%s in %s\n' "$base" "$d" >&2
    _sm_recycle "$slot" "$br" "$d"; return 8
  fi
  git -C "$d" checkout --quiet -b "$br" "origin/$base" >&2 || { _sm_recycle "$slot" "$br" "$d"; return 8; }
  if [ ! -f "$d/.gitmodules" ]; then
    printf 'no submodules in %s\n' "$base" >&2
    _sm_recycle "$slot" "$br" "$d"
    [ "${JSON:-0}" -eq 1 ] && printf '{"slot":%s,"base":%s,"candidates":[],"errors":[],"pushed":false}' \
      "$(jstr "$slot")" "$(jstr "$base")"
    return 0
  fi
  if ! GIT_TERMINAL_PROMPT=0 git -C "$d" submodule update --quiet --init --recursive >&2; then
    _sm_err "." "git submodule update --init --recursive failed"
  fi

  # Direct submodules of the managed repository, as "name<TAB>path".
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    name="${a%% *}"; path="${a#* }"
    name="${name#submodule.}"; name="${name%.path}"
    sm="$d/$path"
    cur="$(git -C "$d" ls-tree HEAD -- "$path" | awk '$2 == "commit" { print $3 }')"
    [ -n "$cur" ] || { _sm_err "$path" "no gitlink recorded in $base"; continue; }
    [ -e "$sm/.git" ] || { _sm_err "$path" "not initialised"; continue; }
    if ! a="$(_sm_tracking_branch "$d" "$name" "$sm" "$base")"; then
      _sm_err "$path" "cannot determine the tracking branch (no .gitmodules branch, remote HEAD unreadable)"
      continue
    fi
    if ! GIT_TERMINAL_PROMPT=0 git -C "$sm" fetch --quiet origin \
         "+refs/heads/$a:refs/remotes/origin/$a" 2>/dev/null; then
      _sm_err "$path" "git fetch of origin/$a failed"
      continue
    fi
    cand="$(git -C "$sm" rev-parse --verify --quiet "refs/remotes/origin/$a^{commit}")"
    [ "$cand" != "$cur" ] || { printf '  %s %s is current on %s\n' "$(c_dim OK)" "$path" "$a" >&2; continue; }
    if ! git -C "$sm" merge-base --is-ancestor "$cur" "$cand" 2>/dev/null; then
      _sm_err "$path" "origin/$a ($(printf '%.7s' "$cand")) does not descend from the recorded $(printf '%.7s' "$cur"); skipped"
      continue
    fi
    cnt="$(git -C "$sm" rev-list --count "$cur..$cand")"
    SM_PATHS+=("$path"); SM_NAMES+=("$name"); SM_BRANCHES+=("$a")
    SM_CUR+=("$cur"); SM_CAND+=("$cand"); SM_COUNT+=("$cnt"); SM_SEL+=(0)
  done <<EOF
$(git -C "$d" config -f "$d/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null)
EOF

  n=${#SM_PATHS[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    path="${SM_PATHS[$i]}"; sm="$d/$path"
    printf '\n%s  %.7s -> %.7s  (%s commits on %s)\n' "$path" "${SM_CUR[$i]}" "${SM_CAND[$i]}" \
      "${SM_COUNT[$i]}" "${SM_BRANCHES[$i]}" >&2
    git -C "$sm" log --oneline --no-decorate -n 10 "${SM_CUR[$i]}..${SM_CAND[$i]}" 2>/dev/null \
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
  elif [ "${DRY:-0}" -eq 1 ]; then
    printf '\ndry run: %s candidate(s), nothing changed\n' "$n" >&2
  elif [ "$nsel" -eq 0 ]; then
    printf '\nnothing selected\n' >&2
  fi

  if [ "${DRY:-0}" -ne 1 ] && [ "$nsel" -gt 0 ]; then
    i=0; subj=""; body=""
    while [ "$i" -lt "$n" ]; do
      if [ "${SM_SEL[$i]}" = 1 ]; then
        path="${SM_PATHS[$i]}"
        git -C "$d/$path" checkout --quiet --detach "${SM_CAND[$i]}" >&2 \
          && git -C "$d" add -- "$path" \
          || { _sm_err "$path" "could not move to ${SM_CAND[$i]}"; rc=8; }
        subj="${subj:+$subj, }$path"
        body="${body}$(printf -- '- %s: %.7s..%.7s (%s commits on %s)' "$path" "${SM_CUR[$i]}" \
          "${SM_CAND[$i]}" "${SM_COUNT[$i]}" "${SM_BRANCHES[$i]}")
"
      fi
      i=$((i + 1))
    done
    if [ "$rc" -ne 0 ]; then
      _sm_recycle "$slot" "$br" "$d"; return "$rc"
    fi
    printf '\nPointer changes for %s:\n' "$base" >&2
    git -C "$d" --no-pager diff --cached --submodule=log >&2
    git -C "$d" --no-pager diff --cached --stat >&2

    if [ "$push" -eq 1 ] || _sm_ask "Commit, push $br, and open a PR into $base?"; then
      title="Update submodule pointers: $subj"
      if git -C "$d" commit --quiet -m "$title" -m "$body" >&2 \
         && GIT_TERMINAL_PROMPT=0 git -C "$d" push --quiet -u origin "$br" >&2; then
        pushed=1
        printf 'pushed %s\n' "$br" >&2
        if command -v "${AGENTWS_GH:-gh}" >/dev/null 2>&1; then
          pr_url="$(cd "$d" && "${AGENTWS_GH:-gh}" pr create --base "$base" --head "$br" \
            --title "$title" --body "$body" 2>/dev/null | tail -1)" || pr_url=""
        fi
        if [ -n "$pr_url" ]; then
          printf 'opened %s\n' "$pr_url" >&2
        else
          printf 'Open a pull request from %s into %s on your forge.\n' "$br" "$base" >&2
        fi
      else
        printf 'commit or push failed; nothing was pushed\n' >&2
        rc=8
      fi
    else
      printf 'not pushed; the slot is reset\n' >&2
    fi
  fi

  _sm_recycle "$slot" "$br" "$d" || rc=8

  if [ "${JSON:-0}" -eq 1 ]; then
    i=0
    while [ "$i" -lt "$n" ]; do
      cand_json+=("$(printf '{"path":%s,"name":%s,"branch":%s,"current":%s,"candidate":%s,"commits":%s,"selected":%s}' \
        "$(jstr "${SM_PATHS[$i]}")" "$(jstr "${SM_NAMES[$i]}")" "$(jstr "${SM_BRANCHES[$i]}")" \
        "$(jstr "${SM_CUR[$i]}")" "$(jstr "${SM_CAND[$i]}")" "$(jnum "${SM_COUNT[$i]}")" \
        "$(jbool "${SM_SEL[$i]}")")")
      i=$((i + 1))
    done
    printf '{"slot":%s,"base":%s,"branch":%s,"dry_run":%s,"candidates":[%s],"errors":[%s],"pushed":%s,"pr_url":%s}' \
      "$(jstr "$slot")" "$(jstr "$base")" "$(jstr "$br")" "$(jbool "${DRY:-0}")" \
      "$(jjoin "${cand_json[@]+"${cand_json[@]}"}")" "$(jjoin "${SM_ERRS[@]+"${SM_ERRS[@]}"}")" \
      "$(jbool "$pushed")" "$(if [ -n "$pr_url" ]; then jstr "$pr_url"; else printf null; fi)"
  fi
  return "$rc"
}
