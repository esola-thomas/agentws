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
# The contract is twelve functions: api_version plus the eleven hooks below.

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

# ACTION: <slot> <abs-path> <ref>. Core has moved the slot's working tree to
# <ref> and still holds the lock. Bring subordinate state the parent checkout
# does not carry into agreement with <ref>. Called by recycle and by refresh.
# A non-zero rc fails that command and the lock is NOT released, so a slot is
# never handed on in a state status would call dirty.
#
# The default exists because `git checkout` and `git reset` move the gitlink but
# not the submodule working tree, which leaves the parent permanently dirty and
# the slot unclaimable. `sync` first, so a submodule whose URL changed on <ref>
# is fetched from the right remote. `--checkout` so a submodule.<name>.update of
# merge, rebase, or none cannot turn a reset into a merge. Never --force:
# uncommitted work inside a submodule must fail loudly, not be discarded.
provider_slot_reset() { # <slot> <abs-path> <ref>
  local d="${2-}"
  [ -n "$d" ] && [ -f "$d/.gitmodules" ] || return 0
  run git -C "$d" submodule sync --recursive --quiet || return 1
  run git -C "$d" submodule update --init --recursive --checkout --quiet || return 1
}

# VALUE: space-separated extra subcommand names. Core parses the string with
# case; bash 3.2 has neither associative arrays nor a usable callback registry.
# Core dispatches `agentws <name>` to provider_cmd_<name>.
provider_commands()     { printf ''; }

# ACTION: extra `export K=V` lines appended to `agentws claim --print-env`.
provider_claim_env()    { :; }

# VALUE: ready, missing, or stale. Checks must be fast enough for status.
provider_env_check()    { printf 'ready'; }

# ACTION: provision or repair the slot's project environment.
provider_env_setup()    { :; }

# VALUE: short command or instruction returned to a claimed worker.
provider_bootstrap_hint() { printf ''; }
