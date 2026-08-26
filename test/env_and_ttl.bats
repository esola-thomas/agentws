#!/usr/bin/env bats

load helper

setup() { setup_sandbox 1 2 3; }
teardown() { teardown_sandbox; }

install_env_provider() {
  local pdir="$SANDBOX/providers"
  mkdir -p "$pdir"
  {
    printf '. "$AGENTWS_LIB/providers/worktree.sh"\n'
    printf 'provider_env_check() { if [ -f "$(git -C "$2" rev-parse --absolute-git-dir)/agentws-env-ready" ]; then printf ready; else printf missing; fi; }\n'
    printf 'provider_env_setup() { : > "$(git -C "$2" rev-parse --absolute-git-dir)/agentws-env-ready"; }\n'
    printf 'provider_bootstrap_hint() { printf ./bootstrap; }\n'
    printf 'provider_slot_create() { git clone -q "$AGENTWS_ROOT/1_proj" "$2"; }\n'
  } > "$pdir/custom.sh"
  sed -e 's/provider: worktree/provider: custom/' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  export AGENTWS_PROVIDER_PATH="$pdir"
}

@test "claim prefers an environment-ready slot and returns its bootstrap hint" {
  install_env_provider
  : > "$(git -C "$ROOT/2_proj" rev-parse --absolute-git-dir)/agentws-env-ready"
  run agentws claim --json work
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slot')" = "2" ]
  [ "$(printf '%s' "$json" | jq -r '.data.env')" = "ready" ]
  [ "$(printf '%s' "$json" | jq -r '.data.bootstrap_hint')" = "./bootstrap" ]
}

@test "require-env refuses when every free environment is missing" {
  install_env_provider
  run agentws claim --json --require-env work
  [ "$status" -eq 5 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.error.code')" = "ENOSLOT" ]
}

@test "doctor fix-env provisions and records a ready environment" {
  install_env_provider
  run agentws doctor --json --fix-env 1
  [ "$status" -eq 0 ]
  [ -f "$(git -C "$ROOT/1_proj" rev-parse --absolute-git-dir)/agentws-env-ready" ]
  [ -f "$ROOT/.agentws/env/1.ready" ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="env") | .status')" = "pass" ]
}

@test "create with-env provisions a new configured slot" {
  install_env_provider
  printf 'slots: [1,2,3,4]\n' >> "$CONFIG"
  run agentws create --json --with-env 4
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.env')" = "ready" ]
  [ -f "$(git -C "$ROOT/4_proj" rev-parse --absolute-git-dir)/agentws-env-ready" ]
}

@test "per-claim ttl is clamped and structured metadata is persisted" {
  run agentws claim --json --ttl 99 --task-id GH-5 --branch feat/mcp --agent codex work
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.lock.ttl_hours')" = "12" ]
  [ "$(printf '%s' "$json" | jq -r '.data.lock.task_id')" = "GH-5" ]
  [ "$(printf '%s' "$json" | jq -r '.data.lock.branch')" = "feat/mcp" ]
  [ "$(printf '%s' "$json" | jq -r '.data.lock.agent')" = "codex" ]
  [ "$(printf '%s' "$json" | jq -r '.data.lock.remaining_minutes > 0')" = "true" ]
}

@test "doctor auto-releases a finished slot after the configured quiet period" {
  printf 'auto_release: true\nauto_release_minutes: 30\n' >> "$CONFIG"
  agentws lock 1 work >/dev/null
  agentws doctor --json 1 >/dev/null
  local marker="$ROOT/.agentws/activity/1"
  local old=$(( $(date +%s) - 1900 ))
  sed -e "s/^epoch=.*/epoch=$old/" "$marker" > "$marker.new"
  mv "$marker.new" "$marker"

  run agentws doctor --json 1
  [ "$status" -eq 0 ]
  [ ! -f "$(lock_path 1)" ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="auto_release") | .detail')" = "released finished slot after 30 quiet minute(s)" ]
}
