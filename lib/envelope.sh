# envelope.sh - the uniform --json envelope.
#
# Closes the wsctl:797 gap where claim/lock/unlock/sync/prune/create rejected
# --json with rc 2. Every command now has a JSON form and every JSON form has
# the same shape:
#
#   {"ok":bool,"command":str,"data":<object|null>,"error":null|{"code":str,"message":str}}
#
# Exactly one line on stdout. Human narrative always goes to stderr, so a
# parser reading stdout never sees prose.

# Stable code -> exit status. Callers match on the string, scripts on the
# number; neither may be renumbered without a version bump.
envelope_exit_code() { # envelope_exit_code <code>
  case "${1-}" in
    OK)          printf '0' ;;
    EUSAGE)      printf '2' ;;
    ECONFIG)     printf '3' ;;
    ELOCKED)     printf '4' ;;
    ENOSLOT)     printf '5' ;;
    ENOTFOUND)   printf '6' ;;
    EPROVIDER)   printf '7' ;;
    EGIT)        printf '8' ;;
    *)           printf '1' ;;
  esac
}

# Print the envelope. <data> must already be a JSON value, or empty for null.
envelope_emit() { # envelope_emit <command> <ok 0|1> <data-json> [code] [message]
  local cmd="$1" ok="$2" data="${3-}" code="${4-}" msg="${5-}" err
  [ -n "$data" ] || data="null"
  if [ "$ok" = "1" ]; then
    err="null"
  else
    err="$(printf '{"code":%s,"message":%s}' "$(jstr "${code:-EFAIL}")" "$(jstr "$msg")")"
  fi
  printf '{"ok":%s,"command":%s,"data":%s,"error":%s}\n' \
    "$(jbool "$ok")" "$(jstr "$cmd")" "$data" "$err"
}

envelope_ok()  { envelope_emit "$1" 1 "${2-}"; }

envelope_err() { # envelope_err <command> <code> <message>
  envelope_emit "$1" 0 "" "$2" "$3"
  exit "$(envelope_exit_code "$2")"
}

# Run a command function and wrap it.
#
# Not in JSON mode this is a plain call. In JSON mode the function's stdout is
# captured and becomes `data`; its stderr is passed through untouched so the
# narrative still reaches a human, and its tail supplies the error message when
# the function fails. A function that dies only kills the capture subshell, so
# a die() inside a command still produces a well-formed envelope.
envelope_run() { # envelope_run <command-name> <function> [args...]
  local cmd="$1" fn="$2"; shift 2
  if [ "${JSON:-0}" -ne 1 ]; then
    "$fn" "$@"
    return $?
  fi

  local errf out rc msg code
  errf="$(mktemp "${TMPDIR:-/tmp}/agentws.XXXXXX")" || die "cannot create temp file"
  out="$("$fn" "$@" 2>"$errf")"; rc=$?
  cat "$errf" >&2

  if [ $rc -eq 0 ]; then
    case "$out" in
      '{'*|'['*) envelope_emit "$cmd" 1 "$out" ;;
      *)         envelope_emit "$cmd" 1 "" ;;
    esac
    rm -f "$errf"
    return 0
  fi

  # BSD sed has no \x escape, so the ESC byte must be literal in the pattern.
  local esc; esc=$(printf '\033')
  msg="$(sed -e "s/${esc}\[[0-9;]*m//g" "$errf" | grep -v '^[[:space:]]*$' | tail -3 | tr '\n' ' ')"
  rm -f "$errf"
  [ -n "$msg" ] || msg="$cmd failed with rc $rc"
  code="$(envelope_code_for_rc "$rc")"
  envelope_emit "$cmd" 0 "" "$code" "$msg"
  return "$(envelope_exit_code "$code")"
}

# A command function signals a specific failure class by returning the exit
# code from envelope_exit_code. Anything else is a generic failure.
envelope_code_for_rc() { # envelope_code_for_rc <rc>
  case "${1-}" in
    2) printf 'EUSAGE' ;;
    3) printf 'ECONFIG' ;;
    4) printf 'ELOCKED' ;;
    5) printf 'ENOSLOT' ;;
    6) printf 'ENOTFOUND' ;;
    7) printf 'EPROVIDER' ;;
    8) printf 'EGIT' ;;
    *) printf 'EFAIL' ;;
  esac
}

# Narrative line. Goes to stderr under --json so stdout stays parseable.
say() {
  if [ "${JSON:-0}" -eq 1 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi
}

sayf() { # sayf <format> [args...]
  local f="$1"; shift
  # shellcheck disable=SC2059
  if [ "${JSON:-0}" -eq 1 ]; then printf "$f" "$@" >&2; else printf "$f" "$@"; fi
}
