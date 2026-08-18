# core.sh - escaping, colour, and process primitives.
# Ported from wsctl:78-157. jq is optional; jstr falls back to sed escaping.

# ------------------------------------------------------------------ colour
# Degrade to plain text under --json so no escape sequence can leak into a
# JSON string.
c_red()  { if [ "${JSON:-0}" -eq 1 ]; then printf '%s' "$1"; else printf '\033[31m%s\033[0m' "$1"; fi; }
c_grn()  { if [ "${JSON:-0}" -eq 1 ]; then printf '%s' "$1"; else printf '\033[32m%s\033[0m' "$1"; fi; }
c_yel()  { if [ "${JSON:-0}" -eq 1 ]; then printf '%s' "$1"; else printf '\033[33m%s\033[0m' "$1"; fi; }
c_dim()  { if [ "${JSON:-0}" -eq 1 ]; then printf '%s' "$1"; else printf '\033[2m%s\033[0m'  "$1"; fi; }

# ------------------------------------------------------------------- json out
AGENTWS_JQ_BIN="$(command -v jq 2>/dev/null || true)"

jstr() { # jstr <value> -> properly quoted JSON string
  if [ -n "$AGENTWS_JQ_BIN" ]; then
    printf '%s' "${1-}" | "$AGENTWS_JQ_BIN" -Rs .
  else
    printf '"%s"' "$(printf '%s' "${1-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/[[:cntrl:]]//g')"
  fi
}

jnum() { # jnum <value> -> bare number, defaulting to 0 on anything non-numeric
  local v="${1-}"
  if [[ "$v" =~ ^-?[0-9]+$ ]]; then printf '%s' "$v"; else printf '0'; fi
}

jbool() { if [ "${1-}" = "1" ] || [ "${1-}" = "true" ]; then printf 'true'; else printf 'false'; fi; }

# Single-quote a value for safe shell eval. Any embedded single quote is closed,
# escaped, and reopened ('\''), so a hostile reason string cannot inject.
sq() { printf "'%s'" "$(printf '%s' "${1-}" | sed "s/'/'\\\\''/g")"; }

# Join already-formatted JSON fragments with commas: jjoin "${arr[@]+"${arr[@]}"}"
jjoin() {
  local out="" x
  for x in "$@"; do
    [ -z "$x" ] && continue
    out="${out:+$out,}$x"
  done
  printf '%s' "$out"
}

json_unsupported() { # json_unsupported <cmd>
  printf '{"error":%s}\n' "$(jstr "--json is not supported for '$1'")"
  exit 2
}

die() { printf 'agentws: %s\n' "$*" >&2; exit 1; }

# die with a file:line prefix, for the config parser
die_at() { # die_at <file> <lineno> <message>
  printf 'agentws: %s:%s: %s\n' "$1" "$2" "$3" >&2
  exit 3
}

run() { # run <cmd...>
  if [ "${DRY:-0}" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
    return 0
  fi
  "$@"
}

confirm() { # confirm <prompt>
  [ "${ASSUME_YES:-0}" -eq 1 ] && return 0
  [ "${DRY:-0}" -eq 1 ] && return 0
  local reply
  read -r -p "$1 [y/N] " reply
  [ "$reply" = "y" ] || [ "$reply" = "Y" ]
}

# Lowercase without ${var,,}, which is bash 4 only.
lower() { printf '%s' "${1-}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'; }
