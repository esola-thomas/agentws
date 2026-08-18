#!/usr/bin/env bash
# _contract.sh - Provider API v1, with the core-supplied default for every hook.
#
# lib/provider.sh sources this file first, installing these defaults, then
# sources providers/<name>.sh on top. A provider redefines only what differs.
#
# Function classes:
#   VALUE     - writes exactly one line to stdout, diagnostics to stderr, rc 0
#   PREDICATE - prints nothing, rc 0 = true, rc 1 = false
#   ACTION    - may print freely, rc is the result
#
# Rules, enforced by convention and by review:
#   - No hook may cd, exit, or assign to any AGENTWS_* variable.
#   - No hook may read or write $AGENTWS_LOCK_DIR. Locking is core-only.
#   - provider_slot_destroy is called ONLY after core verified lock_mine or --force.
#   - Providers read ONLY the AGENTWS_P_* namespace, never the config file.
#   - Forge-agnostic: plain git porcelain only, never a hosting-provider API.
#
# The contract is eight functions: api_version plus the seven hooks below.

# VALUE. Required. Core dies on a mismatch with AGENTWS_PROVIDER_API.
provider_api_version() { printf '1'; }

# VALUE: absolute path of a slot. Renders AGENTWS_SLOT_NAME_FORMAT.
provider_slot_path() { printf '%s/%s' "$AGENTWS_ROOT" "$(slot_name "$1")"; }

# PREDICATE: is a usable checkout present?
# -e, NOT -d. In a git worktree, .git is a FILE. A `[[ -d "$d/.git" ]]` test
# reports zero slots under the default provider, which is why slot existence is
# a hook and never an inline test in core.
provider_slot_exists() { [ -e "$(provider_slot_path "$1")/.git" ]; }

# ACTION: <slot> <abs-path>
provider_slot_create()  { die "provider '$AGENTWS_PROVIDER' cannot create slots"; }

# ACTION: <slot> <abs-path>. Core has already checked the lock.
provider_slot_destroy() { die "provider '$AGENTWS_PROVIDER' cannot destroy slots"; }

# ACTION: <slot> <abs-path>. Prints "OK|WARN|FAIL <check> <detail>" lines.
provider_slot_doctor()  { printf 'OK checkout %s\n' "${2-}"; }

# VALUE: space-separated extra subcommand names. Core parses the string with
# case; bash 3.2 has neither associative arrays nor a usable callback registry.
# Core dispatches `agentws <name>` to provider_cmd_<name>.
provider_commands()     { printf ''; }

# ACTION: extra `export K=V` lines appended to `agentws claim --print-env`.
provider_claim_env()    { :; }
