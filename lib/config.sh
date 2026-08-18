# config.sh - .agentws.yml discovery, strict-subset YAML parser, canonicalisation.
#
# The parser accepts a documented strict subset and nothing else. Anything it
# does not recognise is a loud, line-numbered error. It never drops a key.
#
# Supported:
#   key: value                 flat scalar, optionally "quoted" or 'quoted'
#   key: [a, b, c]             inline list
#   key:                       followed by "  - item" block list lines
#   provider_opts:             exactly one level of nesting, scalars only
#   # comment                  full-line or trailing
# Not supported: anchors/aliases, tabs, multi-line scalars, nested maps outside
# provider_opts, quoted keys, documents beyond the first.

AGENTWS_CONFIG_FILE=""
AGENTWS_P_KEYS=""

config_find() { # -> path on stdout, or exit 3
  local d
  if [ -n "${AGENTWS_CONFIG:-}" ]; then
    case "$AGENTWS_CONFIG" in
      /*) ;;
      *) die "AGENTWS_CONFIG must be an absolute path: $AGENTWS_CONFIG" ;;
    esac
    [ -f "$AGENTWS_CONFIG" ] || die "AGENTWS_CONFIG does not exist: $AGENTWS_CONFIG"
    printf '%s' "$AGENTWS_CONFIG"; return 0
  fi
  d="$(pwd -P)"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    if [ -f "$d/.agentws.yml" ]; then printf '%s' "$d/.agentws.yml"; return 0; fi
    [ "$d" = "${HOME:-}" ] && break
    d="$(dirname "$d")"
  done
  [ -f "/.agentws.yml" ] && { printf '%s' "/.agentws.yml"; return 0; }
  if [ -n "${AGENTWS_ROOT:-}" ] && [ -f "${AGENTWS_ROOT}/.agentws.yml" ]; then
    printf '%s' "${AGENTWS_ROOT}/.agentws.yml"; return 0
  fi
  printf 'agentws: no .agentws.yml found; run: agentws init\n' >&2
  exit 3
}

# Strip a trailing comment, then surrounding quotes. A quoted value ends at its
# closing quote, so a '#' inside quotes is data, not a comment.
config_scalar() { # config_scalar <raw>
  local v="${1-}" rest
  case "$v" in
    '"'*)
      rest="${v#\"}"
      case "$rest" in *'"'*) printf '%s' "${rest%%\"*}"; return 0 ;; esac ;;
    "'"*)
      rest="${v#\'}"
      case "$rest" in *"'"*) printf '%s' "${rest%%\'*}"; return 0 ;; esac ;;
  esac
  v="$(printf '%s' "$v" | sed -e 's/[[:space:]]#.*$//' -e 's/^#.*$//' -e 's/[[:space:]]*$//')"
  printf '%s' "$v"
}

# Strip a trailing comment from a value that is not a quoted scalar, so that
# list-bracket detection is not defeated by an end-of-line comment.
config_decomment() { # config_decomment <raw>
  printf '%s' "${1-}" | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//'
}

# Turn "[a, b, c]" or a block list accumulation into a space-separated string.
config_inline_list() { # config_inline_list <raw>
  local v="${1-}"
  case "$v" in '['*) v="${v#?}" ;; esac
  case "$v" in *']') v="${v%?}" ;; esac
  printf '%s' "$v" | tr ',' '\n' | while IFS= read -r item || [ -n "$item" ]; do
    item="$(printf '%s' "$item" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    item="$(config_scalar "$item")"
    [ -n "$item" ] && printf '%s ' "$item"
  done
}

# Reject syntax the subset does not cover. Called on every non-blank line.
config_reject() { # config_reject <file> <lineno> <rawline>
  local f="$1" n="$2" l="$3"
  case "$l" in
    *"	"*) die_at "$f" "$n" "tab character; the parser requires spaces only" ;;
  esac
  case "$l" in
    *": &"*|*": \*"*|"&"*|"---"*|"..."*)
      die_at "$f" "$n" "unsupported YAML construct (anchor, alias, or document marker)" ;;
  esac
}

config_parse() { # config_parse <file>
  local f="$1" n=0 raw line key val dval indent cur_list="" cur_key="" in_opts=0

  # Raw values, expanded after the whole file is read.
  local r_version="" r_root="" r_top="" r_provider="" r_default_branch=""
  local r_slots="" r_fmt="" r_ref="" r_excl="" r_ttl="" r_lockdir=""

  while IFS= read -r raw || [ -n "$raw" ]; do
    n=$((n + 1))
    line="$raw"
    # full-line comment or blank
    case "$line" in
      ''|'#'*) continue ;;
    esac
    case "$(printf '%s' "$line" | sed 's/[[:space:]]//g')" in
      '') continue ;;
    esac
    config_reject "$f" "$n" "$line"

    indent="$(printf '%s' "$line" | sed -e 's/[^ ].*$//' | awk '{print length($0)}')"
    [ -z "$indent" ] && indent=0
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

    # block list item
    case "$line" in
      '- '*|'-'*)
        if [ "${line#- }" != "$line" ] || [ "$line" = "-" ]; then
          [ -n "$cur_key" ] || die_at "$f" "$n" "list item with no preceding key"
          val="$(config_scalar "${line#- }")"
          cur_list="${cur_list}${val} "
          continue
        fi
        ;;
    esac

    case "$line" in
      *:*) ;;
      *) die_at "$f" "$n" "not a 'key: value' line and not a '- item' list entry: $line" ;;
    esac

    key="${line%%:*}"
    val="${line#*:}"
    val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    dval="$(config_decomment "$val")"

    case "$key" in
      *[!A-Za-z0-9_]*) die_at "$f" "$n" "unsupported key '$key'; keys must be bare [A-Za-z0-9_]" ;;
      '') die_at "$f" "$n" "empty key" ;;
    esac

    # flush any block list that just ended
    if [ -n "$cur_key" ] && [ -n "$cur_list" ]; then
      case "$cur_key" in
        slots) r_slots="$cur_list" ;;
        exclude_from_claim) r_excl="$cur_list" ;;
      esac
    fi
    cur_list=""; cur_key=""

    if [ "$indent" -gt 0 ]; then
      [ "$in_opts" -eq 1 ] || die_at "$f" "$n" \
        "nested mapping is only supported under 'provider_opts:', found nested key '$key'"
      [ -n "$dval" ] || die_at "$f" "$n" "provider_opts.$key must be a scalar, not a nested map"
      eval "AGENTWS_P_${key}=\"\$(config_scalar \"\$val\")\""
      AGENTWS_P_KEYS="${AGENTWS_P_KEYS}${key} "
      continue
    fi

    in_opts=0
    case "$key" in
      version)            r_version="$(config_scalar "$val")" ;;
      root)               r_root="$(config_scalar "$val")" ;;
      top)                r_top="$(config_scalar "$val")" ;;
      provider)           r_provider="$(config_scalar "$val")" ;;
      default_branch)     r_default_branch="$(config_scalar "$val")" ;;
      slot_name_format)   r_fmt="$(config_scalar "$val")" ;;
      reference_slot)     r_ref="$(config_scalar "$val")" ;;
      ttl_hours)          r_ttl="$(config_scalar "$val")" ;;
      lock_dir)           r_lockdir="$(config_scalar "$val")" ;;
      slots)
        if [ -n "$dval" ]; then
          case "$dval" in
            '['*']') r_slots="$(config_inline_list "$dval")" ;;
            *) die_at "$f" "$n" "slots must be an inline list [a, b] or a block list" ;;
          esac
        else cur_key="slots"; fi ;;
      exclude_from_claim)
        if [ -n "$dval" ]; then
          case "$dval" in
            '['*']') r_excl="$(config_inline_list "$dval")" ;;
            *) die_at "$f" "$n" "exclude_from_claim must be an inline list or a block list" ;;
          esac
        else cur_key="exclude_from_claim"; fi ;;
      provider_opts)
        [ -z "$dval" ] || die_at "$f" "$n" "provider_opts: takes a nested block, not a scalar"
        in_opts=1 ;;
      *) die_at "$f" "$n" "unknown key '$key'" ;;
    esac
  done < "$f"

  # trailing block list at EOF
  if [ -n "$cur_key" ] && [ -n "$cur_list" ]; then
    case "$cur_key" in
      slots) r_slots="$cur_list" ;;
      exclude_from_claim) r_excl="$cur_list" ;;
    esac
  fi

  [ "$r_version" = "1" ] || die "$f: version must be 1, got '${r_version:-<missing>}'"
  [ -n "$r_root" ] || die "$f: 'root' is required"
  [ -n "$r_top" ]  || die "$f: 'top' is required"
  [ -n "$r_slots" ] || die "$f: 'slots' is required"

  AGENTWS_TOP="$r_top"
  AGENTWS_PROVIDER="${r_provider:-worktree}"
  AGENTWS_DEFAULT_BRANCH="${r_default_branch:-main}"
  AGENTWS_SLOT_NAME_FORMAT="${r_fmt:-{slot\}_{top\}}"
  AGENTWS_REFERENCE_SLOT="$r_ref"
  AGENTWS_TTL_HOURS="${r_ttl:-12}"
  AGENTWS_SLOTS="$(printf '%s' "$r_slots" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"
  AGENTWS_EXCLUDE_FROM_CLAIM="$(printf '%s' "$r_excl" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"

  case "$AGENTWS_TTL_HOURS" in
    ''|*[!0-9]*) die "$f: ttl_hours must be a non-negative integer, got '$AGENTWS_TTL_HOURS'" ;;
  esac

  AGENTWS_ROOT="$(config_canon "$(config_expand "$r_root")")"
  AGENTWS_LOCK_DIR="$(config_canon "$(config_expand "${r_lockdir:-{root\}/.agentws/locks}")")"

  # provider_opts values may reference {root}/{top}/{user}; expand in place.
  local k
  for k in $AGENTWS_P_KEYS; do
    eval "AGENTWS_P_${k}=\"\$(config_expand \"\$AGENTWS_P_${k}\")\""
  done

  AGENTWS_CONFIG_FILE="$f"
}

config_expand() { # config_expand <string> [slot]
  local s="${1-}" slot="${2-}"
  case "$s" in
    '~/'*) s="${HOME}/${s#\~/}" ;;
    '~') s="$HOME" ;;
  esac
  s="$(printf '%s' "$s" \
    | sed -e "s|{root}|${AGENTWS_ROOT:-}|g" \
          -e "s|{top}|${AGENTWS_TOP:-}|g" \
          -e "s|{user}|${USER:-}|g" \
          -e "s|{slot}|${slot}|g")"
  printf '%s' "$s"
}

# Canonicalise to an absolute real path. Two symlinked roots must not produce
# two lock dirs for one physical checkout.
config_canon() { # config_canon <path>
  local p="${1-}" parent base
  [ -n "$p" ] || { printf ''; return 0; }
  case "$p" in
    /*) ;;
    *) p="$(pwd -P)/$p" ;;
  esac
  if [ -d "$p" ]; then
    ( cd "$p" 2>/dev/null && pwd -P )
    return 0
  fi
  # Not created yet: canonicalise the deepest existing ancestor, keep the tail.
  parent="$(dirname "$p")"; base="$(basename "$p")"
  local tail="$base"
  while [ ! -d "$parent" ] && [ "$parent" != "/" ]; do
    tail="$(basename "$parent")/$tail"
    parent="$(dirname "$parent")"
  done
  printf '%s/%s' "$( cd "$parent" 2>/dev/null && pwd -P )" "$tail"
}

config_load() {
  local f; f="$(config_find)" || exit $?
  config_parse "$f"
}

# ------------------------------------------------------------------- slots
# Slot naming lives here because the format string is a config value.

slot_name() { # slot_name <slot>
  printf '%s' "$(config_expand "$AGENTWS_SLOT_NAME_FORMAT" "$1")"
}

slot_dir() { # slot_dir <slot> -> absolute path
  printf '%s/%s' "$AGENTWS_ROOT" "$(slot_name "$1")"
}

cmd_config() {
  if [ "${JSON:-0}" -ne 1 ]; then
    printf 'config_file          %s\n' "$AGENTWS_CONFIG_FILE"
    printf 'root                 %s\n' "$AGENTWS_ROOT"
    printf 'top                  %s\n' "$AGENTWS_TOP"
    printf 'provider             %s\n' "$AGENTWS_PROVIDER"
    printf 'default_branch       %s\n' "$AGENTWS_DEFAULT_BRANCH"
    printf 'slots                %s\n' "$AGENTWS_SLOTS"
    printf 'slot_name_format     %s\n' "$AGENTWS_SLOT_NAME_FORMAT"
    printf 'reference_slot       %s\n' "$AGENTWS_REFERENCE_SLOT"
    printf 'exclude_from_claim   %s\n' "$AGENTWS_EXCLUDE_FROM_CLAIM"
    printf 'ttl_hours            %s\n' "$AGENTWS_TTL_HOURS"
    printf 'lock_dir             %s\n' "$AGENTWS_LOCK_DIR"
    local k
    for k in $AGENTWS_P_KEYS; do
      eval "printf 'provider_opts.%-8s %s\n' \"\$k\" \"\$AGENTWS_P_${k}\""
    done
    return 0
  fi
  local k parts=() sl=() ex=() s
  for s in $AGENTWS_SLOTS; do sl+=("$(jstr "$s")"); done
  for s in $AGENTWS_EXCLUDE_FROM_CLAIM; do ex+=("$(jstr "$s")"); done
  for k in $AGENTWS_P_KEYS; do
    parts+=("$(eval "printf '%s:%s' \"\$(jstr \"\$k\")\" \"\$(jstr \"\$AGENTWS_P_${k}\")\"")")
  done
  printf '{"config_file":%s,"version":1,"root":%s,"top":%s,"provider":%s,"default_branch":%s,"slots":[%s],"slot_name_format":%s,"reference_slot":%s,"exclude_from_claim":[%s],"ttl_hours":%s,"lock_dir":%s,"provider_opts":{%s}}\n' \
    "$(jstr "$AGENTWS_CONFIG_FILE")" "$(jstr "$AGENTWS_ROOT")" "$(jstr "$AGENTWS_TOP")" \
    "$(jstr "$AGENTWS_PROVIDER")" "$(jstr "$AGENTWS_DEFAULT_BRANCH")" \
    "$(jjoin "${sl[@]+"${sl[@]}"}")" "$(jstr "$AGENTWS_SLOT_NAME_FORMAT")" \
    "$(jstr "$AGENTWS_REFERENCE_SLOT")" "$(jjoin "${ex[@]+"${ex[@]}"}")" \
    "$(jnum "$AGENTWS_TTL_HOURS")" "$(jstr "$AGENTWS_LOCK_DIR")" \
    "$(jjoin "${parts[@]+"${parts[@]}"}")"
}
