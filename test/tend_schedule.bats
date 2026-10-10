#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SANDBOX="$REPO/test/.tend-sandbox-$$-$BATS_TEST_NUMBER"
  mkdir -p "$SANDBOX/bin" "$SANDBOX/farm" "$SANDBOX/home"
  export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/xdg"
  export FAKE_CRON="$SANDBOX/crontab" FAKE_SYSTEMD="$SANDBOX/systemd"
  export FAKE_UNAME=Linux FAKE_BACKEND=cron
  export PATH="$SANDBOX/bin:$PATH"
  cat > "$SANDBOX/bin/crontab" <<'MOCK'
#!/bin/bash
case "$1" in
  -l) [ -f "$FAKE_CRON" ] && cat "$FAKE_CRON" ;;
  -) cat > "$FAKE_CRON" ;;
esac
MOCK
  cat > "$SANDBOX/bin/systemctl" <<'MOCK'
#!/bin/bash
[ "$FAKE_BACKEND" = systemd ] || exit 1
case "$2" in
  enable) : > "$FAKE_SYSTEMD" ;;
  disable) rm -f "$FAKE_SYSTEMD" ;;
  is-enabled) [ -f "$FAKE_SYSTEMD" ] ;;
  show) printf 'Sat 2026-10-10 02:00:00 UTC\n' ;;
esac
MOCK
  cat > "$SANDBOX/bin/uname" <<'MOCK'
#!/bin/bash
printf '%s\n' "$FAKE_UNAME"
MOCK
  cat > "$SANDBOX/bin/launchctl" <<'MOCK'
#!/bin/bash
case "$1" in
  bootstrap) : > "$FAKE_SYSTEMD" ;;
  bootout) rm -f "$FAKE_SYSTEMD" ;;
  list) [ -f "$FAKE_SYSTEMD" ] ;;
esac
MOCK
  chmod +x "$SANDBOX/bin/"*
  CONFIG="$SANDBOX/farm/config.yml"
  printf 'version: 1\nroot: %s\ntop: proj\nslots: [1]\n' "$SANDBOX/farm" > "$CONFIG"
  export REPO CONFIG
}

teardown() {
  [ ! -d "$SANDBOX" ] || rm -r "$SANDBOX"
}

schedule() {
  bash -uc '
    . "$REPO/lib/core.sh"
    . "$REPO/lib/config.sh"
    . "$REPO/lib/tend_schedule.sh"
    config_parse "$CONFIG"
    AGENTWS_BIN_DIR="${SCHED_BIN:-$REPO/bin}"
    JSON=1 DRY="${DRY:-0}"
    tend_schedule "$1"
  ' schedule "$1"
}

@test "tend config defaults and normalized positive integers" {
  run bash -uc '. "$REPO/lib/core.sh"; . "$REPO/lib/config.sh"; config_parse "$CONFIG"; JSON=1; cmd_config'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.tend_interval_minutes == 15 and .tend_refresh and (.tend_reap|not) and (.tend_fix_env|not) and (.tend_self_update|not)'
  printf 'tend_interval_minutes: 0071\n' >> "$CONFIG"
  run schedule status
  [ "$status" -eq 0 ]
}

@test "invalid interval and bool values are refused" {
  printf 'tend_interval_minutes: 0\n' >> "$CONFIG"
  run schedule status
  [ "$status" -ne 0 ]
  sed '/tend_interval_minutes/d' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  printf 'tend_self_update: maybe\n' >> "$CONFIG"
  run schedule status
  [ "$status" -ne 0 ]
  sed '/tend_self_update/d' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  printf 'tend_refresh:\n' >> "$CONFIG"
  run schedule status
  [ "$status" -ne 0 ]
}

@test "cron install is idempotent, preserves other jobs, and uninstalls" {
  printf '5 * * * * echo unrelated\n' > "$FAKE_CRON"
  printf 'tend_interval_minutes: 71\n' >> "$CONFIG"
  run schedule install
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.installed and .scheduler == "cron" and .next_run == null'
  run schedule install
  [ "$status" -eq 0 ]
  [ "$(grep -c ' # agentws-tend@' "$FAKE_CRON")" -eq 1 ]
  grep -q '^\* \* \* \* \* /bin/bash ' "$FAKE_CRON"
  grep -q '^interval=71$' "$SANDBOX/farm/.agentws/"*.sh
  run schedule uninstall
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.installed|not'
  grep -Fx '5 * * * * echo unrelated' "$FAKE_CRON"
  run schedule uninstall
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.installed|not'
}

@test "dry run changes neither scheduler nor metadata" {
  export DRY=1
  run schedule install
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_CRON" ]
  [ ! -e "$SANDBOX/farm/.agentws" ]
}

@test "systemd uses a persistent calendar with jitter and low weights" {
  export FAKE_BACKEND=systemd
  run schedule install
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.installed and .scheduler == "systemd" and (.next_run != null)'
  grep -Fx 'Persistent=true' "$XDG_CONFIG_HOME/systemd/user/"*.timer
  grep -Fx 'OnCalendar=*-*-* *:*:00' "$XDG_CONFIG_HOME/systemd/user/"*.timer
  grep -Fx 'RandomizedDelaySec=30' "$XDG_CONFIG_HOME/systemd/user/"*.timer
  grep -Fx 'CPUWeight=10' "$XDG_CONFIG_HOME/systemd/user/"*.service
  grep -Fx 'IOWeight=10' "$XDG_CONFIG_HOME/systemd/user/"*.service
  run schedule uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_SYSTEMD" ]
}

@test "launchd escapes XML and unregisters its own job" {
  export FAKE_UNAME=Darwin
  mkdir -p "$SANDBOX/farm & <quoted>"
  mv "$CONFIG" "$SANDBOX/farm & <quoted>/config.yml"
  CONFIG="$SANDBOX/farm & <quoted>/config.yml"
  printf 'version: 1\nroot: %s\ntop: proj\nslots: [1]\n' "$SANDBOX/farm & <quoted>" > "$CONFIG"
  run schedule install
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.installed and .scheduler == "launchd"'
  grep -q 'farm &amp; &lt;quoted&gt;' "$HOME/Library/LaunchAgents/"*.plist
  run schedule uninstall
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_SYSTEMD" ]
}

@test "canonical config symlinks reuse one schedule" {
  run schedule install
  [ "$status" -eq 0 ]
  ln -s "$CONFIG" "$SANDBOX/alias.yml"
  CONFIG="$SANDBOX/alias.yml"
  run schedule install
  [ "$status" -eq 0 ]
  [ "$(grep -c ' # agentws-tend@' "$FAKE_CRON")" -eq 1 ]
}

@test "unrelated scheduler files are never overwritten" {
  export FAKE_BACKEND=systemd
  run schedule install
  [ "$status" -eq 0 ]
  printf 'unrelated\n' > "$XDG_CONFIG_HOME/systemd/user/"*.service
  run schedule install
  [ "$status" -ne 0 ]
  grep -Fx unrelated "$XDG_CONFIG_HOME/systemd/user/"*.service
}

@test "runner safely quotes shell paths and cron percent signs" {
  mkdir -p "$SANDBOX/farm 'quoted% dollar\$"
  mv "$CONFIG" "$SANDBOX/farm 'quoted% dollar\$/config.yml"
  CONFIG="$SANDBOX/farm 'quoted% dollar\$/config.yml"
  printf 'version: 1\nroot: %s\ntop: proj\nslots: [1]\n' "$SANDBOX/farm 'quoted% dollar\$" > "$CONFIG"
  run schedule install
  [ "$status" -eq 0 ]
  grep -F '\%' "$FAKE_CRON"
  run bash -n "$SANDBOX/farm 'quoted% dollar\$/.agentws/"*.sh
  [ "$status" -eq 0 ]
}

@test "elapsed-time guard skips an early wakeup and executes a due run" {
  export SCHED_BIN="$SANDBOX/bin" FAKE_CALL="$SANDBOX/call"
  cat > "$SANDBOX/bin/agentws" <<'MOCK'
#!/bin/bash
printf '%s\n' "$@" > "$FAKE_CALL"
MOCK
  cat > "$SANDBOX/bin/sleep" <<'MOCK'
#!/bin/bash
exit 0
MOCK
  chmod +x "$SANDBOX/bin/agentws" "$SANDBOX/bin/sleep"
  printf 'tend_interval_minutes: 71\n' >> "$CONFIG"
  run schedule install
  [ "$status" -eq 0 ]
  runner="$(printf '%s' "$SANDBOX/farm/.agentws/"*.sh)"
  last="${runner%.sh}.last"
  printf '%s\n' "$(( $(date +%s) - 3600 ))" > "$last"
  run bash "$runner"
  [ "$status" -eq 0 ]
  [ ! -e "$FAKE_CALL" ]
  printf '%s\n' "$(( $(date +%s) - 4300 ))" > "$last"
  run bash "$runner"
  [ "$status" -eq 0 ]
  [ "$(sed -n '2p' "$FAKE_CALL")" = "$CONFIG" ]
  [ "$(sed -n '3p' "$FAKE_CALL")" = tend ]
}

@test "cron removal preserves a different job with a shared marker prefix" {
  run schedule install
  [ "$status" -eq 0 ]
  marker="$(sed -n 's/.* # //p' "$FAKE_CRON")"
  printf '0 0 * * * echo other # %s-extra\n' "$marker" >> "$FAKE_CRON"
  run schedule uninstall
  [ "$status" -eq 0 ]
  grep -Fx "0 0 * * * echo other # $marker-extra" "$FAKE_CRON"
}
