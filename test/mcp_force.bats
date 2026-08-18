#!/usr/bin/env bats
# mcp_force.bats - the force policy, section C of the validation plan.
#
# --force is a human CLI action. The MCP server must never pass it, never
# advertise it in a schema, and never retry a busy lock. A model that can force
# its way into a workspace defeats the entire point of the lock ladder.

load helper

MCP="$AGENTWS_REPO_ROOT/mcp/agentws-mcp"

setup() {
  setup_sandbox 1 2 3
  STUB_DIR="$SANDBOX/stub"
  mkdir -p "$STUB_DIR"
}
teardown() { teardown_sandbox; }

# ------------------------------------------------------------ static greps

@test "the server never passes --force to the CLI" {
  ! grep -nE '(^|[^-[:alnum:]])--force' "$MCP"
}

@test "no tool schema exposes a force property" {
  # Comments are excluded; a JSON key or a CLI flag is not.
  ! grep -vE '^[[:space:]]*#' "$MCP" | grep -nE '"force"|--force|FORCE='
}

@test "every occurrence of 'force' is prose, not a flag" {
  local line
  while IFS= read -r line; do
    # Acceptable: a comment, or a description string telling the model no
    # force option exists.
    case "$line" in
      *"#"*) continue ;;
      *description*|*instructions*|*message*) continue ;;
      *) printf 'unexpected force reference: %s\n' "$line" >&2; return 1 ;;
    esac
  done <<EOF
$(grep -n 'force' "$MCP" || true)
EOF
}

@test "the server sets no FORCE environment variable for the CLI" {
  ! grep -nE 'FORCE=1|FORCE=true' "$MCP"
}

@test "the six tool schemas are exactly the documented set" {
  local names
  names="$(sed -n 's/.*"name":"\(workspace_[a-z_]*\)".*/\1/p' "$MCP" | sort -u | tr '\n' ' ')"
  [ "$names" = "workspace_claim workspace_doctor workspace_lock workspace_release workspace_status workspace_sync " ]
}

@test "workspace_lock tells the model a busy result is final" {
  grep -q 'do not retry' "$MCP"
}

# --------------------------------------------------- no retry, behaviourally
# A stub agentws records every invocation. One tools/call that hits a busy lock
# must produce exactly one invocation: no retry, forced or otherwise.

write_stub() { # write_stub <exit-code> <stdout-json>
  cat > "$STUB_DIR/agentws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_DIR/calls"
printf '%s\n' '$2'
exit $1
EOF
  chmod +x "$STUB_DIR/agentws"
  : > "$STUB_DIR/calls"
}

mcp_send() { # mcp_send <request-json>... -> server stdout
  local reqs="$1"
  printf '%s\n' "$reqs" |
    AGENTWS_BIN="$STUB_DIR/agentws" "$MCP" 2>/dev/null
}

busy_envelope() {
  printf '%s' '{"ok":false,"command":"lock","data":null,"error":{"code":"ELOCKED","message":"held by someone else"}}'
}

@test "a busy lock is attempted exactly once, never retried" {
  write_stub 4 "$(busy_envelope)"
  mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_lock","arguments":{"session":"s1","slot":"1","reason":"work"}}}' >/dev/null
  [ "$(grep -c 'lock' "$STUB_DIR/calls")" -eq 1 ]
}

@test "the retry attempt, if any, would not carry --force" {
  write_stub 4 "$(busy_envelope)"
  mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_lock","arguments":{"session":"s1","slot":"1","reason":"work"}}}' >/dev/null
  ! grep -q -- '--force' "$STUB_DIR/calls"
}

@test "a busy lock is reported to the model as an error, not swallowed" {
  write_stub 4 "$(busy_envelope)"
  local out
  out="$(mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_lock","arguments":{"session":"s1","slot":"1","reason":"work"}}}')"
  [ "$(printf '%s' "$out" | sed -e 's/^Content-Length:[^{]*//' | jq -r '.result.isError')" = "true" ]
}

@test "a busy claim is attempted exactly once" {
  write_stub 5 '{"ok":false,"command":"claim","data":null,"error":{"code":"ENOSLOT","message":"none free"}}'
  mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_claim","arguments":{"session":"s1","reason":"work"}}}' >/dev/null
  [ "$(grep -c 'claim' "$STUB_DIR/calls")" -eq 1 ]
}

# ------------------------------------------------------------ owner scoping

@test "the server derives a per-session owner and passes it as --owner" {
  write_stub 0 '{"ok":true,"command":"status","data":{},"error":null}'
  mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_status","arguments":{"session":"session-abc"}}}' >/dev/null
  grep -q -- '--owner mcp:session-abc' "$STUB_DIR/calls"
}

@test "two sessions never share an owner string" {
  write_stub 0 '{"ok":true,"command":"status","data":{},"error":null}'
  mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_status","arguments":{"session":"aaa"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workspace_status","arguments":{"session":"bbb"}}}' >/dev/null
  grep -q -- '--owner mcp:aaa' "$STUB_DIR/calls"
  grep -q -- '--owner mcp:bbb' "$STUB_DIR/calls"
}

@test "a call without a session is refused before any CLI invocation" {
  write_stub 0 '{"ok":true,"command":"status","data":{},"error":null}'
  mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_status","arguments":{}}}' >/dev/null
  [ ! -s "$STUB_DIR/calls" ]
}

@test "tools/list advertises six tools and no force parameter anywhere" {
  write_stub 0 '{"ok":true,"command":"status","data":{},"error":null}'
  local out body
  out="$(mcp_send '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}')"
  body="$(printf '%s' "$out" | sed -e 's/^Content-Length:[^{]*//')"
  [ "$(printf '%s' "$body" | jq -r '.result.tools | length')" = "6" ]
  [ "$(printf '%s' "$body" | jq -r '[.result.tools[].inputSchema.properties | keys[]] | map(select(.=="force")) | length')" = "0" ]
}
