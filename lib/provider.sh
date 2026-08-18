# provider.sh - provider loading and dispatch.
#
# Load order is: defaults from providers/_contract.sh, then the selected
# provider sourced on top. A provider that omits a hook inherits the default.
# A provider that needs another provider as its base sources it itself.

AGENTWS_PROVIDER_API=1
AGENTWS_PROVIDER_FILE=""

# Search path: an explicit AGENTWS_PROVIDER_PATH entry wins, then the bundled
# providers/ directory next to lib/.
provider_search_path() {
  local d
  for d in ${AGENTWS_PROVIDER_PATH:-}; do printf '%s\n' "$d"; done
  printf '%s\n' "$AGENTWS_LIB_DIR/../providers"
}

provider_file_for() { # provider_file_for <name> -> path on stdout, rc 1 if absent
  local name="$1" d f
  case "$name" in
    ''|*/*|*..*|_*) die "invalid provider name '$name'" ;;
    *[!A-Za-z0-9_-]*) die "invalid provider name '$name'" ;;
  esac
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    f="$d/$name.sh"
    if [ -f "$f" ]; then printf '%s' "$f"; return 0; fi
  done <<EOF
$(provider_search_path)
EOF
  return 1
}

provider_load() {
  local name="${AGENTWS_PROVIDER:-worktree}" contract f v
  AGENTWS_LIB="$(cd "$AGENTWS_LIB_DIR/.." && pwd -P)"
  contract="$AGENTWS_LIB_DIR/../providers/_contract.sh"
  [ -f "$contract" ] || die "provider contract not found at $contract"
  # shellcheck source=../providers/_contract.sh
  . "$contract"

  f="$(provider_file_for "$name")" || die "unknown provider '$name' (looked for $name.sh in: $(provider_search_path | tr '\n' ' '))"
  # shellcheck source=/dev/null
  . "$f"
  AGENTWS_PROVIDER_FILE="$f"

  v="$(provider_api_version)"
  [ "$v" = "$AGENTWS_PROVIDER_API" ] || \
    die "provider '$name' implements API v$v, this agentws speaks v$AGENTWS_PROVIDER_API"
}

# --------------------------------------------------------------- dispatch

# PREDICATE: does the provider claim this subcommand name?
provider_has_command() { # provider_has_command <name>
  local want="$1" c
  for c in $(provider_commands); do
    [ "$c" = "$want" ] && return 0
  done
  return 1
}

provider_run_command() { # provider_run_command <name> [args...]
  local name="$1"; shift
  provider_has_command "$name" || return 127
  command -v "provider_cmd_$name" >/dev/null 2>&1 || \
    die "provider '$AGENTWS_PROVIDER' advertises '$name' but defines no provider_cmd_$name"
  "provider_cmd_$name" "$@"
}

# --------------------------------------------------------------- helpers

# Every slot named in the config, in config order.
slot_list() { local s; for s in $AGENTWS_SLOTS; do printf '%s\n' "$s"; done; }

# Only the slots that actually exist on disk, per the provider.
slot_list_existing() {
  local s
  for s in $AGENTWS_SLOTS; do
    provider_slot_exists "$s" && printf '%s\n' "$s"
  done
  return 0
}
