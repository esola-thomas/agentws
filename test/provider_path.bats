#!/usr/bin/env bats

load helper

setup() {
  setup_sandbox 1
  PRIV="$SANDBOX/private-providers"
  mkdir -p "$PRIV"
  {
    printf '#!/usr/bin/env bash\n'
    printf '. "$AGENTWS_LIB_DIR/../providers/worktree.sh"\n'
    printf 'provider_bootstrap_hint() { printf "from-private"; }\n'
  } > "$PRIV/mine.sh"
  sed -i.bak 's/^provider: worktree$/provider: mine/' "$CONFIG" && rm -f "$CONFIG.bak"
  printf 'provider_path: "%s"\n' "$PRIV" >> "$CONFIG"
}

teardown() { teardown_sandbox; }

@test "provider_path resolves a provider that lives outside the checkout" {
  run agentws config --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "\"provider_path\":\"$PRIV\""
  run agentws status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q '"bootstrap_hint":"from-private"'
}

@test "provider_path expands {root}" {
  mv "$PRIV" "$ROOT/.providers"
  sed -i.bak "s|^provider_path:.*|provider_path: \"{root}/.providers\"|" "$CONFIG" && rm -f "$CONFIG.bak"
  run agentws config
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q "provider_path *$ROOT/.providers"
}

@test "an unknown provider still fails clearly with provider_path set" {
  sed -i.bak 's/^provider: mine$/provider: nope/' "$CONFIG" && rm -f "$CONFIG.bak"
  run agentws status --json
  [ "$status" -ne 0 ]
}
