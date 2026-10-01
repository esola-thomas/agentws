# setup.sh - commands that run before a config exists: init, use, setup, hook.
#
# setup wires each installed AI harness to THIS checkout: the MCP server is
# registered by absolute path and the skill is a symlink into skills/agentws.
# Because every harness points at one checkout, `agentws update` upgrades all
# of them at once and there is never a second copy to drift.

AGENTWS_DEFAULT_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/agentws/default.yml"
SETUP_HARNESSES="claude codex copilot cursor gemini"
# The hook is found again by this marker; the full command carries the quoted
# absolute path so it runs even when ~/.local/bin is not on the harness's PATH.
SETUP_HOOK_MARK="hook session-start"

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
      # Re-running init --force keeps the slots that already exist.
      if [ ! -e "$root/${i}_$top" ]; then
        "$AGENTWS_BIN_DIR/agentws" --config "$f" create "$i" >&2 || return 7
      fi
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
setup_detected() { # setup_detected <harness>: is its command on PATH
  case "$1" in
    claude|codex|copilot|gemini) command -v "$1" >/dev/null 2>&1 ;;
    cursor) command -v cursor >/dev/null 2>&1 || command -v cursor-agent >/dev/null 2>&1 ;;
    *) return 1 ;;
  esac
}

# The MCP server needs bash 4.1+. Candidates are tried in order; a bare name is
# looked up on PATH. AGENTWS_SETUP_BASH_CANDIDATES (colon-separated) overrides
# the list for tests.
SETUP_BASH_CANDIDATES="bash:/opt/homebrew/bin/bash:/usr/local/bin/bash"

# setup_mcp_bash: on success prints "" when the PATH bash qualifies (the server
# runs through its shebang) or the absolute path of the bash to run it with.
# On failure prints the version of the first bash found, or "none", returns 1.
setup_mcp_bash() {
  local list="${AGENTWS_SETUP_BASH_CANDIDATES:-$SETUP_BASH_CANDIDATES}" c p v maj min found="" IFS=:
  for c in $list; do
    case "$c" in
      */*) [ -x "$c" ] || continue; p="$c" ;;
      *)   p="$(command -v "$c" 2>/dev/null)" || continue ;;
    esac
    # shellcheck disable=SC2016
    v="$("$p" -c 'printf "%s %s %s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "$BASH_VERSION"' 2>/dev/null)" || continue
    maj="${v%% *}"; v="${v#* }"; min="${v%% *}"; v="${v#* }"
    case "$maj.$min" in .*|*.|*[!0-9.]*) continue ;; esac
    [ -n "$found" ] || found="$v"
    if [ "$maj" -gt 4 ] || { [ "$maj" -eq 4 ] && [ "$min" -ge 1 ]; }; then
      case "$c" in */*) printf '%s' "$p" ;; esac
      return 0
    fi
  done
  printf '%s' "${found:-none}"
  return 1
}

setup_bash_msg() { # setup_bash_msg <found-version>
  printf 'MCP server needs bash 4.1+ (found %s). Install it (macOS: brew install bash), then rerun: agentws setup' "$1"
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

# Rewrite a JSON file through jq. Missing file starts as {}, created private.
# The result is written back IN PLACE, through any symlink, so the file keeps
# its inode, mode, and link: a dotfiles symlink to a 600 file holding secrets
# stays exactly that. jq runs first, so a jq failure never touches the file.
json_edit() { # json_edit <file> <jq-args...>
  local f="$1" tmp; shift
  mkdir -p "$(dirname "$f")" || return 1
  [ -s "$f" ] || ( umask 077; printf '{}\n' > "$f" ) || return 1
  tmp="$(umask 077; mktemp "${TMPDIR:-/tmp}/agentws-json.XXXXXX")" || return 1
  if jq "$@" "$f" > "$tmp"; then
    cat "$tmp" > "$f" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"; return 1
  fi
  rm -f "$tmp"
}

setup_link_skill() { # setup_link_skill <harness> <on|off>
  local d l
  d="$(setup_skill_dir "$1")"; l="$d/agentws"
  if [ "$2" = off ]; then
    # Only our own link; ~/.agents/skills is shared by four harnesses, so the
    # link stays while any of them is still wired.
    case "$(readlink "$l" 2>/dev/null)" in
      "$AGENTWS_HOME_DIR/skills/agentws") ;;
      *) return 0 ;;
    esac
    if [ "$1" != claude ]; then
      local o
      for o in codex copilot cursor gemini; do
        [ "$o" = "$1" ] && continue
        case "$(setup_state "$o")" in "yes "*) return 0 ;; esac
      done
    fi
    rm -f "$l"
    return 0
  fi
  if [ -e "$l" ] && [ ! -L "$l" ]; then
    printf '  %s exists and is not a symlink; leaving it\n' "$l" >&2
    return 0
  fi
  mkdir -p "$d" && ln -sfn "$AGENTWS_HOME_DIR/skills/agentws" "$l"
}

# The owner prefix already on the agentws entry, so re-wiring keeps it:
# changing a prefix orphans the locks held under the old one.
setup_prefix() { # setup_prefix <harness> -> prefix, default the harness name
  local h="$1" p="" f
  case "$h" in
    claude) f="$HOME/.claude.json" ;;
    codex)  f="$HOME/.codex/config.toml" ;;
    *)      f="$(setup_json_file "$h")" ;;
  esac
  if [ -f "$f" ]; then
    if [ "$h" = codex ]; then
      p="$(awk '
        /^[ \t]*\[/ { sec = $0; gsub(/[ \t]/, "", sec); next }
        (sec == "[mcp_servers.agentws.env]" || sec == "[mcp_servers.agentws]") &&
        /AGENTWS_OWNER_PREFIX"?[ \t]*=[ \t]*"/ {
          sub(/.*AGENTWS_OWNER_PREFIX"?[ \t]*=[ \t]*"/, ""); sub(/".*/, ""); print; exit
        }' "$f" 2>/dev/null)"
    else
      p="$(jq -r '.mcpServers.agentws.env.AGENTWS_OWNER_PREFIX // empty | strings' "$f" 2>/dev/null)"
    fi
  fi
  printf '%s' "${p:-$h}"
}

# SETUP_MCP_BASH (set by cmd_setup) is empty to run the server through its
# shebang, or the absolute bash to run it with.
setup_mcp() { # setup_mcp <harness> <on|off>
  local h="$1" mcp="$AGENTWS_HOME_DIR/mcp/agentws-mcp" f pre cmd=()
  if [ -n "${SETUP_MCP_BASH:-}" ]; then cmd=("$SETUP_MCP_BASH" "$mcp"); else cmd=("$mcp"); fi
  pre="$(setup_prefix "$h")"
  case "$h" in
    claude)
      command -v claude >/dev/null 2>&1 || { printf '  claude CLI not on PATH; skipped MCP\n' >&2; return 0; }
      claude mcp remove --scope user agentws >/dev/null 2>&1 || true
      [ "$2" = off ] && return 0
      claude mcp add agentws --scope user --env "AGENTWS_OWNER_PREFIX=$pre" -- "${cmd[@]+"${cmd[@]}"}" >/dev/null
      ;;
    codex)
      command -v codex >/dev/null 2>&1 || { printf '  codex CLI not on PATH; skipped MCP\n' >&2; return 0; }
      codex mcp remove agentws >/dev/null 2>&1 || true
      [ "$2" = off ] && return 0
      codex mcp add agentws --env "AGENTWS_OWNER_PREFIX=$pre" -- "${cmd[@]+"${cmd[@]}"}" >/dev/null
      ;;
    copilot|cursor|gemini)
      f="$(setup_json_file "$h")"
      if [ "$2" = off ]; then
        [ -f "$f" ] && json_edit "$f" 'del(.mcpServers.agentws)'
        return 0
      fi
      json_edit "$f" --arg c "${cmd[0]}" --arg a "${SETUP_MCP_BASH:+$mcp}" --arg p "$pre" --arg t "$h" '
        .mcpServers.agentws = ({command:$c, args:(if $a == "" then [] else [$a] end), env:{AGENTWS_OWNER_PREFIX:$p}}
          + (if $t == "copilot" then {type:"local", tools:["*"]}
             elif $t == "cursor" then {type:"stdio"} else {} end))'
      ;;
  esac
}

# Claude Code SessionStart hook: shows the farm to every new session.
setup_claude_hook() { # setup_claude_hook <on|off>
  local f="$HOME/.claude/settings.json"
  [ "$1" = off ] && [ ! -f "$f" ] && return 0
  json_edit "$f" --arg mark "$SETUP_HOOK_MARK" --arg cmd "$(sq "$AGENTWS_BIN_DIR/agentws") hook session-start" --arg on "$1" '
    def ours: (.command // "") | (contains("agentws") and contains($mark));
    .hooks.SessionStart = ([(.hooks.SessionStart // [])[]
        | if has("hooks") then .hooks = [.hooks[] | select(ours | not)] else . end
        | select((has("hooks") | not) or (.hooks | length > 0))]
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
#   no names   every harness whose command is on PATH
#   --check    report wiring, change nothing
#   --remove   undo the wiring
#   --refresh  re-link skills only where already set up (run by update)
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
  # Without a bash that can run the server, MCP is reported and left unwired.
  local SETUP_MCP_BASH="" mcp_ok=1
  if [ -n "$names" ] && { [ "$mode" = on ] || [ "$mode" = check ]; }; then
    if ! SETUP_MCP_BASH="$(setup_mcp_bash)"; then
      mcp_ok=0
      printf 'setup: %s\n' "$(setup_bash_msg "$SETUP_MCP_BASH")" >&2
      SETUP_MCP_BASH=""
    fi
  fi

  for h in $names; do
    case "$mode" in
      check) : ;;
      refresh)
        st="$(setup_state "$h")"
        [ "${st#* }" = yes ] && setup_link_skill "$h" on
        ;;
      *)
        [ "${QUIET:-0}" -eq 1 ] || printf '%s %s\n' "$([ "$mode" = on ] && echo wiring || echo removing)" "$h" >&2
        if [ "$mcp_ok" -eq 1 ]; then
          setup_mcp "$h" "$mode" || { printf '  %s: MCP registration failed\n' "$h" >&2; rc=1; }
        fi
        setup_link_skill "$h" "$mode" || rc=1
        [ "$h" = claude ] && { setup_claude_hook "$mode" || rc=1; }
        ;;
    esac
    st="$(setup_state "$h")"
    [ "$mcp_ok" -eq 1 ] || st="no ${st#* }"
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
