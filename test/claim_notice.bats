#!/usr/bin/env bats
# claim_notice.bats - slot labels, the claim notice, provider_slot_claimed,
# provider_claim_notice, the env object, and the in-slot session-start hook.

load helper

setup() {
  setup_sandbox 1 2 lab
  mkdir -p "$SANDBOX/prov"
  # A provider with the contract's default slot hooks plus the claim hooks.
  cat > "$SANDBOX/prov/hooktest.sh" <<'P'
provider_api_version() { printf '1'; }
provider_claim_env() {
  printf 'export DB_NAME=%s\n' "db_$1"
  printf 'export QUOTED=%s\n' "$(sq "it's \$HOME")"
  printf 'export PLAIN="two words"\n'
  printf 'not an export\n'
}
provider_claim_notice() {
  [ "${NOTICE_FAIL:-0}" -eq 0 ] || { printf 'half a line\n'; return 5; }
  printf 'Test DB: test_%s. Never edit shared config.\n' "$1"
}
provider_slot_claimed() {
  printf '%s %s\n' "$1" "$2" >> "$CLAIM_LOG"
  printf 'provider chatter on stdout\n'
  return "${CLAIMED_RC:-0}"
}
P
  sed -i.bak 's/^provider: .*/provider: hooktest/' "$CONFIG"
  printf 'provider_path: %s\n' "$SANDBOX/prov" >> "$CONFIG"
  export CLAIM_LOG="$SANDBOX/claims"
  : > "$CLAIM_LOG"
}
teardown() { teardown_sandbox; }

last_json() { printf '%s' "${lines[${#lines[@]}-1]}"; }
notice_file() { printf '%s/%s.notice' "$LOCKS" "$1"; }

@test "plain claim ends stdout with the path and prints the notice on stderr" {
  local out err
  out="$(agentws claim 'fix parser' 2>"$SANDBOX/err")"
  err="$(cat "$SANDBOX/err")"
  [ "$(printf '%s\n' "$out" | tail -1)" = "$ROOT/1_proj" ]
  [[ "$out" != *"you hold slot"* ]]
  [[ "$out" != *"chatter"* ]]
  [[ "$err" == *'agentws: you hold slot 1 (proj_1) for "fix parser".'* ]]
  [[ "$err" == *"Label everything you create outside this checkout with proj_1"* ]]
  [[ "$err" == *"Ports: your base port + 1."* ]]
  [[ "$err" == *"Test DB: test_1. Never edit shared config."* ]]
  [[ "$err" == *"export DB_NAME=db_1"* ]]
  [[ "$err" == *"Checkpoint with: agentws checkpoint set"* ]]
  [[ "$err" == *"provider chatter on stdout"* ]]
  [ "$(cat "$(notice_file 1)")" = "$(printf '%s\n' "$err" | sed -n '/^agentws: you hold/,/^Checkpoint with/p')" ]
}

@test "--print-env exports the label and the provider env and stays eval-safe" {
  local out
  out="$(agentws claim --print-env work 2>/dev/null)"
  [[ "$out" == *"export AGENTWS_LABEL='proj_1'"* ]]
  [[ "$out" == *"export DB_NAME=db_1"* ]]
  [ "$(printf '%s\n' "$out" | grep -vc '^export ')" -eq 1 ]
  # The one non-export line is the provider's own; everything else evals.
  eval "$(printf '%s\n' "$out" | grep '^export ')"
  [ "$AGENTWS_LABEL" = proj_1 ]
  [ "$QUOTED" = "it's \$HOME" ]
}

@test "--json carries label, notice, claim_env object, and no warnings" {
  run agentws claim --json work
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.label')" = proj_1 ]
  last_json | jq -r '.data.notice' | grep -q 'you hold slot 1 (proj_1)'
  [ "$(last_json | jq -c '.data.claim_env')" = '{"DB_NAME":"db_1","QUOTED":"it'"'"'s $HOME","PLAIN":"two words"}' ]
  [ "$(last_json | jq -c '.data.claim_warnings')" = '[]' ]
  run agentws status --json
  [ "$(last_json | jq -r '.data.slots[2].label')" = proj_lab ]
}

@test "provider_slot_claimed runs once per claim with the slot path" {
  agentws claim one >/dev/null 2>&1
  agentws claim --json two >/dev/null 2>&1
  agentws claim --print-env three >/dev/null 2>&1
  [ "$(wc -l < "$CLAIM_LOG" | tr -d ' ')" -eq 3 ]
  [ "$(sed -n 1p "$CLAIM_LOG")" = "1 $ROOT/1_proj" ]
  [ "$(sed -n 2p "$CLAIM_LOG")" = "2 $ROOT/2_proj" ]
  [ "$(sed -n 3p "$CLAIM_LOG")" = "lab $ROOT/lab_proj" ]
}

@test "a failing provider_slot_claimed is a warning and the lock is kept" {
  CLAIMED_RC=3 run agentws claim --json work
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.ok')" = true ]
  [ "$(last_json | jq -r '.data.claim_warnings[0]')" = "provider hooktest: provider_slot_claimed failed (rc 3); the lock is kept" ]
  [ -f "$(lock_path 1)" ]
  run env CLAIMED_RC=3 "$AGENTWS_BIN" claim plain
  [ "$status" -eq 0 ]
  [[ "$output" == *"agentws: warning: provider hooktest: provider_slot_claimed failed"* ]]
  [ -f "$(lock_path 2)" ]
}

@test "a provider_slot_claimed that exits or dies still leaves a successful claim" {
  printf 'provider_slot_claimed() { die "setup broke"; }\n' >> "$SANDBOX/prov/hooktest.sh"
  run agentws claim --json work
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.ok')" = true ]
  last_json | jq -r '.data.claim_warnings[0]' | grep -q 'provider_slot_claimed failed (rc 1)'
  [ -f "$(lock_path 1)" ]
  printf 'provider_slot_claimed() { exit 9; }\n' >> "$SANDBOX/prov/hooktest.sh"
  run agentws claim --print-env work2
  [ "$status" -eq 0 ]
  [[ "$output" == *"export AGENTWS_SLOT='2'"* ]]
  [ -f "$(lock_path 2)" ]
}

@test "a failing provider_claim_notice drops its lines and warns" {
  NOTICE_FAIL=1 run agentws claim --json work
  [ "$status" -eq 0 ]
  [[ "$(last_json | jq -r '.data.notice')" != *'half a line'* ]]
  last_json | jq -r '.data.claim_warnings[0]' | grep -q 'provider_claim_notice failed (rc 5)'
}

@test "a non-numeric slot gets a sanitized label and no port line" {
  sed -i.bak 's/^top: .*/top: my-proj.x/' "$CONFIG"
  sed -i.bak 's/^slot_name_format: .*/slot_name_format: "{slot}_proj"/' "$CONFIG"
  run agentws claim --slot lab --json work
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.label')" = my_proj_x_lab ]
  [[ "$(last_json | jq -r '.data.notice')" != *Ports* ]]
}

@test "the notice is deleted on unlock and replaced by the next owner's claim" {
  agentws claim --slot 2 work >/dev/null 2>&1
  [ -f "$(notice_file 2)" ]
  agentws unlock 2 >/dev/null
  [ ! -e "$(notice_file 2)" ]
  write_lock_default 2 "owner_pid=4242" "owner_start=777"
  printf 'old notice\n' > "$(notice_file 2)"
  agentws lock 2 plain-lock >/dev/null
  [ ! -e "$(notice_file 2)" ]
}

@test "MCP workspace_claim returns the label, notice, and claim_env" {
  local mcp="$AGENTWS_REPO_ROOT/mcp/agentws-mcp" out
  out="$(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_claim","arguments":{"session":"s1","reason":"work"}}}' \
    | "$mcp" 2>/dev/null | sed -e 's/^Content-Length:[^{]*//' | jq -r '.result.content[0].text')"
  [ "$(printf '%s' "$out" | jq -r '.data.label')" = proj_1 ]
  [ "$(printf '%s' "$out" | jq -r '.data.claim_env.DB_NAME')" = db_1 ]
  printf '%s' "$out" | jq -r '.data.notice' | grep -q 'Test DB: test_1'
  [ "$(wc -l < "$CLAIM_LOG" | tr -d ' ')" -eq 1 ]
}

@test "session-start inside a locked slot prints the notice and checkpoint" {
  agentws claim work >/dev/null 2>&1
  mkdir -p "$ROOT/1_proj/sub"
  cd "$ROOT/1_proj/sub"
  run agentws hook session-start
  [ "$status" -eq 0 ]
  [[ "$output" == *"you hold slot 1 (proj_1)"* ]]
  [[ "$output" == *"No checkpoint yet"* ]]
  [[ "$output" != *"agentws farm"* ]]
  agentws checkpoint set --phase tests --next "fix flaky test" >/dev/null
  run agentws hook session-start
  [[ "$output" == *"next:  fix flaky test"* ]]
}

@test "session-start in a slot locked without a claim names the lock and label" {
  agentws lock 2 manual >/dev/null
  cd "$ROOT/2_proj"
  run agentws hook session-start
  [ "$status" -eq 0 ]
  [[ "$output" == *'you are in slot 2 (2_proj), locked by tester for "manual". Label shared resources with proj_2.'* ]]
}

@test "session-start outside a slot, or in an unlocked one, prints the farm table" {
  cd "$SANDBOX"
  run agentws hook session-start
  [ "$status" -eq 0 ]
  [[ "$output" == *"agentws farm"* ]]
  cd "$ROOT/1_proj"
  run agentws hook session-start
  [[ "$output" == *"agentws farm"* ]]
}

@test "session-start is silent with no farm" {
  unset AGENTWS_CONFIG
  mkdir -p "$SANDBOX/nofarm"
  cd "$SANDBOX/nofarm"
  HOME="$SANDBOX/nofarm" run agentws hook session-start
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
