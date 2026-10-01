#!/usr/bin/env bats
# onboarding.bats - init, use, setup, hook, install.sh, and self-update.
#
# HOME is a sandbox and the harness CLIs are stubs that log their argv, so no
# test touches a real agent configuration or the network.

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-onb.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$HOME/.config" XDG_STATE_HOME="$HOME/.local/state"
  export AGENTWS_NO_AUTO_UPDATE=1
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
  git config --file "$GIT_CONFIG_GLOBAL" user.name tester
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
  unset AGENTWS_CONFIG AGENTWS_ROOT AGENTWS_PID AGENTWS_OWNER
  mkdir -p "$HOME"
  STUBS="$SANDBOX/stubs"
  mkdir -p "$STUBS"
  export PATH="$STUBS:$PATH"
}
teardown() { teardown_sandbox; }

make_repo() { # make_repo <dir>
  mkdir -p "$1"
  git -C "$1" init -q
  : > "$1/README"
  git -C "$1" add README
  git -C "$1" commit -q -m init
}

stub() { # stub <name>: a CLI that appends its argv to $SANDBOX/<name>.log
  printf '#!/bin/sh\necho "$*" >> "%s/%s.log"\n' "$SANDBOX" "$1" > "$STUBS/$1"
  chmod +x "$STUBS/$1"
}

# ---------------------------------------------------------------------- init

@test "init turns a checkout into a farm beside it and makes it the default" {
  make_repo "$SANDBOX/proj"
  cd "$SANDBOX/proj"
  run agentws init --slots 2
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/proj-ws/.agentws.yml" ]
  [ -e "$SANDBOX/proj-ws/1_proj/.git" ]
  [ -e "$SANDBOX/proj-ws/2_proj/.git" ]
  [ -L "$XDG_CONFIG_HOME/agentws/default.yml" ]

  # Found from an unrelated directory through the default pointer.
  cd /
  run agentws status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots | length')" -eq 2 ]
}

@test "init refuses outside a git checkout and over an existing farm" {
  mkdir -p "$SANDBOX/plain"
  cd "$SANDBOX/plain"
  run agentws init
  [ "$status" -ne 0 ]
  [[ "$output" == *"not inside a git checkout"* ]]

  make_repo "$SANDBOX/proj"
  cd "$SANDBOX/proj"
  agentws init --slots 1 >/dev/null 2>&1
  run agentws init --slots 1
  [ "$status" -ne 0 ]
  [[ "$output" == *"already exists"* ]]
}

@test "a second farm does not steal the default; use switches it" {
  make_repo "$SANDBOX/a"; make_repo "$SANDBOX/b"
  (cd "$SANDBOX/a" && agentws init --slots 1 >/dev/null 2>&1)
  (cd "$SANDBOX/b" && agentws init --slots 1 >/dev/null 2>&1)
  [ "$(readlink "$XDG_CONFIG_HOME/agentws/default.yml")" = "$SANDBOX/a-ws/.agentws.yml" ]
  run agentws use "$SANDBOX/b-ws"
  [ "$status" -eq 0 ]
  [ "$(readlink "$XDG_CONFIG_HOME/agentws/default.yml")" = "$SANDBOX/b-ws/.agentws.yml" ]
}

# ---------------------------------------------------------------------- hook

@test "hook session-start is silent with exit 0 when there is no farm" {
  cd "$SANDBOX"
  run agentws hook session-start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hook session-start shows the farm when one exists" {
  make_repo "$SANDBOX/proj"
  (cd "$SANDBOX/proj" && agentws init --slots 1 >/dev/null 2>&1)
  cd "$SANDBOX"
  run agentws hook session-start
  [ "$status" -eq 0 ]
  [[ "$output" == *"agentws farm"* ]]
  [[ "$output" == *"1_proj"* ]]
}

# --------------------------------------------------------------------- setup

@test "setup wires every detected harness and is idempotent" {
  stub claude; stub codex
  mkdir -p "$HOME/.copilot" "$HOME/.cursor" "$HOME/.gemini"
  printf '{"theme":"dark"}\n' > "$HOME/.gemini/settings.json"

  run agentws setup
  [ "$status" -eq 0 ]
  run agentws setup
  [ "$status" -eq 0 ]

  grep -q "mcp add agentws --scope user --env AGENTWS_OWNER_PREFIX=claude -- .*/mcp/agentws-mcp" "$SANDBOX/claude.log"
  grep -q "mcp add agentws --env AGENTWS_OWNER_PREFIX=codex -- .*/mcp/agentws-mcp" "$SANDBOX/codex.log"
  [ "$(jq -r '.mcpServers.agentws.type' "$HOME/.copilot/mcp-config.json")" = local ]
  [ "$(jq -r '.mcpServers.agentws.type' "$HOME/.cursor/mcp.json")" = stdio ]
  [ "$(jq -r '.mcpServers.agentws.env.AGENTWS_OWNER_PREFIX' "$HOME/.gemini/settings.json")" = gemini ]
  [ "$(jq -r '.theme' "$HOME/.gemini/settings.json")" = dark ]
  [ -L "$HOME/.claude/skills/agentws" ]
  [ -f "$HOME/.agents/skills/agentws/SKILL.md" ]
  # Two runs, one hook.
  [ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("agentws hook session-start"))] | length' \
        "$HOME/.claude/settings.json")" -eq 1 ]
}

@test "setup --remove undoes the wiring and keeps unrelated hooks" {
  stub claude
  mkdir -p "$HOME/.claude"
  printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}\n' \
    > "$HOME/.claude/settings.json"
  agentws setup claude >/dev/null 2>&1
  run agentws setup claude --remove
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.claude/skills/agentws" ]
  [ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOME/.claude/settings.json")" = "echo mine" ]
  [ "$(jq '.hooks.SessionStart | length' "$HOME/.claude/settings.json")" -eq 1 ]
  grep -q "mcp remove --scope user agentws" "$SANDBOX/claude.log"
}

@test "setup rejects an unknown harness" {
  run agentws setup vim
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown harness"* ]]
}

# ------------------------------------------------------- install and update

# A local "origin" standing in for GitHub: a clone of this checkout's HEAD.
make_origin() {
  ORIGIN="$SANDBOX/origin"
  git clone -q "$AGENTWS_REPO_ROOT" "$ORIGIN"
  # Carry uncommitted work under test (staged, unstaged, or new) into the
  # origin. .claude/ is harness state, not source.
  (cd "$AGENTWS_REPO_ROOT" && {
     git diff -z --name-only --diff-filter=d HEAD
     git ls-files -z -o --exclude-standard -- . ':!.claude'
   } | xargs -0 -I{} cp --parents {} "$ORIGIN/") 2>/dev/null || true
  git -C "$ORIGIN" add -A && git -C "$ORIGIN" commit -q -m wip --allow-empty
  git -C "$ORIGIN" checkout -q -B main
}

piped_install() {
  AGENTWS_REPO="$ORIGIN" AGENTWS_PREFIX="$HOME/bin" bash -s -- --no-setup < "$AGENTWS_REPO_ROOT/install.sh"
}

@test "piped install makes a managed clone and links it" {
  make_origin
  run piped_install
  [ "$status" -eq 0 ]
  [ -f "$HOME/.local/share/agentws/.git/agentws-managed" ]
  [ -L "$HOME/bin/agentws" ]
  run "$HOME/bin/agentws" version --json
  [ "$(printf '%s' "$output" | jq -r '.data.managed')" = true ]
}

@test "update follows new releases and never downgrades" {
  make_origin
  git -C "$ORIGIN" tag v9.0.0
  piped_install >/dev/null 2>&1
  local home="$HOME/.local/share/agentws" before
  before="$(git -C "$home" rev-parse HEAD)"
  [ "$before" = "$(git -C "$ORIGIN" rev-parse v9.0.0)" ]

  git -C "$ORIGIN" commit -q --allow-empty -m next
  git -C "$ORIGIN" tag v9.1.0
  run "$HOME/bin/agentws" update
  [ "$status" -eq 0 ]
  [ "$(git -C "$home" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.1.0)" ]

  # The newest tag on an older commit would be a downgrade: not taken.
  git -C "$ORIGIN" tag v9.2.0 "$before"
  run "$HOME/bin/agentws" update
  [ "$(git -C "$home" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.1.0)" ]
}

@test "update --check reports without moving" {
  make_origin
  git -C "$ORIGIN" tag v9.0.0
  piped_install >/dev/null 2>&1
  git -C "$ORIGIN" commit -q --allow-empty -m next
  git -C "$ORIGIN" tag v9.1.0
  run "$HOME/bin/agentws" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"update available"* ]]
  [ "$(git -C "$HOME/.local/share/agentws" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.0.0)" ]
}

@test "update refuses a dirty managed install" {
  make_origin
  piped_install >/dev/null 2>&1
  printf 'x\n' >> "$HOME/.local/share/agentws/README.md"
  run "$HOME/bin/agentws" update
  [ "$status" -ne 0 ]
  [[ "$output" == *"local changes"* ]]
}

@test "a development checkout is never updated" {
  run agentws update
  [ "$status" -eq 0 ]
  [[ "$output" == *"development checkout"* ]]
}

@test "any command triggers a once-a-day background update" {
  make_origin
  git -C "$ORIGIN" tag v9.0.0
  piped_install >/dev/null 2>&1
  git -C "$ORIGIN" commit -q --allow-empty -m next
  git -C "$ORIGIN" tag v9.1.0
  local home="$HOME/.local/share/agentws" i
  unset AGENTWS_NO_AUTO_UPDATE

  # Piped through cat: the detached check must not hold the pipe open.
  run bash -c "timeout 10 '$HOME/bin/agentws' version | cat"
  [ "$status" -eq 0 ]
  [ -f "$XDG_STATE_HOME/agentws/last-check" ]
  for i in $(seq 1 50); do
    [ "$(git -C "$home" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.1.0)" ] && break
    sleep 0.2
  done
  [ "$(git -C "$home" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.1.0)" ]

  # Within the interval, a newer release is not picked up.
  git -C "$ORIGIN" commit -q --allow-empty -m later
  git -C "$ORIGIN" tag v9.2.0
  "$HOME/bin/agentws" version >/dev/null
  sleep 1
  [ "$(git -C "$home" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.1.0)" ]
}
