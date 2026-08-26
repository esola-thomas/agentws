#!/usr/bin/env bash
# install.sh - symlink agentws and its MCP server onto PATH. No build step.
#
# Usage:
#   ./install.sh                  install into ~/.local/bin
#   ./install.sh /usr/local/bin   install into a chosen directory
#   ./install.sh --uninstall      remove the symlinks
#   ./install.sh --check          report what is installed, change nothing

set -uo pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  printf 'install.sh: this requires bash, not sh/dash. Run: bash install.sh\n' >&2
  exit 1
fi

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREFIX="${AGENTWS_PREFIX:-$HOME/.local/bin}"
MODE=install

for arg in "$@"; do
  case "$arg" in
    --uninstall) MODE=uninstall ;;
    --check)     MODE=check ;;
    -h|--help)   sed -n '2,9p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*)          printf 'install.sh: unknown option %s\n' "$arg" >&2; exit 2 ;;
    *)           PREFIX="$arg" ;;
  esac
done

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*" >&2; }
die()  { printf 'ERROR %s\n' "$*" >&2; exit 1; }

for f in "$SRC/bin/agentws" "$SRC/mcp/agentws-mcp"; do
  [ -f "$f" ] || die "not found: $f (run install.sh from inside the agentws checkout)"
done

case "$MODE" in
check)
  say "source:  $SRC"
  say "prefix:  $PREFIX"
  for n in agentws agentws-mcp; do
    t="$PREFIX/$n"
    if [ -L "$t" ]; then
      say "  $n -> $(readlink "$t")"
    elif [ -e "$t" ]; then
      say "  $n present but is not a symlink"
    else
      say "  $n not installed"
    fi
  done
  exit 0
  ;;
uninstall)
  for n in agentws agentws-mcp; do
    t="$PREFIX/$n"
    if [ -L "$t" ]; then
      rm -- "$t" && say "removed $t"
    elif [ -e "$t" ]; then
      warn "$t is not a symlink, leaving it alone"
    fi
  done
  exit 0
  ;;
esac

command -v git >/dev/null 2>&1 || die "git not found on PATH"
command -v jq  >/dev/null 2>&1 || warn "jq not found. The CLI works without it; agentws-mcp requires it."

mkdir -p "$PREFIX" || die "cannot create $PREFIX"
[ -w "$PREFIX" ]   || die "$PREFIX is not writable. Pick another prefix: ./install.sh ~/bin"

chmod +x "$SRC/bin/agentws" "$SRC/mcp/agentws-mcp" 2>/dev/null || true

link() { # link <target> <name>
  local target="$1" name="$2" dest="$PREFIX/$2"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    die "$dest exists and is not a symlink. Remove it first."
  fi
  ln -sfn "$target" "$dest" || die "failed to link $dest"
  say "linked $dest -> $target"
}

link "$SRC/bin/agentws"      agentws
link "$SRC/mcp/agentws-mcp"  agentws-mcp

case ":$PATH:" in
  *":$PREFIX:"*) ;;
  *) warn "$PREFIX is not on your PATH. Add: export PATH=\"$PREFIX:\$PATH\"" ;;
esac

say ""
say "Next:"
say "  cd <your repo> && agentws init"
say "  agentws status"
say ""
say "MCP config fragments to merge into your agent tool:"
say "  $SRC/mcp/claude_code.example.json"
say "  $SRC/mcp/copilot.example.json"
