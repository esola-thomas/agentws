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
  unset AGENTWS_CONFIG AGENTWS_ROOT AGENTWS_PID AGENTWS_OWNER AGENTWS_SETUP_BASH_CANDIDATES CODEX_HOME
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
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}

stub() { # stub <name>: a CLI that appends its argv to $SANDBOX/<name>.log
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/%s.log"\n' "$SANDBOX" "$1" > "$STUBS/$1"
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
  stub claude; stub codex; stub copilot; stub cursor-agent; stub gemini
  mkdir -p "$HOME/.gemini"
  printf '{"theme":"dark"}\n' > "$HOME/.gemini/settings.json"

  run agentws setup
  [ "$status" -eq 0 ]
  run agentws setup
  [ "$status" -eq 0 ]

  # The server always runs under an absolute bash, even when PATH bash is fine.
  local b mcp="$AGENTWS_REPO_ROOT/mcp/agentws-mcp"
  b="$(command -v bash)"
  grep -qF -- "mcp add agentws --scope user --env AGENTWS_OWNER_PREFIX=claude -- $b $mcp" "$SANDBOX/claude.log"
  grep -qF -- "mcp add agentws --env AGENTWS_OWNER_PREFIX=codex -- $b $mcp" "$SANDBOX/codex.log"
  [ "$(jq -r '.mcpServers.agentws.type' "$HOME/.copilot/mcp-config.json")" = local ]
  [ "$(jq -r '.mcpServers.agentws.type' "$HOME/.cursor/mcp.json")" = stdio ]
  [ "$(jq -r '.mcpServers.agentws.command' "$HOME/.cursor/mcp.json")" = "$b" ]
  [ "$(jq -r '.mcpServers.agentws.args[0]' "$HOME/.cursor/mcp.json")" = "$mcp" ]
  [ "$(jq -r '.mcpServers.agentws.env.AGENTWS_OWNER_PREFIX' "$HOME/.gemini/settings.json")" = gemini ]
  [ "$(jq -r '.theme' "$HOME/.gemini/settings.json")" = dark ]
  [ -L "$HOME/.claude/skills/agentws" ]
  [ -f "$HOME/.agents/skills/agentws/SKILL.md" ]
  # Two runs, one hook.
  [ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("hook session-start"))] | length' \
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

@test "setup detects a harness by its command, not its config dir" {
  stub gemini
  mkdir -p "$HOME/.codex" "$HOME/.copilot" "$HOME/.claude"
  PATH="$STUBS:/usr/bin:/bin" run agentws setup
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcpServers.agentws.env.AGENTWS_OWNER_PREFIX' "$HOME/.gemini/settings.json")" = gemini ]
  [ ! -e "$HOME/.copilot/mcp-config.json" ]
  [ ! -e "$HOME/.cursor/mcp.json" ]
  [[ "$output" != *codex* ]]
  [[ "$output" != *claude* ]]

  # Named explicitly, a harness is wired without its command.
  PATH="$STUBS:/usr/bin:/bin" run agentws setup copilot
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcpServers.agentws.type' "$HOME/.copilot/mcp-config.json")" = local ]
}

@test "setup detects Cursor by cursor-agent or by ~/.cursor" {
  stub cursor-agent
  PATH="$STUBS:/usr/bin:/bin" run agentws setup
  [ "$(jq -r '.mcpServers.agentws.type' "$HOME/.cursor/mcp.json")" = stdio ]
  rm -f "$STUBS/cursor-agent" "$HOME/.cursor/mcp.json"
  PATH="$STUBS:/usr/bin:/bin" run agentws setup
  [ "$status" -eq 0 ]
  [ "$(jq -r '.mcpServers.agentws.type' "$HOME/.cursor/mcp.json")" = stdio ]
}

@test "setup --refresh relinks wired skills whatever is on PATH" {
  mkdir -p "$HOME/.agents/skills"
  ln -s "$SANDBOX/old/skills/agentws" "$HOME/.agents/skills/agentws"
  PATH="$STUBS:/usr/bin:/bin" run agentws setup --refresh
  [ "$status" -eq 0 ]
  [ "$(readlink "$HOME/.agents/skills/agentws")" = "$AGENTWS_REPO_ROOT/skills/agentws" ]
}

fake_bash() { # fake_bash <path> <major> <minor> <version>: reports a bash version
  mkdir -p "$(dirname "$1")"
  printf '#!/bin/sh\nprintf "%%s" "%s %s %s"\n' "$2" "$3" "$4" > "$1"
  chmod +x "$1"
}

@test "setup skips MCP without bash 4.1 but links the skill and hook" {
  stub claude
  fake_bash "$SANDBOX/old/bash" 3 2 "3.2.57(1)-release"
  export AGENTWS_SETUP_BASH_CANDIDATES="$SANDBOX/missing/bash:$SANDBOX/old/bash"
  run agentws setup claude gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"MCP server needs bash 4.1+ (found 3.2.57(1)-release)"* ]]
  [[ "$output" == *"brew install bash"* ]]
  [ ! -e "$SANDBOX/claude.log" ]
  [ ! -e "$HOME/.gemini/settings.json" ]
  [ -L "$HOME/.claude/skills/agentws" ]
  [ -L "$HOME/.agents/skills/agentws" ]
  [ "$(jq '.hooks.SessionStart | length' "$HOME/.claude/settings.json")" -eq 1 ]

  # A registration left from before is reported as unusable.
  printf '{"mcpServers":{"agentws":{"command":"x"}}}\n' > "$HOME/.claude.json"
  run agentws setup claude --check
  [[ "$output" == *"mcp:no "* ]]
}

@test "setup runs the server with an absolute bash when PATH bash is too old" {
  stub claude; stub codex
  fake_bash "$SANDBOX/old/bash" 3 2 "3.2.57(1)-release"
  fake_bash "$SANDBOX/my brew/bin/bash" 5 2 "5.2.37(1)-release"
  export AGENTWS_SETUP_BASH_CANDIDATES="$SANDBOX/old/bash:$SANDBOX/my brew/bin/bash"
  run agentws setup claude codex gemini
  [ "$status" -eq 0 ]
  [[ "$output" != *"needs bash"* ]]
  local mcp="$AGENTWS_REPO_ROOT/mcp/agentws-mcp"
  grep -qF -- "--env AGENTWS_OWNER_PREFIX=claude -- $SANDBOX/my brew/bin/bash $mcp" "$SANDBOX/claude.log"
  grep -qF -- "--env AGENTWS_OWNER_PREFIX=codex -- $SANDBOX/my brew/bin/bash $mcp" "$SANDBOX/codex.log"
  [ "$(jq -r '.mcpServers.agentws.command' "$HOME/.gemini/settings.json")" = "$SANDBOX/my brew/bin/bash" ]
  [ "$(jq -r '.mcpServers.agentws.args[0]' "$HOME/.gemini/settings.json")" = "$mcp" ]
}

@test "setup --check reports an entry that does not run under bash 4.1+ as stale" {
  local nb="$SANDBOX/nb/bash" mcp="$AGENTWS_REPO_ROOT/mcp/agentws-mcp"
  fake_bash "$nb" 5 2 "5.2.37(1)-release"
  export AGENTWS_SETUP_BASH_CANDIDATES="$nb"
  mkdir -p "$HOME/.codex" "$HOME/.gemini"

  # Shebang-style entries from before: they hit whatever bash is on PATH.
  jq -n --arg c "$mcp" '{mcpServers:{agentws:{command:$c, args:[]}}}' > "$HOME/.claude.json"
  printf '[mcp_servers.agentws]\ncommand = "%s"\nargs = []\n' "$mcp" > "$HOME/.codex/config.toml"
  jq -n --arg c "$mcp" '{mcpServers:{agentws:{command:$c, args:[]}}}' > "$HOME/.gemini/settings.json"
  run agentws setup claude codex gemini --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"claude   mcp:stale"* ]]
  [[ "$output" == *"codex    mcp:stale"* ]]
  [[ "$output" == *"gemini   mcp:stale"* ]]
  [[ "$output" == *"rerun: agentws setup"* ]]
  run agentws setup gemini --check --json
  [ "$(printf '%s' "$output" | jq -r '.data.harnesses[0].mcp_state')" = stale ]

  # The expected shape reads as yes.
  jq -n --arg c "$nb" --arg a "$mcp" '{mcpServers:{agentws:{command:$c, args:[$a]}}}' > "$HOME/.claude.json"
  printf '[mcp_servers.agentws]\ncommand = "%s"\nargs = ["%s"]\n' "$nb" "$mcp" > "$HOME/.codex/config.toml"
  run agentws setup claude codex --check
  [[ "$output" == *"claude   mcp:yes"* ]]
  [[ "$output" == *"codex    mcp:yes"* ]]

  # Plain setup rewrites a stale entry.
  run agentws setup gemini
  [ "$status" -eq 0 ]
  run agentws setup gemini --check
  [[ "$output" == *"gemini   mcp:yes"* ]]
}

@test "setup keeps an existing owner prefix on the agentws entry" {
  stub claude; stub codex
  printf '{"mcpServers":{"agentws":{"command":"x","env":{"AGENTWS_OWNER_PREFIX":"team-a"}}}}\n' \
    > "$HOME/.claude.json"
  mkdir -p "$HOME/.codex" "$HOME/.gemini" "$HOME/.cursor"
  printf '[mcp_servers.other.env]\nAGENTWS_OWNER_PREFIX = "wrong"\n\n[mcp_servers.agentws]\ncommand = "x"\n\n[mcp_servers.agentws.env]\nAGENTWS_OWNER_PREFIX = "team-b"\n' \
    > "$HOME/.codex/config.toml"
  printf '{"mcpServers":{"agentws":{"command":"x","env":{"AGENTWS_OWNER_PREFIX":"team-c"}}}}\n' \
    > "$HOME/.gemini/settings.json"
  run agentws setup claude codex gemini cursor
  [ "$status" -eq 0 ]
  grep -q -- "--env AGENTWS_OWNER_PREFIX=team-a -- " "$SANDBOX/claude.log"
  grep -q -- "--env AGENTWS_OWNER_PREFIX=team-b -- " "$SANDBOX/codex.log"
  [ "$(jq -r '.mcpServers.agentws.env.AGENTWS_OWNER_PREFIX' "$HOME/.gemini/settings.json")" = team-c ]
  [ "$(jq -r '.mcpServers.agentws.env.AGENTWS_OWNER_PREFIX' "$HOME/.cursor/mcp.json")" = cursor ]
}

codex_prefix() { # codex_prefix <expected>: config.toml from stdin, then setup codex
  mkdir -p "$HOME/.codex"
  cat > "$HOME/.codex/config.toml"
  rm -f "$SANDBOX/codex.log"
  agentws setup codex >/dev/null 2>&1
  grep -qF -- "mcp add agentws --env AGENTWS_OWNER_PREFIX=$1 -- " "$SANDBOX/codex.log"
}

@test "setup reads the codex owner prefix from every TOML form" {
  stub codex
  codex_prefix 'te am"x' <<'EOF'
[mcp_servers.agentws]
command = "x"

[mcp_servers.agentws.env]
AGENTWS_OWNER_PREFIX = 'te am"x'
EOF
  codex_prefix 'a"b\c' <<'EOF'
[mcp_servers.agentws.env]
AGENTWS_OWNER_PREFIX = "a\"b\\c"
EOF
  codex_prefix new <<'EOF'
[mcp_servers.agentws.env]
# AGENTWS_OWNER_PREFIX = "old"
AGENTWS_OWNER_PREFIX = "new"
EOF
  codex_prefix real <<'EOF'
[mcp_servers.agentws.env]
MY_AGENTWS_OWNER_PREFIX = "suffix"
AGENTWS_OWNER_PREFIX = "real"
EOF
  codex_prefix codex <<'EOF'
[mcp_servers.agentws.env]
MY_AGENTWS_OWNER_PREFIX = "suffix"
EOF
  codex_prefix quoted <<'EOF'
[mcp_servers."agentws".env]
"AGENTWS_OWNER_PREFIX" = "quoted"
EOF
  codex_prefix commented <<'EOF'
[mcp_servers.agentws.env] # written by codex
AGENTWS_OWNER_PREFIX = "commented"
EOF
  codex_prefix inline <<'EOF'
[mcp_servers.agentws]
command = "x"
env = { OTHER = "a,AGENTWS_OWNER_PREFIX = 'no'", AGENTWS_OWNER_PREFIX = 'inline' }
EOF
  codex_prefix dotted <<'EOF'
[mcp_servers.agentws]
env.AGENTWS_OWNER_PREFIX = "dotted"
EOF
  codex_prefix codex <<'EOF'
[mcp_servers.other.env]
AGENTWS_OWNER_PREFIX = "wrong"
[mcp_servers.agentws]
command = "x"
EOF
}

@test "setup leaves an entry alone when its owner prefix cannot be read" {
  stub codex
  mkdir -p "$HOME/.codex" "$HOME/.gemini"
  printf '[mcp_servers.agentws.env]\nAGENTWS_OWNER_PREFIX = "a\\u0041"\n' > "$HOME/.codex/config.toml"
  printf '{"mcpServers":{"agentws":{"command":"x","env":{"AGENTWS_OWNER_PREFIX":7}}}}\n' \
    > "$HOME/.gemini/settings.json"
  run agentws setup codex gemini
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex: cannot read AGENTWS_OWNER_PREFIX"* ]]
  [[ "$output" == *"gemini: cannot read AGENTWS_OWNER_PREFIX"* ]]
  [ ! -e "$SANDBOX/codex.log" ]
  [ "$(jq -r '.mcpServers.agentws.command' "$HOME/.gemini/settings.json")" = x ]
  [ "$(jq -r '.mcpServers.agentws.env.AGENTWS_OWNER_PREFIX' "$HOME/.gemini/settings.json")" = 7 ]
}

@test "install --no-setup warns when no bash can run the MCP server" {
  fake_bash "$SANDBOX/old/bash" 3 2 "3.2.57(1)-release"
  export AGENTWS_SETUP_BASH_CANDIDATES="$SANDBOX/old/bash"
  AGENTWS_PREFIX="$HOME/bin" run bash "$AGENTWS_REPO_ROOT/install.sh" --no-setup
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN MCP server needs bash 4.1+ (found 3.2.57(1)-release)"* ]]
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

  run "$HOME/bin/agentws" version
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

@test "the background check never holds the caller's pipes, even on extra fds" {
  make_origin
  piped_install >/dev/null 2>&1
  unset AGENTWS_NO_AUTO_UPDATE
  # A fetch that hangs: if the detached child kept any pipe open, cat would wait.
  local real; real="$(command -v git)"
  printf '#!/bin/sh\ncase "$*" in *fetch*) sleep 20 ;; esac\nexec "%s" "$@"\n' "$real" > "$STUBS/git"
  chmod +x "$STUBS/git"
  local t0 t1
  t0="$(date +%s)"
  run bash -c "'$HOME/bin/agentws' version 7>&1 | cat"
  t1="$(date +%s)"
  [ "$status" -eq 0 ]
  [ $((t1 - t0)) -lt 5 ]
  pkill -f "$HOME/.local/share/agentws/bin/agentws update" 2>/dev/null || true
}

@test "stable ignores prerelease tags" {
  make_origin
  git -C "$ORIGIN" tag v9.0.0
  piped_install >/dev/null 2>&1
  git -C "$ORIGIN" commit -q --allow-empty -m rc
  git -C "$ORIGIN" tag v9.1.0-rc1
  run "$HOME/bin/agentws" update
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.local/share/agentws" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.0.0)" ]
}

@test "a live update lock is a refusal; a dead one is cleared" {
  make_origin
  piped_install >/dev/null 2>&1
  local lockd="$XDG_STATE_HOME/agentws/update.lock"
  mkdir -p "$lockd"
  sleep 30 & local holder=$!
  printf '%s\n' "$holder" > "$lockd/pid"
  run "$HOME/bin/agentws" update
  [ "$status" -ne 0 ]
  [[ "$output" == *"another update is running"* ]]
  kill "$holder"; wait "$holder" 2>/dev/null || true
  run "$HOME/bin/agentws" update
  [ "$status" -eq 0 ]
  [ ! -e "$lockd" ]
}

@test "setup keeps a symlinked config a symlink, with its mode" {
  mkdir -p "$HOME/.gemini" "$HOME/dotfiles"
  printf '{"apiKey":"SECRET"}\n' > "$HOME/dotfiles/gemini.json"
  chmod 600 "$HOME/dotfiles/gemini.json"
  ln -s "$HOME/dotfiles/gemini.json" "$HOME/.gemini/settings.json"
  run agentws setup gemini
  [ "$status" -eq 0 ]
  [ -L "$HOME/.gemini/settings.json" ]
  [ "$(jq -r .apiKey "$HOME/dotfiles/gemini.json")" = SECRET ]
  [ "$(jq -r '.mcpServers.agentws.command' "$HOME/dotfiles/gemini.json")" != null ]
  [ -z "$(find "$HOME/dotfiles/gemini.json" -perm -g+r)" ]
}

@test "removing one harness keeps the shared skill for the others" {
  mkdir -p "$HOME/.cursor" "$HOME/.gemini"
  agentws setup cursor gemini >/dev/null 2>&1
  run agentws setup cursor --remove
  [ "$status" -eq 0 ]
  [ -L "$HOME/.agents/skills/agentws" ]
  run agentws setup gemini --remove
  [ ! -e "$HOME/.agents/skills/agentws" ]
}

@test "the Claude hook runs from an install path with spaces" {
  stub claude
  local inst="$SANDBOX/my tools/agentws"
  mkdir -p "$inst"
  cp -R "$AGENTWS_REPO_ROOT/bin" "$AGENTWS_REPO_ROOT/lib" "$AGENTWS_REPO_ROOT/mcp" \
        "$AGENTWS_REPO_ROOT/skills" "$AGENTWS_REPO_ROOT/providers" "$AGENTWS_REPO_ROOT/VERSION" "$inst/"
  "$inst/bin/agentws" setup claude >/dev/null 2>&1
  local cmd
  cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOME/.claude/settings.json")"
  run sh -c "$cmd"
  [ "$status" -eq 0 ]
}

@test "a hook entry without a hooks list survives setup" {
  stub claude
  mkdir -p "$HOME/.claude"
  printf '{"hooks":{"SessionStart":[{"matcher":"startup"}]}}\n' > "$HOME/.claude/settings.json"
  agentws setup claude >/dev/null 2>&1
  [ "$(jq '[.hooks.SessionStart[] | select(.matcher == "startup")] | length' "$HOME/.claude/settings.json")" -eq 1 ]
}

@test "init --force keeps existing slots and creates the missing ones" {
  make_repo "$SANDBOX/proj"
  cd "$SANDBOX/proj"
  agentws init --slots 1 >/dev/null 2>&1
  run agentws init --slots 2 --force
  [ "$status" -eq 0 ]
  [ -e "$SANDBOX/proj-ws/1_proj/.git" ]
  [ -e "$SANDBOX/proj-ws/2_proj/.git" ]
}

@test "the MCP server rejects a JSON-RPC batch with an error, not silence" {
  run bash -c "printf '%s\n' '[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}]' | '$AGENTWS_REPO_ROOT/mcp/agentws-mcp' 2>/dev/null"
  [ "$(printf '%s' "$output" | jq -r .error.code)" = "-32600" ]
}

@test "a release tag moved forward on the remote is followed, not a fetch failure" {
  make_origin
  git -C "$ORIGIN" tag v9.0.0
  piped_install >/dev/null 2>&1
  git -C "$ORIGIN" commit -q --allow-empty -m recut
  git -C "$ORIGIN" tag -f v9.0.0 >/dev/null
  run "$HOME/bin/agentws" update
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.local/share/agentws" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.0.0)" ]

  # Moved back to an ancestor: fetched, but never taken.
  git -C "$ORIGIN" tag -f v9.0.0 HEAD~1 >/dev/null
  run "$HOME/bin/agentws" update
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.local/share/agentws" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse main)" ]
}

@test "re-running the installer heals an install whose update cannot fetch a moved tag" {
  make_origin
  # The installed release carries the old update code, without --force.
  sed -i.bak 's/ --tags --force --prune origin/ --tags --prune origin/' "$ORIGIN/lib/update.sh"
  rm -f "$ORIGIN/lib/update.sh.bak"
  git -C "$ORIGIN" commit -q -am "old update code"
  git -C "$ORIGIN" tag v9.0.0
  piped_install >/dev/null 2>&1
  git -C "$ORIGIN" commit -q --allow-empty -m recut
  git -C "$ORIGIN" tag -f v9.0.0 >/dev/null
  run piped_install
  [ "$status" -eq 0 ]
  [ "$(git -C "$HOME/.local/share/agentws" rev-parse HEAD)" = "$(git -C "$ORIGIN" rev-parse v9.0.0)" ]
}
