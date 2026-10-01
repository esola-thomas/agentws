#!/usr/bin/env bats
# submodules.bats - agentws submodules: pointer updates in a claimed slot.
#
# Every remote is a local bare repository. `gh` is replaced through AGENTWS_GH
# by a stub that logs its argv, so no test reaches a forge.

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-sm.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/home/.config" XDG_STATE_HOME="$SANDBOX/home/.state"
  export AGENTWS_NO_AUTO_UPDATE=1 AGENTWS_OWNER=tester
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
  mkdir -p "$HOME"
  git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
  git config --file "$GIT_CONFIG_GLOBAL" user.name tester
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
  unset AGENTWS_CONFIG AGENTWS_ROOT AGENTWS_PID

  R="$SANDBOX/remotes"
  mkdir -p "$R"
  make_remote n
  make_remote a
  make_remote b
  # b carries a nested submodule n.
  git -C "$SANDBOX/wb" submodule add -q "$R/n.git" n
  git -C "$SANDBOX/wb" commit -q -m "add n"
  git -C "$SANDBOX/wb" push -q origin main

  git init -q --bare "$R/parent.git"
  git clone -q "$R/parent.git" "$SANDBOX/wp"
  git -C "$SANDBOX/wp" commit -q --allow-empty -m init
  git -C "$SANDBOX/wp" submodule add -q "$R/a.git" a
  git -C "$SANDBOX/wp" submodule add -q "$R/b.git" b
  git -C "$SANDBOX/wp" commit -q -m "add submodules"
  git -C "$SANDBOX/wp" push -q origin main

  git clone -q "$R/parent.git" "$SANDBOX/src"
  CONFIG="$SANDBOX/ws/.agentws.yml"
  mkdir -p "$SANDBOX/ws"
  cat > "$CONFIG" <<EOF
version: 1
root: $SANDBOX/ws
top: p
provider: worktree
default_branch: main
slots: [1, 2]
ttl_hours: 1
lock_dir: "{root}/.agentws/locks"
provider_opts:
  source_repo: $SANDBOX/src
EOF
  export AGENTWS_CONFIG="$CONFIG"
  agentws create 1 >/dev/null 2>&1
  agentws create 2 >/dev/null 2>&1

  STUBS="$SANDBOX/stubs"
  mkdir -p "$STUBS"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/gh.log"\necho https://example.invalid/pr/1\n' "$SANDBOX" > "$STUBS/gh"
  chmod +x "$STUBS/gh"
  export AGENTWS_GH="$STUBS/gh"
}
teardown() { teardown_sandbox; }

make_remote() { # make_remote <name>: bare repo with one commit on main
  git init -q --bare "$R/$1.git"
  git clone -q "$R/$1.git" "$SANDBOX/w$1"
  git -C "$SANDBOX/w$1" commit -q --allow-empty -m "$1 init"
  git -C "$SANDBOX/w$1" push -q origin main
}

advance() { # advance <name> [count]: new commits on the remote's main
  local i
  git -C "$SANDBOX/w$1" pull -q origin main
  for i in $(seq 1 "${2:-1}"); do
    git -C "$SANDBOX/w$1" commit -q --allow-empty -m "$1 change $i"
  done
  git -C "$SANDBOX/w$1" push -q origin main
}

head_of() { git -C "$R/$1.git" rev-parse main; }
pushed_branch() { git -C "$R/parent.git" for-each-ref --format='%(refname:short)' 'refs/heads/agentws/*'; }
gitlink() { git -C "$R/parent.git" ls-tree "$1" -- "$2" | awk '{print $3}'; }
slot_free() { [ "$(agentws status --json | jq -r --arg s "$1" '.data.slots[] | select(.slot==$s) | .claimable')" = true ]; }

@test "dry run lists candidates and changes nothing" {
  advance a 2
  run agentws submodules --dry-run --json
  [ "$status" -eq 0 ]
  local env; env="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$env" | jq -r '.data.candidates | map(.path) | join(",")')" = a ]
  [ "$(printf '%s' "$env" | jq -r '.data.candidates[0].commits')" -eq 2 ]
  [ "$(printf '%s' "$env" | jq -r '.data.pushed')" = false ]
  [ -z "$(pushed_branch)" ]
  slot_free 1
}

@test "--yes --push commits only the selected gitlinks, pushes, and opens a PR" {
  advance a 3
  local before_b; before_b="$(gitlink main b)"
  run agentws submodules --yes --push
  [ "$status" -eq 0 ]
  local br; br="$(pushed_branch)"
  [ -n "$br" ]
  [ "$(gitlink "$br" a)" = "$(head_of a)" ]
  [ "$(gitlink "$br" b)" = "$before_b" ]
  [ "$(git -C "$R/parent.git" diff --name-only main "$br")" = a ]
  grep -q -- "pr create --base main --head $br" "$SANDBOX/gh.log"
  [[ "$output" == *"https://example.invalid/pr/1"* ]]
  slot_free 1
  [ -z "$(ls "$SANDBOX/ws/.agentws/locks" 2>/dev/null)" ]
}

@test "without gh the branch is pushed and the user is told to open the PR" {
  advance a
  AGENTWS_GH="$SANDBOX/no-such-gh" run agentws submodules --yes --push
  [ "$status" -eq 0 ]
  [ -n "$(pushed_branch)" ]
  [[ "$output" == *"Open a pull request from agentws/submodules-"* ]]
}

@test "--yes still asks before pushing; no answer means nothing is pushed" {
  advance a
  run agentws submodules --yes < /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"Commit, push"* ]]
  [[ "$output" == *"not pushed"* ]]
  [ -z "$(pushed_branch)" ]
  slot_free 1
}

@test "per-submodule answers select candidates, and the final answer gates the push" {
  advance a; advance b
  # a: yes, b: no, push: yes
  run bash -c "printf 'y\nn\ny\n' | '$AGENTWS_BIN' submodules"
  [ "$status" -eq 0 ]
  local br; br="$(pushed_branch)"
  [ -n "$br" ]
  [ "$(git -C "$R/parent.git" diff --name-only main "$br")" = a ]

  # Declining everything makes no branch at all.
  git -C "$R/parent.git" branch -D "$br" >/dev/null
  run bash -c "printf 'n\nn\n' | '$AGENTWS_BIN' submodules"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing selected"* ]]
  [ -z "$(pushed_branch)" ]
}

@test "a submodule that does not fast-forward is reported, not changed" {
  advance a
  # Rewrite b's main with unrelated history.
  rm -rf "$SANDBOX/wb2"; mkdir "$SANDBOX/wb2"
  git -C "$SANDBOX/wb2" init -q
  git -C "$SANDBOX/wb2" commit -q --allow-empty -m rewritten
  git -C "$SANDBOX/wb2" push -q --force "$R/b.git" HEAD:main
  run agentws submodules --yes --push --json
  [ "$status" -eq 0 ]
  local env br; env="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$env" | jq -r '.data.errors[0].path')" = b ]
  [[ "$(printf '%s' "$env" | jq -r '.data.errors[0].message')" == *"does not descend"* ]]
  br="$(pushed_branch)"
  [ "$(git -C "$R/parent.git" diff --name-only main "$br")" = a ]
}

@test "a missing tracking branch is reported and leaves that pointer alone" {
  advance b
  git -C "$SANDBOX/wp" config -f .gitmodules submodule.a.branch no-such-branch
  git -C "$SANDBOX/wp" commit -q -am "track a missing branch"
  git -C "$SANDBOX/wp" push -q origin main
  run agentws submodules --yes --push --json
  [ "$status" -eq 0 ]
  local env; env="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$env" | jq -r '.data.errors[0].path')" = a ]
  [[ "$(printf '%s' "$env" | jq -r '.data.errors[0].message')" == *"origin/no-such-branch failed"* ]]
  [ "$(git -C "$R/parent.git" diff --name-only main "$(pushed_branch)")" = b ]
  slot_free 1
}

@test "a pushed run whose slot cannot be recycled still reports the push" {
  advance b
  mv "$R/a.git" "$R/a.gone"
  run agentws submodules --yes --push --json
  [ "$status" -eq 0 ]
  local env; env="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$env" | jq -r '.data.pushed')" = true ]
  [ "$(printf '%s' "$env" | jq -r '.data.recycled')" = false ]
  [[ "$output" == *"a: not initialised"* ]]
  [[ "$output" == *"Run: agentws --owner 'tester' recycle 1"* ]]
}

@test "interrupting at a prompt hands the slot back" {
  advance a
  run bash -c "sleep 30 | timeout -s TERM 3 '$AGENTWS_BIN' submodules"
  [ "$status" -ne 0 ]
  [[ "$output" == *"interrupted"* ]]
  [ -z "$(pushed_branch)" ]
  slot_free 1
  [ -z "$(git -C "$SANDBOX/src" for-each-ref 'refs/heads/agentws/*')" ]
}

@test "--json refuses to prompt and claims nothing" {
  advance a
  run agentws submodules --yes --json
  [ "$status" -eq 2 ]
  [[ "$output" == *"--json cannot prompt"* ]]
  slot_free 1; slot_free 2
}

@test "a submodule path with a space is handled" {
  make_remote c
  git -C "$SANDBOX/wp" submodule add -q "$R/c.git" "my mod"
  git -C "$SANDBOX/wp" commit -q -m "add my mod"
  git -C "$SANDBOX/wp" push -q origin main
  advance c
  run agentws submodules --yes --push
  [ "$status" -eq 0 ]
  [ "$(git -C "$R/parent.git" diff --name-only main "$(pushed_branch)")" = "my mod" ]
}

@test "a commit that gains other files is never pushed" {
  advance a
  mkdir -p "$SANDBOX/hooks"
  printf '#!/bin/sh
echo extra > extra.txt
git add extra.txt
' > "$SANDBOX/hooks/pre-commit"
  chmod +x "$SANDBOX/hooks/pre-commit"
  git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$SANDBOX/hooks"
  run agentws submodules --yes --push
  [ "$status" -ne 0 ]
  [[ "$output" == *"other than the selected gitlinks"* ]]
  [ -z "$(pushed_branch)" ]
  slot_free 1
}

@test "--base branches from and targets another branch; branch = . follows it" {
  git -C "$SANDBOX/wp" checkout -q -b develop
  git -C "$SANDBOX/wp" config -f .gitmodules submodule.a.branch .
  git -C "$SANDBOX/wp" commit -q -am "a follows the superproject branch"
  git -C "$SANDBOX/wp" push -q origin develop
  git -C "$SANDBOX/wa" checkout -q -b develop
  git -C "$SANDBOX/wa" commit -q --allow-empty -m "a on develop"
  git -C "$SANDBOX/wa" push -q origin develop
  run agentws submodules --base develop --yes --push --json
  [ "$status" -eq 0 ]
  local env br; env="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$env" | jq -r '.data.candidates[0].branch')" = develop ]
  br="$(pushed_branch)"
  [ "$(git -C "$R/parent.git" merge-base develop "$br")" = "$(git -C "$R/parent.git" rev-parse develop)" ]
  [ "$(gitlink "$br" a)" = "$(git -C "$R/a.git" rev-parse develop)" ]
  grep -q -- "--base develop" "$SANDBOX/gh.log"
}

@test "every JSON result has the same keys" {
  run agentws submodules --dry-run --json
  local keys; keys="$(printf '%s\n' "$output" | tail -1 | jq -c '.data | keys')"
  [ "$keys" = '["base","branch","candidates","dry_run","errors","pr_url","pushed","recycled","slot"]' ]
}

@test "nested submodules are checked out but only direct gitlinks are candidates" {
  advance n
  run agentws submodules --dry-run --json
  [ "$status" -eq 0 ]
  local env; env="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$env" | jq -r '.data.candidates | length')" -eq 0 ]
  [ "$(printf '%s' "$env" | jq -r '.data.errors | length')" -eq 0 ]
}

@test "no candidates means no branch and the slot is handed back" {
  run agentws submodules --yes --push
  [ "$status" -eq 0 ]
  [[ "$output" == *"no submodule has a newer commit"* ]]
  [ -z "$(pushed_branch)" ]
  slot_free 1
}

@test "a tracking branch from .gitmodules is honoured" {
  git -C "$SANDBOX/wa" checkout -q -b release
  git -C "$SANDBOX/wa" commit -q --allow-empty -m "on release"
  git -C "$SANDBOX/wa" push -q origin release
  git -C "$SANDBOX/wp" config -f .gitmodules submodule.a.branch release
  git -C "$SANDBOX/wp" commit -q -am "track release"
  git -C "$SANDBOX/wp" push -q origin main
  run agentws submodules --dry-run --json
  local env; env="$(printf '%s\n' "$output" | tail -1)"
  [ "$(printf '%s' "$env" | jq -r '.data.candidates[0].branch')" = release ]
}

# A git that pauses on the call matching $SLOW_GIT_MATCH, after dropping a
# marker, so a test can signal at a known point.
slow_git() { # slow_git <pattern>
  local real; real="$(command -v git)"
  printf '#!/bin/sh\ncase "$*" in *"%s"*) : > "%s/paused"; sleep 4 ;; esac\nexec "%s" "$@"\n' \
    "$1" "$SANDBOX" "$real" > "$STUBS/git"
  chmod +x "$STUBS/git"
}

# Run agentws in its own process group, wait for the pause, signal the group.
# TERM stands in for Ctrl-C: a background job here starts with SIGINT ignored,
# and the command traps INT, TERM, and HUP alike.
signal_at_pause() { # signal_at_pause <SIG> <agentws args...>
  local sig="$1" pid i; shift
  command -v setsid >/dev/null 2>&1 || skip "needs setsid (util-linux)"
  PATH="$STUBS:$PATH" setsid "$AGENTWS_BIN" "$@" >"$SANDBOX/out" 2>"$SANDBOX/err" </dev/null &
  pid=$!
  for i in $(seq 1 100); do [ -e "$SANDBOX/paused" ] && break; sleep 0.1; done
  [ -e "$SANDBOX/paused" ] || return 99
  kill -"$sig" -- -"$pid" 2>/dev/null
  wait "$pid"
}

@test "a non-ASCII submodule path is pushed" {
  make_remote c
  git -C "$SANDBOX/wp" submodule add -q "$R/c.git" "módulo"
  git -C "$SANDBOX/wp" commit -q -m "add módulo"
  git -C "$SANDBOX/wp" push -q origin main
  advance c
  run agentws submodules --yes --push
  [ "$status" -eq 0 ]
  [ -n "$(pushed_branch)" ]
}

@test "a signal during the final recycle does not strand the slot" {
  advance a
  slow_git "fetch origin --prune"
  run signal_at_pause TERM submodules --yes --push
  [ -n "$(pushed_branch)" ]
  slot_free 1
}

@test "an interrupt under --json still prints an envelope and frees the slot" {
  advance a
  slow_git "+refs/heads/main:refs/remotes/origin/main"
  run signal_at_pause TERM submodules --dry-run --json
  [ "$status" -eq 130 ]
  [ "$(tail -1 "$SANDBOX/out" | jq -r .error.code)" = EINTR ]
  slot_free 1
  [ -z "$(git -C "$SANDBOX/src" for-each-ref 'refs/heads/agentws/*')" ]
}
