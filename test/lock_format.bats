#!/usr/bin/env bats
# lock_format.bats - lock file format versioning.
#
# A lock written in a format newer than this build is an uncertain case, so it
# is held and alive: never stale, never claimable, never released or removed
# without a human --force, even when its owner field matches.

load helper

setup()    { setup_sandbox 1 2 3; }
teardown() { teardown_sandbox; }

# A format 2 lock whose owner process is dead and whose TTL has expired, and
# whose owner matches the caller. Under format 1 every one of these would let
# the slot go.
write_future_lock() { # write_future_lock <slot> [owner]
  write_lock_default "$1" "format=2" "owner=${2:-tester}" "owner_pid=4242" "owner_start=777"
  set_lock_age_hours "$1" 48
}

lock_field() { # lock_field <slot> <jq field>
  agentws locks --json 2>/dev/null | jq -r --arg s "$1" ".data.locks[] | select(.slot==\$s) | .$2"
}

@test "a new lock records format=1 as its first line" {
  agentws lock 1 "work" >/dev/null
  [ "$(head -1 "$(lock_path 1)")" = "format=1" ]
  [ "$(grep -c '^format=' "$(lock_path 1)")" -eq 1 ]
  grep -q '^owner=tester$' "$(lock_path 1)"
}

@test "a claimed lock records format=1" {
  agentws claim --json "task" >/dev/null 2>&1
  grep -q '^format=1$' "$(lock_path 1)"
}

@test "a lock without format is format 1 and keeps today's verdicts" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_field 1 format)" = "1" ]
  [ "$(lock_field 1 format_supported)" = "true" ]
  [ "$(lock_reason 1)" = "process_dead" ]
  run agentws lock 1 "taking over"
  [ "$status" -eq 0 ]
  grep -q '^format=1$' "$(lock_path 1)"
}

@test "an explicit format=1 lock is judged exactly like one without format" {
  write_lock_default 1 "format=1" "owner_pid=4242" "owner_start=777"
  [ "$(lock_reason 1)" = "process_dead" ]
  write_lock_default 2 "format=1"
  set_lock_age_hours 2 13
  [ "$(lock_reason 2)" = "ttl" ]
}

@test "a format=2 lock is ALIVE with a dead owner pid and an expired ttl" {
  write_future_lock 1 other
  [ "$(lock_verdict 1)" = "alive" ]
  [ "$(lock_field 1 stale)" = "false" ]
  [ "$(lock_field 1 format)" = "2" ]
  [ "$(lock_field 1 format_supported)" = "false" ]
}

@test "a format=2 lock is never reported as mine, even with a matching owner" {
  write_future_lock 1
  [ "$(lock_field 1 owner)" = "tester" ]
  [ "$(lock_field 1 mine)" = "false" ]
}

@test "an unparseable format is treated as unsupported and ALIVE" {
  write_lock_default 1 "format=2b" "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 48
  [ "$(lock_verdict 1)" = "alive" ]
  [ "$(lock_field 1 format)" = "2b" ]
  [ "$(lock_field 1 format_supported)" = "false" ]
}

@test "format=0 is unsupported: held, not stale, not mine" {
  write_lock_default 1 "format=0" "owner=tester" "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 48
  [ "$(lock_verdict 1)" = "alive" ]
  [ "$(lock_field 1 mine)" = "false" ]
  [ "$(lock_field 1 format_supported)" = "false" ]
  run agentws unlock --json 1
  [ "$status" -eq 9 ]
}

@test "a present but empty format= is unsupported, unlike a missing line" {
  write_lock_default 1 "format=" "owner=tester" "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 48
  [ "$(lock_verdict 1)" = "alive" ]
  [ "$(lock_field 1 mine)" = "false" ]
  [ "$(lock_field 1 format)" = "" ]
  [ "$(lock_field 1 format_supported)" = "false" ]
}

@test "destroy on a format=2 lock refuses with ELOCKFORMAT" {
  write_future_lock 1
  run agentws destroy --json --yes 1
  [ "$status" -eq 9 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.error.code')" = "ELOCKFORMAT" ]
  [ -d "$ROOT/1_proj" ]
  [ -f "$(lock_path 1)" ]
}

@test "sync on a format=2 lock prints the update hint, not --force" {
  write_future_lock 1
  run agentws sync 1
  [[ "$output" == *"agentws update"* ]]
  [[ "$output" != *"Use --force to override"* ]]
}

@test "status --json carries the format fields on the slot lock object" {
  write_future_lock 1
  run agentws status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots[] | select(.slot=="1") | .lock.format_supported')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots[] | select(.slot=="1") | .claimable')" = "false" ]
}

@test "claim skips a format=2 slot even when its owner matches" {
  write_future_lock 1
  local out
  out="$(agentws claim --json "task" 2>/dev/null)"
  [ "$(printf '%s' "$out" | jq -r '.data.slot')" = "2" ]
  grep -q '^format=2$' "$(lock_path 1)"
}

@test "lock by the matching owner refuses with ELOCKFORMAT" {
  write_future_lock 1
  run agentws lock --json 1 "again"
  [ "$status" -eq 9 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.error.code')" = "ELOCKFORMAT" ]
  [[ "$output" == *"agentws update"* ]]
  grep -q '^format=2$' "$(lock_path 1)"
}

@test "lock by another owner refuses with rc 9 rather than taking over" {
  write_future_lock 1 other
  run agentws lock 1 "mine now"
  [ "$status" -eq 9 ]
  grep -q '^owner=other$' "$(lock_path 1)"
}

@test "unlock by the matching owner refuses with ELOCKFORMAT" {
  write_future_lock 1
  run agentws unlock --json 1
  [ "$status" -eq 9 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.error.code')" = "ELOCKFORMAT" ]
  [[ "$output" == *"agentws update"* ]]
  [ -f "$(lock_path 1)" ]
}

@test "recycle by the matching owner refuses with ELOCKFORMAT" {
  write_future_lock 1
  run agentws recycle --json 1
  [ "$status" -eq 9 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.error.code')" = "ELOCKFORMAT" ]
  [ -f "$(lock_path 1)" ]
  grep -q '^format=2$' "$(lock_path 1)"
}

@test "refresh refuses a format=2 slot with ELOCKFORMAT" {
  write_future_lock 1
  run agentws refresh --json 1
  [ "$status" -eq 9 ]
  [ -f "$(lock_path 1)" ]
}

@test "doctor auto-release never removes a format=2 lock" {
  printf 'auto_release: true\nauto_release_minutes: 0\n' >> "$CONFIG"
  write_future_lock 1
  run agentws doctor 1
  [ -f "$(lock_path 1)" ]
  [[ "$output" == *"agentws update"* ]]
}

@test "doctor reports a format=2 lock as a warning naming the fix" {
  write_future_lock 1
  run agentws doctor --json 1
  [ "$status" -eq 0 ]
  local rec
  rec="$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -c '.data.slots[0].checks[] | select(.id=="lock")')"
  [ "$(printf '%s' "$rec" | jq -r '.status')" = "warn" ]
  [[ "$(printf '%s' "$rec" | jq -r '.detail')" == *"agentws update"* ]]
}

@test "status text names the format and the fix" {
  write_future_lock 1
  run agentws status
  [ "$status" -eq 0 ]
  [[ "$output" == *"lock format 2"* ]]
  [[ "$output" == *"agentws update"* ]]
}

@test "unlock --force releases a format=2 lock" {
  write_future_lock 1 other
  run agentws unlock 1 --force
  [ "$status" -eq 0 ]
  [ ! -f "$(lock_path 1)" ]
}
