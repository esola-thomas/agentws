#!/usr/bin/env bats
# hook_guard.bats - `agentws hook pre-tool-use`, the Claude Code PreToolUse
# guard for sessions inside a slot.

load helper

setup() {
  setup_sandbox 0 1 2
  printf 'reference_slot: "0"\n' >> "$CONFIG"
}
teardown() { teardown_sandbox; }

# hook_input <cwd> <tool> <field> <value> -> hook JSON on stdout
hook_input() {
  jq -cn --arg cwd "$1" --arg t "$2" --arg k "$3" --arg v "$4" \
    '{session_id:"x",cwd:$cwd,hook_event_name:"PreToolUse",permission_mode:"bypassPermissions",tool_name:$t,tool_input:{($k):$v}}'
}

# guard <cwd> <tool> <field> <value>: run the hook, set status and output
guard() {
  hook_input "$@" > "$SANDBOX/in.json"
  run bash -c '"$1" hook pre-tool-use < "$2"' _ "$AGENTWS_BIN" "$SANDBOX/in.json"
}

denied() {
  [ "$status" -eq 0 ] && \
    [ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecision')" = deny ]
}

allowed() { [ "$status" -eq 0 ] && [ -z "$output" ]; }

@test "writes inside the session's own slot are allowed" {
  guard "$ROOT/1_proj" Write file_path "$ROOT/1_proj/src/new.txt"
  allowed
  guard "$ROOT/1_proj" Edit file_path "README"
  allowed
  mkdir -p "$ROOT/1_proj/deep"
  guard "$ROOT/1_proj/deep" Edit file_path "../README"
  allowed
  guard "$ROOT/1_proj" Write file_path "$SANDBOX/outside-any-slot.txt"
  allowed
}

@test "writes into another slot are denied, by path, by .., and through a symlink" {
  guard "$ROOT/1_proj" Write file_path "$ROOT/2_proj/x.txt"
  denied
  [[ "$(printf '%s' "$output" | jq -r '.hookSpecificOutput.permissionDecisionReason')" == "agentws: $ROOT/2_proj/x.txt is in slot 2 (2_proj), but this session works in slot 1 (1_proj)"* ]]
  guard "$ROOT/1_proj" Edit file_path "../2_proj/README"
  denied
  guard "$ROOT/1_proj" Write file_path "$ROOT/1_proj/nope/../../2_proj/new/dir/f"
  denied
  ln -s "$ROOT/2_proj/README" "$ROOT/1_proj/link"
  guard "$ROOT/1_proj" Edit file_path "$ROOT/1_proj/link"
  denied
  ln -s "$ROOT/2_proj" "$ROOT/1_proj/dirlink"
  guard "$ROOT/1_proj" Write file_path "$ROOT/1_proj/dirlink/new.txt"
  denied
  guard "$ROOT/1_proj" NotebookEdit notebook_path "$ROOT/2_proj/n.ipynb"
  denied
}

@test "writes into the reference slot are denied, even from inside it" {
  guard "$ROOT/1_proj" Write file_path "$ROOT/0_proj/README"
  denied
  [[ "$output" == *"reference slot 0 (0_proj)"* ]]
  guard "$ROOT/0_proj" Edit file_path "$ROOT/0_proj/README"
  denied
}

@test "git checkout of the default branch and git reset --hard are denied in a slot" {
  guard "$ROOT/1_proj" Bash command "git checkout main"
  denied
  [[ "$output" == *"git checkout -b <branch> origin/main"* ]]
  guard "$ROOT/1_proj" Bash command "  git   reset   --hard  "
  denied
  guard "$ROOT/1_proj" Bash command "git reset --hard origin/main"
  denied
  guard "$ROOT/1_proj" Bash command "cd sub && git reset --hard HEAD~1"
  denied
  guard "$ROOT/1_proj" Bash command "git fetch; git checkout main"
  denied
  guard "$ROOT/1_proj" Bash command "git reset --hard HEAD -- extra args"
  denied
  guard "$ROOT/1_proj" Bash command "git reset --hard \"origin/main\""
  denied
}

@test "other git commands in a slot are allowed" {
  local c
  for c in "git checkout -b feat/x origin/main" "git checkout main -- README" "git status" \
           "git reset HEAD README" "echo git reset" "git checkout other" \
           "git commit -m \"x; git reset --hard y\"" "git commit -m 'undo | git checkout main'"; do
    guard "$ROOT/1_proj" Bash command "$c"
    allowed
  done
}

@test "a session outside every slot is never guarded" {
  guard "$SANDBOX" Write file_path "$ROOT/2_proj/x.txt"
  allowed
  guard "$ROOT" Write file_path "$ROOT/0_proj/README"
  allowed
  guard "$ROOT" Bash command "git reset --hard"
  allowed
}

@test "silent exit 0 with no farm" {
  unset AGENTWS_CONFIG
  mkdir -p "$SANDBOX/nofarm"
  hook_input "$SANDBOX/nofarm" Write file_path "$ROOT/2_proj/x" > "$SANDBOX/in.json"
  HOME="$SANDBOX/nofarm" run bash -c '"$1" hook pre-tool-use < "$2"' _ "$AGENTWS_BIN" "$SANDBOX/in.json"
  allowed
}

@test "silent exit 0 with no jq, even for a write the guard would deny" {
  hook_input "$ROOT/1_proj" Write file_path "$ROOT/2_proj/x.txt" > "$SANDBOX/in.json"
  local nojq="$SANDBOX/nojq" c p
  mkdir -p "$nojq"
  for c in bash env git sed cat tr hostname dirname basename readlink date awk mktemp head tail \
           grep wc cksum sort id uname rm mkdir ls cut tee sleep; do
    p="$(command -v "$c" 2>/dev/null)" && ln -s "$p" "$nojq/$c"
  done
  run env PATH="$nojq" bash -c '"$1" hook pre-tool-use < "$2"' _ "$AGENTWS_BIN" "$SANDBOX/in.json"
  allowed
  # The same PATH plus jq denies, so the allow above came from the jq check.
  ln -s "$(command -v jq)" "$nojq/jq"
  run env PATH="$nojq" bash -c '"$1" hook pre-tool-use < "$2"' _ "$AGENTWS_BIN" "$SANDBOX/in.json"
  denied
}

@test "unparseable input and unknown tools are allowed silently" {
  printf 'not json' > "$SANDBOX/in.json"
  run bash -c '"$1" hook pre-tool-use < "$2"' _ "$AGENTWS_BIN" "$SANDBOX/in.json"
  allowed
  guard "$ROOT/1_proj" Read file_path "$ROOT/2_proj/README"
  allowed
}

@test "setup wires the PreToolUse guard once and --remove keeps other hooks" {
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/.claude" "$SANDBOX/stubs"
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/stubs/claude"; chmod +x "$SANDBOX/stubs/claude"
  printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"echo mine"}]}]}}\n' \
    > "$HOME/.claude/settings.json"
  PATH="$SANDBOX/stubs:$PATH" run agentws setup claude
  [ "$status" -eq 0 ]
  PATH="$SANDBOX/stubs:$PATH" run agentws setup claude
  local f="$HOME/.claude/settings.json"
  [ "$(jq '[.hooks.PreToolUse[].hooks[] | select(.command | contains("hook pre-tool-use"))] | length' "$f")" -eq 1 ]
  [ "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("hook pre-tool-use")) | .matcher' "$f")" = "Write|Edit|MultiEdit|NotebookEdit|Bash" ]
  [ "$(jq '[.hooks.SessionStart[].hooks[] | select(.command | contains("hook session-start"))] | length' "$f")" -eq 1 ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")" = "echo mine" ]

  PATH="$SANDBOX/stubs:$PATH" run agentws setup claude --remove
  [ "$status" -eq 0 ]
  [ "$(jq '.hooks.PreToolUse | length' "$f")" -eq 1 ]
  [ "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$f")" = "echo mine" ]
  [ "$(jq '.hooks | has("SessionStart")' "$f")" = false ]
}
