# setup.sh - commands that run before a config exists: init, use, setup, hook.
#
# setup wires each installed AI harness to THIS checkout: the MCP server is
# registered by absolute path and the skill is a symlink into skills/agentws.
# Because every harness points at one checkout, `agentws update` upgrades all
# of them at once and there is never a second copy to drift.

AGENTWS_DEFAULT_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/agentws/default.yml"
SETUP_HARNESSES="claude codex copilot cursor gemini"
# The hook matches on this suffix; the full command carries the absolute path
# so it runs even when ~/.local/bin is not on the harness's PATH.
SETUP_HOOK_MARK="agentws hook session-start"

# ---------------------------------------------------------------------- init
# init [repo] [--root DIR] [--slots N]: one command from a checkout to a farm.
# The farm lives beside the repo (<repo>-ws/), its slots are worktrees of the
# repo, and it becomes the default farm when none is set yet.
cmd_init() {
  local repo="" root="${INIT_ROOT:-}" n="${INIT_SLOTS:-3}" top defbr f slots="" i made_default=0
  repo="${1:-$(pwd -P)}"
  repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'init: %s is not inside a git checkout\n' "${1:-$(pwd -P)}" >&2; return 2; }
  case "$n" in ''|*[!0-9]*|0) printf 'init: --slots must be a positive integer\n' >&2; return 2 ;; esac
  top="$(basename "$repo")"
  [ -n "$root" ] || root="$(dirname "$repo")/${top}-ws"
  case "$root" in /*) ;; *) root="$(pwd -P)/$root" ;; esac
  f="$root/.agentws.yml"
  if [ -e "$f" ] && [ "${FORCE:-0}" -ne 1 ]; then
    printf 'init: %s already exists (use --force to overwrite)\n' "$f" >&2
    return 2
  fi

  defbr="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
  defbr="${defbr#origin/}"
  [ -n "$defbr" ] || defbr="$(git -C "$repo" branch --show-current 2>/dev/null || true)"
  [ -n "$defbr" ] || defbr=main
  i=1
  while [ "$i" -le "$n" ]; do slots="${slots:+$slots, }$i"; i=$((i + 1)); done

  if [ "${DRY:-0}" -eq 1 ]; then
    printf '  [dry-run] write %s (%s slots of %s on %s)\n' "$f" "$n" "$repo" "$defbr" >&2
  else
    mkdir -p "$root" || return 1
    cat > "$f" <<EOF
# agentws farm for $repo. Reference: .agentws.yml.example in the agentws repo.
version: 1
root: $root
top: $top
provider: worktree
default_branch: $defbr
slots: [$slots]
slot_name_format: "{slot}_{top}"
ttl_hours: 12
lock_dir: "{root}/.agentws/locks"
provider_opts:
  source_repo: $repo
EOF
    printf 'wrote %s\n' "$f" >&2
    i=1
    while [ "$i" -le "$n" ]; do
      "$AGENTWS_BIN_DIR/agentws" --config "$f" create "$i" >&2 || return 7
      i=$((i + 1))
    done
    if [ ! -e "$AGENTWS_DEFAULT_CONFIG" ]; then
      use_config "$f" && made_default=1
    fi
  fi

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"path":%s,"root":%s,"top":%s,"repo":%s,"default_branch":%s,"slots":%s,"default":%s}' \
      "$(jstr "$f")" "$(jstr "$root")" "$(jstr "$top")" "$(jstr "$repo")" "$(jstr "$defbr")" \
      "$n" "$(jbool "$made_default")"
  elif [ "${DRY:-0}" -ne 1 ]; then
    printf '\nFarm ready: %s slots in %s\n' "$n" "$root"
    [ "$made_default" -eq 1 ] && printf 'It is your default farm, so agents find it from any directory.\n'
    [ "$made_default" -eq 1 ] || printf 'Make it the default farm with: agentws use %s\n' "$f"
    printf 'Try: agentws status\n'
  fi
}

# ----------------------------------------------------------------------- use
use_config() { # use_config <abs-config-path>
  mkdir -p "$(dirname "$AGENTWS_DEFAULT_CONFIG")" || return 1
  ln -sfn "$1" "$AGENTWS_DEFAULT_CONFIG" || return 1
  printf 'default farm -> %s\n' "$1" >&2
}

# use [config]: make a farm the default. Without an argument, the farm found
# from the current directory.
cmd_use() {
  local f="${1:-}"
  if [ -z "$f" ]; then
    f="$(config_find)" || return 3
  fi
  case "$f" in /*) ;; *) f="$(pwd -P)/$f" ;; esac
  [ -d "$f" ] && f="$f/.agentws.yml"
  [ -f "$f" ] || { printf 'use: %s not found\n' "$f" >&2; return 2; }
  use_config "$f" || return 1
  [ "${JSON:-0}" -eq 1 ] && printf '{"default":%s}' "$(jstr "$f")"
  return 0
}

# ---------------------------------------------------------------------- hook
# hook session-start: context for a new agent session. Silent and exit 0
# whenever there is no farm, so it is safe to install globally.
cmd_hook() {
  case "${1:-}" in
    session-start)
      local out
      out="$("$AGENTWS_BIN_DIR/agentws" free 2>/dev/null)" || return 0
      [ -n "$out" ] || return 0
      printf 'agentws farm (claim a slot before any checkout of the farmed repo; see the agentws skill):\n%s\n' "$out"
      ;;
    *) printf 'hook: unknown event %s (session-start)\n' "${1:-}" >&2; return 2 ;;
  esac
  return 0
}

# --------------------------------------------------------------------- setup
setup_detected() { # setup_detected <harness>
  case "$1" in
    claude)  command -v claude  >/dev/null 2>&1 || [ -d "$HOME/.claude" ] ;;
    codex)   command -v codex   >/dev/null 2>&1 || [ -d "$HOME/.codex" ] ;;
    copilot) command -v copilot >/dev/null 2>&1 || [ -d "$HOME/.copilot" ] ;;
    cursor)  command -v cursor  >/dev/null 2>&1 || [ -d "$HOME/.cursor" ] ;;
    gemini)  command -v gemini  >/dev/null 2>&1 || [ -d "$HOME/.gemini" ] ;;
    *) return 1 ;;
  esac
}

setup_skill_dir() { # setup_skill_dir <harness> -> personal skills dir
  case "$1" in
    claude) printf '%s/.claude/skills' "$HOME" ;;
    *)      printf '%s/.agents/skills' "$HOME" ;;  # Codex, Copilot, Cursor, Gemini
  esac
}

setup_json_file() { # setup_json_file <harness> -> MCP config file for JSON-merge harnesses
  case "$1" in
    copilot) printf '%s/.copilot/mcp-config.json' "$HOME" ;;
    cursor)  printf '%s/.cursor/mcp.json' "$HOME" ;;
    gemini)  printf '%s/.gemini/settings.json' "$HOME" ;;
  esac
}

# Rewrite a JSON file through jq, atomically. Missing file starts as {}.
json_edit() { # json_edit <file> <jq-args...>
  local f="$1" tmp; shift
  mkdir -p "$(dirname "$f")" || return 1
  [ -s "$f" ] || printf '{}\n' > "$f"
  tmp="$f.agentws.$$"
  if jq "$@" "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

setup_link_skill() { # setup_link_skill <harness> <on|off>
  local d l
  d="$(setup_skill_dir "$1")"; l="$d/agentws"
  if [ "$2" = off ]; then
    [ -L "$l" ] && rm -f "$l"
    return 0
  fi
  if [ -e "$l" ] && [ ! -L "$l" ]; then
    printf '  %s exists and is not a symlink; leaving it\n' "$l" >&2
    return 0
  fi
  mkdir -p "$d" && ln -sfn "$AGENTWS_HOME_DIR/skills/agentws" "$l"
}

setup_mcp() { # setup_mcp <harness> <on|off>
  local h="$1" mcp="$AGENTWS_HOME_DIR/mcp/agentws-mcp" f
  case "$h" in
    claude)
      command -v claude >/dev/null 2>&1 || { printf '  claude CLI not on PATH; skipped MCP\n' >&2; return 0; }
      claude mcp remove --scope user agentws >/dev/null 2>&1 || true
      [ "$2" = off ] && return 0
      claude mcp add agentws --scope user --env AGENTWS_OWNER_PREFIX=claude -- "$mcp" >/dev/null
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || { printf '  codex CLI not on PATH; skipped MCP\n' >&2; return 0; }
      codex mcp remove agentws >/dev/null 2>&1 || true
      [ "$2" = off ] && return 0
      codex mcp add agentws --env AGENTWS_OWNER_PREFIX=codex -- "$mcp" >/dev/null
      ;;
    copilot|cursor|gemini)
      f="$(setup_json_file "$h")"
      if [ "$2" = off ]; then
        [ -f "$f" ] && json_edit "$f" 'del(.mcpServers.agentws)'
        return 0
      fi
      json_edit "$f" --arg c "$mcp" --arg p "$h" --arg t "$h" '
        .mcpServers.agentws = ({command:$c, args:[], env:{AGENTWS_OWNER_PREFIX:$p}}
          + (if $t == "copilot" then {type:"local", tools:["*"]}
             elif $t == "cursor" then {type:"stdio"} else {} end))'
      ;;
  esac
}

# Claude Code SessionStart hook: shows the farm to every new session.
setup_claude_hook() { # setup_claude_hook <on|off>
  local f="$HOME/.claude/settings.json"
  [ "$1" = off ] && [ ! -f "$f" ] && return 0
  json_edit "$f" --arg mark "$SETUP_HOOK_MARK" --arg cmd "$AGENTWS_BIN_DIR/agentws hook session-start" --arg on "$1" '
    .hooks.SessionStart = ([(.hooks.SessionStart // [])[]
        | .hooks = [(.hooks // [])[] | select((.command // "") | contains($mark) | not)]
        | select(.hooks | length > 0)]
      + (if $on == "on" then [{hooks:[{type:"command", command:$cmd}]}] else [] end))
    | if (.hooks.SessionStart | length) == 0 then del(.hooks.SessionStart) else . end
    | if (.hooks | length) == 0 then del(.hooks) else . end'
}

setup_state() { # setup_state <harness> -> "mcp skill" words: yes/no
  local h="$1" m=no s=no f
  case "$h" in
    claude) [ -f "$HOME/.claude.json" ] && jq -e '.mcpServers.agentws' "$HOME/.claude.json" >/dev/null 2>&1 && m=yes ;;
    codex)  grep -q '^\[mcp_servers\.agentws\]' "$HOME/.codex/config.toml" 2>/dev/null && m=yes ;;
    *)      f="$(setup_json_file "$h")"
            [ -f "$f" ] && jq -e '.mcpServers.agentws' "$f" >/dev/null 2>&1 && m=yes ;;
  esac
  [ -L "$(setup_skill_dir "$h")/agentws" ] && s=yes
  printf '%s %s' "$m" "$s"
}

# setup [harness...] [--check|--remove|--refresh]
#   no names   every detected harness
#   --check    report wiring, change nothing
#   --remove   undo the wiring
#   --refresh  re-link skills and hooks only where already set up (run by update)
cmd_setup() {
  local mode=on names="" a h st objs=() rc=0
  for a in "$@"; do
    case "$a" in
      --check)   mode=check ;;
      --remove)  mode=off ;;
      --refresh) mode=refresh ;;
      all)       names="$SETUP_HARNESSES" ;;
      claude|codex|copilot|cursor|gemini) names="${names:+$names }$a" ;;
      *) printf 'setup: unknown harness %s (%s)\n' "$a" "$SETUP_HARNESSES" >&2; return 2 ;;
    esac
  done
  if [ -z "$names" ]; then
    for h in $SETUP_HARNESSES; do setup_detected "$h" && names="${names:+$names }$h"; done
  fi
  if [ -z "$names" ]; then
    printf 'setup: no supported harness found (%s)\n' "$SETUP_HARNESSES" >&2
  fi
  if [ "$mode" != check ] && [ "$mode" != refresh ] && ! command -v jq >/dev/null 2>&1; then
    printf 'setup: jq is required (the MCP server needs it too)\n' >&2
    return 1
  fi

  for h in $names; do
    case "$mode" in
      check) : ;;
      refresh)
        st="$(setup_state "$h")"
        [ "${st#* }" = yes ] && setup_link_skill "$h" on
        [ "$h" = claude ] && [ "${st%% *}" = yes ] && setup_claude_hook on
        ;;
      *)
        [ "${QUIET:-0}" -eq 1 ] || printf '%s %s\n' "$([ "$mode" = on ] && echo wiring || echo removing)" "$h" >&2
        setup_mcp "$h" "$mode" || { printf '  %s: MCP registration failed\n' "$h" >&2; rc=1; }
        setup_link_skill "$h" "$mode" || rc=1
        [ "$h" = claude ] && { setup_claude_hook "$mode" || rc=1; }
        ;;
    esac
    st="$(setup_state "$h")"
    objs+=("$(printf '{"harness":%s,"mcp":%s,"skill":%s}' "$(jstr "$h")" \
      "$(jbool "$([ "${st%% *}" = yes ] && echo 1)")" "$(jbool "$([ "${st#* }" = yes ] && echo 1)")")")
    [ "${JSON:-0}" -eq 1 ] || [ "$mode" = refresh ] || \
      printf '  %-8s mcp:%-3s skill:%s\n' "$h" "${st%% *}" "${st#* }" >&2
  done

  if [ "${JSON:-0}" -eq 1 ]; then
    printf '{"harnesses":[%s]}' "$(jjoin "${objs[@]+"${objs[@]}"}")"
  elif [ "$mode" = on ] && [ -n "$names" ]; then
    printf 'Restart open agent sessions to pick up the MCP server and skill.\n' >&2
  fi
  return $rc
}
