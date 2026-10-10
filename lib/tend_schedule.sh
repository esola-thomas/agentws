# tend_schedule.sh - per-config user scheduler registration.
# shellcheck shell=bash

tend_schedule_config() {
  local p="$AGENTWS_CONFIG_FILE" link
  while [ -L "$p" ]; do
    link="$(readlink "$p")" || return 1
    case "$link" in /*) p="$link" ;; *) p="$(dirname "$p")/$link" ;; esac
  done
  config_canon "$p"
}

tend_schedule_id() {
  tend_schedule_config | cksum | awk '{print $1 "-" $2}'
}

tend_schedule_field() {
  local f="$AGENTWS_ROOT/.agentws/tend-schedule"
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" | head -1
}

tend_schedule_backend() {
  if [ "$(uname -s)" = Darwin ]; then
    command -v launchctl >/dev/null 2>&1 || return 1
    printf launchd
  elif command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    printf systemd
  elif command -v crontab >/dev/null 2>&1; then
    printf cron
  else
    printf 'agentws: no usable user scheduler (systemd, cron, launchd)\n' >&2
    return 1
  fi
}

tend_schedule_systemd_quote() {
  printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g' -e 's/\$/$$/g')"
}

tend_schedule_xml() {
  printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}

tend_schedule_status() {
  local id name backend installed=0 next="" dir cron last interval now
  id="$(tend_schedule_id)" || return 1
  name="agentws-tend@$id"
  backend="$(tend_schedule_field scheduler)"
  if [ "$(tend_schedule_field id)" != "$id" ]; then backend=""; fi
  case "$backend" in
    systemd)
      if systemctl --user is-enabled "$name.timer" >/dev/null 2>&1; then
        installed=1
        next="$(systemctl --user show "$name.timer" --property=NextElapseUSecRealtime --value 2>/dev/null)" || next=""
      fi ;;
    cron)
      cron="$(crontab -l 2>/dev/null)" || cron=""
      if printf '%s\n' "$cron" | grep " # $name\$" >/dev/null; then installed=1; fi ;;
    launchd)
      dir="$HOME/Library/LaunchAgents"
      if [ -f "$dir/$name.plist" ] && launchctl list "$name" >/dev/null 2>&1; then installed=1; fi ;;
  esac
  [ "$next" != n/a ] || next=""
  if [ "$installed" -eq 1 ] && [ -z "$next" ]; then
    last="$(tend_schedule_field installed_at)"
    [ ! -f "$AGENTWS_ROOT/.agentws/$name.last" ] || IFS= read -r last < "$AGENTWS_ROOT/.agentws/$name.last"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    interval="${AGENTWS_TEND_INTERVAL_MINUTES:-15}"
    now="$(date +%s)"
    if [ "$backend" = cron ] && awk -v interval="$interval" \
       'BEGIN { exit !(interval <= 60 && 60 % interval == 0) }'; then
      next="$(awk -v now="$now" -v minute="$(date +%M)" -v second="$(date +%S)" -v interval="$interval" \
        'BEGIN { printf "%.0f", now-second+(interval-minute%interval)*60 }')"
    elif [ "$last" -gt 0 ]; then
      next="$(awk -v last="$last" -v now="$now" -v interval="$interval" \
        'BEGIN { due=last+interval*60; if (due<now) due=now; printf "%.0f", due }')"
    else
      next=""
    fi
  fi
  printf '{"installed":%s,"scheduler":%s,"next_run":%s}\n' \
    "$(jbool "$installed")" "$([ -n "$backend" ] && jstr "$backend" || printf null)" \
    "$([ -n "$next" ] && jstr "$next" || printf null)"
}

tend_schedule_owned() {
  [ ! -e "$1" ] && [ ! -L "$1" ] && return 0
  [ ! -L "$1" ] && grep -Fx "# $2" "$1" >/dev/null 2>&1 && return 0
  printf 'agentws: refusing to overwrite unrelated scheduler file: %s\n' "$1" >&2
  return 1
}

tend_schedule() {
  local action="${1:-status}" id name backend config state runner units plist cron line f cadence="*" gated=1
  if [ "$#" -gt 1 ]; then
    printf 'agentws: tend schedule expects exactly one action\n' >&2
    return 2
  fi
  case "$action" in install|uninstall|status) ;; *)
    printf 'agentws: tend schedule expects install, uninstall, or status\n' >&2; return 2 ;;
  esac
  if [ "$action" = status ]; then
    if [ "${JSON:-0}" -eq 1 ]; then tend_schedule_status
    else printf 'Tend schedule: %s\n' "$(tend_schedule_status)"; fi
    return $?
  fi
  config="$(tend_schedule_config)" || return 1
  # Newlines cannot be represented in the metadata or scheduler formats.
  case "$config$AGENTWS_ROOT$HOME$AGENTWS_BIN_DIR${XDG_CONFIG_HOME:-}${PATH:-}" in
    *'
'*|*$'\r'*) printf 'agentws: scheduler paths must not contain newlines\n' >&2; return 1 ;;
  esac
  id="$(tend_schedule_id)" || return 1
  name="agentws-tend@$id"
  state="$AGENTWS_ROOT/.agentws"
  if [ -L "$state/tend-schedule" ]; then
    printf 'agentws: refusing symlinked scheduler metadata\n' >&2
    return 1
  fi
  runner="$state/$name.sh"
  units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  plist="$HOME/Library/LaunchAgents/$name.plist"
  backend="$(tend_schedule_field scheduler)"
  if [ -n "$backend" ] && [ "$(tend_schedule_field id)" != "$id" ]; then
    printf 'agentws: this farm has a schedule for a different config; uninstall it first\n' >&2
    return 1
  fi
  if [ "$action" = uninstall ] && [ -z "$backend" ]; then
    if [ "${JSON:-0}" -eq 1 ]; then tend_schedule_status
    else printf 'No tend schedule installed for %s\n' "$config"; fi
    return $?
  fi
  [ -n "$backend" ] || backend="$(tend_schedule_backend)" || return 1
  case "$backend" in
    systemd|cron|launchd) ;;
    *) printf 'agentws: unrecognized scheduler metadata: %s\n' "$backend" >&2; return 1 ;;
  esac
  if [ "${DRY:-0}" -eq 1 ]; then
    printf 'Would %s %s using %s\n' "$action" "$name" "$backend" >&2
    [ "${JSON:-0}" -ne 1 ] || tend_schedule_status
    return 0
  fi
  for f in "$runner" "$units/$name.service" "$units/$name.timer"; do
    tend_schedule_owned "$f" "$name" || return 1
  done
  if [ -e "$plist" ] || [ -L "$plist" ]; then
    if [ -L "$plist" ] || ! grep -Fx "<!-- $name -->" "$plist" >/dev/null; then
      printf 'agentws: refusing unrelated launchd file: %s\n' "$plist" >&2; return 1;
    fi
  fi
  if [ "$action" = install ]; then
    if awk -v interval="$AGENTWS_TEND_INTERVAL_MINUTES" \
       'BEGIN { exit !(interval <= 60 && 60 % interval == 0) }'; then
      cadence="*/$AGENTWS_TEND_INTERVAL_MINUTES"; gated=0
      [ "$AGENTWS_TEND_INTERVAL_MINUTES" -ne 60 ] || cadence=0
    fi
    [ "$backend" != launchd ] || gated=0
    mkdir -p "$state" || return 1
    (
      umask 077
      {
        printf '#!/bin/bash\n# %s\n' "$name"
        printf 'PATH=%s\nexport PATH\n' "$(sq "$PATH")"
        printf 'last=%s\ninterval=%s\n' "$(sq "$state/$name.last")" "$AGENTWS_TEND_INTERVAL_MINUTES"
        printf 'gated=%s\n' "$gated"
        cat <<'RUNNER'
now=$(date +%s) || exit 1
previous=0
if [ -f "$last" ]; then IFS= read -r previous < "$last"; fi
case "$previous" in ''|*[!0-9]*) previous=0 ;; esac
if [ "$gated" -eq 1 ]; then
  awk -v now="$now" -v previous="$previous" -v interval="$interval" \
    'BEGIN { exit !(now - previous >= interval * 60) }' || exit 0
fi
printf '%s\n' "$now" > "$last" || exit 1
RUNNER
        [ "$backend" = systemd ] || printf 'sleep "$((RANDOM %% 31))"\n'
        printf 'set -- %s --config %s tend --json\n' "$(sq "$AGENTWS_BIN_DIR/agentws")" "$(sq "$config")"
        cat <<'RUNNER'
if command -v ionice >/dev/null 2>&1; then set -- ionice -c 3 "$@"; fi
if command -v nice >/dev/null 2>&1; then set -- nice -n 10 "$@"; fi
exec "$@"
RUNNER
      } > "$runner"
    ) || return 1
    case "$backend" in
      systemd)
        mkdir -p "$units" || return 1
        {
          printf '# %s\n[Unit]\nDescription=agentws maintenance\n[Service]\nType=oneshot\n' "$name"
          printf 'ExecStart=/bin/bash %s\nCPUWeight=10\nIOWeight=10\n' "$(tend_schedule_systemd_quote "$runner")"
        } > "$units/$name.service" || return 1
        local calendar="*"
        [ "$gated" -ne 0 ] || calendar="0/$AGENTWS_TEND_INTERVAL_MINUTES"
        [ "$AGENTWS_TEND_INTERVAL_MINUTES" -ne 60 ] || calendar=00
        printf '# %s\n[Unit]\nDescription=agentws maintenance timer\n[Timer]\nOnCalendar=*-*-* *:%s:00\nPersistent=true\nRandomizedDelaySec=30\n[Install]\nWantedBy=timers.target\n' "$name" "$calendar" > "$units/$name.timer" || return 1
        systemctl --user daemon-reload >&2 && systemctl --user enable --now "$name.timer" >&2 || return 1 ;;
      cron)
        cron="$(crontab -l 2>/dev/null)" || cron=""
        # Cron processes percent signs even inside shell quotes.
        line="$(printf '/bin/bash %s' "$(sq "$runner")" | sed 's/%/\\%/g')"
        { printf '%s\n' "$cron" | grep -v " # $name\$" || true; printf '%s * * * * %s # %s\n' "$cadence" "$line" "$name"; } | crontab - >&2 || return 1 ;;
      launchd)
        mkdir -p "$(dirname "$plist")" || return 1
        {
          printf '<?xml version="1.0" encoding="UTF-8"?>\n<!-- %s -->\n<plist version="1.0"><dict>\n' "$name"
          printf '<key>Label</key><string>%s</string>\n' "$name"
          printf '<key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string></array>\n' "$(tend_schedule_xml "$runner")"
          printf '<key>StartInterval</key><integer>%s</integer>\n<key>RunAtLoad</key><true/>\n<key>LowPriorityIO</key><true/>\n<key>Nice</key><integer>10</integer>\n</dict></plist>\n' \
            "$(awk -v interval="$AGENTWS_TEND_INTERVAL_MINUTES" 'BEGIN { printf "%.0f", interval * 60 }')"
        } > "$plist" || return 1
        launchctl bootout "gui/$(id -u)/$name" >/dev/null 2>&1 || true
        launchctl bootstrap "gui/$(id -u)" "$plist" >&2 || return 1 ;;
    esac
    printf 'installed=1\nscheduler=%s\nid=%s\nconfig=%s\ninstalled_at=%s\n' "$backend" "$id" "$config" "$(date +%s)" > "$state/tend-schedule" || return 1
  else
    case "$backend" in
      systemd)
        systemctl --user disable --now "$name.timer" >&2 || return 1
        rm -f "$units/$name.service" "$units/$name.timer" || return 1
        systemctl --user daemon-reload >&2 || return 1 ;;
      cron)
        cron="$(crontab -l 2>/dev/null)" || cron=""
        { printf '%s\n' "$cron" | grep -v " # $name\$" || true; } | crontab - >&2 || return 1 ;;
      launchd)
        launchctl bootout "gui/$(id -u)/$name" >&2 || return 1
        rm -f "$plist" || return 1 ;;
    esac
    rm -f "$runner" "$state/$name.last" "$state/tend-schedule" || return 1
  fi
  if [ "${JSON:-0}" -eq 1 ]; then tend_schedule_status
  else printf 'Tend schedule %s: %s (%s)\n' "$action" "$name" "$backend"; fi
}
