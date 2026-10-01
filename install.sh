#!/usr/bin/env bash
# install.sh - install agentws and wire it into your AI coding tools.
#
#   curl -fsSL https://raw.githubusercontent.com/esola-thomas/agentws/main/install.sh | bash
#
# Piped, it clones agentws into ~/.local/share/agentws (a managed install that
# updates itself daily). Run from a checkout, it links that checkout instead
# (a dev install that never updates itself).
#
# Options:
#   --no-setup      link the CLI only; skip wiring AI harnesses
#   --uninstall     remove harness wiring, links, and a managed install
#   --check         report what is installed, change nothing
# Environment:
#   AGENTWS_HOME            managed install dir   (default ~/.local/share/agentws)
#   AGENTWS_PREFIX          where links go        (default ~/.local/bin)
#   AGENTWS_UPDATE_CHANNEL  stable (releases, default) or main

# Everything runs from main, called on the last line, so a truncated download
# executes nothing.
main() {
  set -uo pipefail
  local repo="${AGENTWS_REPO:-https://github.com/esola-thomas/agentws.git}"
  local home="${AGENTWS_HOME:-$HOME/.local/share/agentws}"
  local prefix="${AGENTWS_PREFIX:-$HOME/.local/bin}"
  local mode=install setup=1 src="" arg

  for arg in "$@"; do
    case "$arg" in
      --uninstall) mode=uninstall ;;
      --check)     mode=check ;;
      --no-setup)  setup=0 ;;
      -h|--help)   printf '%s\n' "Usage: install.sh [--no-setup|--uninstall|--check]  (see the header of install.sh)"; return 0 ;;
      *)           err "unknown option $arg"; return 2 ;;
    esac
  done

  # Running from a checkout? Then that checkout is the install.
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    [ -x "$src/bin/agentws" ] || src=""
  fi

  case "$mode" in
    check)
      if [ -L "$prefix/agentws" ]; then
        say "agentws -> $(readlink "$prefix/agentws")"
        "$prefix/agentws" version
        "$prefix/agentws" setup --check
      else
        say "agentws is not installed in $prefix"
      fi
      return 0 ;;
    uninstall)
      if [ -x "$prefix/agentws" ]; then "$prefix/agentws" setup --remove all || true; fi
      local n
      for n in agentws agentws-mcp; do
        [ -L "$prefix/$n" ] && rm -f "$prefix/$n" && say "removed $prefix/$n"
      done
      if [ -f "$home/.git/agentws-managed" ]; then
        rm -rf "$home" && say "removed $home"
      fi
      return 0 ;;
  esac

  need git || return 1
  need jq  || warn "jq not found: the CLI works, but the MCP server and harness setup need it"

  if [ -z "$src" ]; then
    src="$home"
    if [ -f "$src/.git/agentws-managed" ]; then
      say "updating $src"
      "$src/bin/agentws" update || return 1
    else
      [ -e "$src" ] && { err "$src exists and is not an agentws install; set AGENTWS_HOME"; return 1; }
      say "cloning agentws into $src"
      mkdir -p "$(dirname "$src")" && git clone --quiet "$repo" "$src" || return 1
      local tag
      tag="$(git -C "$src" tag -l 'v[0-9]*' --sort=-v:refname | head -1)"
      if [ -n "$tag" ] && [ "${AGENTWS_UPDATE_CHANNEL:-stable}" = stable ]; then
        git -C "$src" -c advice.detachedHead=false checkout --quiet --detach "$tag" || return 1
      fi
      printf 'channel=%s\n' "${AGENTWS_UPDATE_CHANNEL:-stable}" > "$src/.git/agentws-managed"
    fi
  else
    say "dev install from $src (updates with git pull, not automatically)"
  fi

  mkdir -p "$prefix" || return 1
  link "$src/bin/agentws" "$prefix/agentws" || return 1
  link "$src/mcp/agentws-mcp" "$prefix/agentws-mcp" || return 1
  case ":$PATH:" in
    *":$prefix:"*) ;;
    *) warn "$prefix is not on your PATH. Add to your shell profile: export PATH=\"$prefix:\$PATH\"" ;;
  esac

  if [ "$setup" -eq 1 ] && command -v jq >/dev/null 2>&1; then
    say ""
    "$src/bin/agentws" setup || warn "harness setup reported a problem; rerun: agentws setup"
  fi

  say ""
  say "agentws $("$src/bin/agentws" version | sed 's/^agentws //') installed."
  say "Next, inside the repo your agents work on:"
  say "  agentws init        # creates a farm of 3 isolated checkouts next to it"
}

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
err()  { printf 'ERROR %s\n' "$*" >&2; }
need() { command -v "$1" >/dev/null 2>&1 || { err "$1 not found on PATH"; return 1; }; }

link() { # link <target> <dest>
  if [ -e "$2" ] && [ ! -L "$2" ]; then
    err "$2 exists and is not a symlink; remove it first"
    return 1
  fi
  ln -sfn "$1" "$2"
}

if [ -z "${BASH_VERSION:-}" ]; then
  printf 'install.sh needs bash: curl -fsSL <url> | bash\n' >&2
  exit 1
fi
main "$@"
