#!/usr/bin/env bats
# lock_matrix.bats - THE 6-CASE LOCK LADDER MATRIX.
#
# The assertion in every case is the verdict, alive or dead, not the wording of
# a message. A false "dead" puts two agents in one checkout, so the ladder's
# only job is to be conservative in every uncertain case.
#
# /proc is faked through AGENTWS_PROC, so all six cases are deterministic and
# run identically on Linux and macOS.

load helper

setup()    { setup_sandbox 1 2 3; }
teardown() { teardown_sandbox; }

# ---------------------------------------------------------------- case 1
# Same host, owner_pid live, owner_start matches -> ALIVE.

@test "case 1: live owner pid with matching start time is ALIVE" {
  mkproc 4242 777
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 1: a live lock reports no stale_reason" {
  mkproc 4242 777
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ -z "$(lock_reason 1)" ]
}

@test "case 1: a different owner gets BUSY with rc 1" {
  mkproc 4242 777
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  run agentws lock 1 "my turn"
  [ "$status" -eq 1 ]
  [[ "$output" == *BUSY* ]]
  # The holder's lock file is untouched.
  grep -q '^owner=other$' "$(lock_path 1)"
}

@test "case 1: a live lock is not claimable" {
  mkproc 4242 777
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  run agentws free --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.data.free | index("1_proj") // "no"')" = "no" ]
}

# ---------------------------------------------------------------- case 2
# Same host, owner_pid absent from /proc -> DEAD, reason process_dead.

@test "case 2: owner pid absent from proc is DEAD" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "dead" ]
}

@test "case 2: stale_reason is process_dead" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_reason 1)" = "process_dead" ]
}

@test "case 2: takeover is permitted and prints the NOTE" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  run agentws lock 1 "taking over"
  [ "$status" -eq 0 ]
  [[ "$output" == *NOTE* ]]
  grep -q '^owner=tester$' "$(lock_path 1)"
}

# ---------------------------------------------------------------- case 3
# Same host, pid present but owner_start DIFFERS: the pid was reused by an
# unrelated process -> DEAD. This is the case a naive rewrite silently loses.

@test "case 3: reused pid with mismatched start time is DEAD" {
  mkproc 4242 999
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "dead" ]
}

@test "case 3: reused pid reports process_dead, not ttl" {
  mkproc 4242 999
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_reason 1)" = "process_dead" ]
}

@test "case 3: a pid present with NO recorded start time stays ALIVE" {
  # Nothing to compare against, so the reuse question is unanswerable.
  mkproc 4242 999
  write_lock_default 1 "owner_pid=4242"
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 3: an unreadable stat file stays ALIVE" {
  mkdir -p "$PROC/4242"
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "alive" ]
}

# ---------------------------------------------------------------- case 4
# A lock recorded on another host, or with no host field, can never be judged
# from this machine's process table -> ALIVE regardless of pid state.

@test "case 4: a different host is ALIVE even when the pid is absent locally" {
  write_lock_default 1 "host=some-other-box" "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 4: an empty host field is ALIVE" {
  write_lock 1 "owner=other" "reason=t" "epoch=$(date +%s)" "host=" \
    "pid=9" "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 4: a cross-host lock does NOT consult the local proc tree" {
  # A local process with this pid exists AND its start time differs, which on
  # the same host would be a definitive case-3 dead. Cross-host must ignore it.
  mkproc 4242 999
  write_lock_default 1 "host=some-other-box" "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 4: a cross-host lock still expires by ttl" {
  write_lock_default 1 "host=some-other-box" "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 13
  [ "$(lock_reason 1)" = "ttl" ]
}

# ---------------------------------------------------------------- case 5
# No owner_pid recorded, because the caller never exported AGENTWS_PID.
# ALIVE below the ttl, "ttl" at or above it. Both sides of the boundary.

@test "case 5: no owner_pid, fresh lock, is ALIVE" {
  write_lock_default 1
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 5: no owner_pid, age just below ttl, is ALIVE" {
  write_lock_default 1
  set_lock_age_hours 1 11
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 5: no owner_pid, age exactly at ttl, is stale with reason ttl" {
  write_lock_default 1
  set_lock_age_hours 1 12
  [ "$(lock_reason 1)" = "ttl" ]
}

@test "case 5: no owner_pid, age past ttl, is stale with reason ttl" {
  write_lock_default 1
  set_lock_age_hours 1 30
  [ "$(lock_reason 1)" = "ttl" ]
}

@test "case 5: a non-numeric owner_pid is treated as absent and stays ALIVE" {
  write_lock_default 1 "owner_pid=notapid" "owner_start=777"
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 5: the plain pid field is NEVER used for liveness" {
  # pid=999999 does not exist in the fake proc tree. If liveness ever consulted
  # it, this fresh lock would read dead and every lock in production would be
  # takeable the instant it was written.
  write_lock_default 1 "pid=999999"
  [ "$(lock_verdict 1)" = "alive" ]
}

# ---------------------------------------------------------------- case 6
# AGENTWS_PROC points at a directory that does not exist: macOS, Git Bash,
# MSYS2. Liveness is unanswerable -> ALIVE always, and the degradation must be
# reported rather than silent.

@test "case 6: no proc directory means ALIVE whatever the pid" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  export AGENTWS_PROC="$SANDBOX/no-such-proc"
  [ "$(lock_verdict 1)" = "alive" ]
}

@test "case 6: no proc directory still honours ttl expiry" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 13
  export AGENTWS_PROC="$SANDBOX/no-such-proc"
  [ "$(lock_reason 1)" = "ttl" ]
}

@test "case 6: locks --json reports liveness_supported false" {
  write_lock_default 1
  export AGENTWS_PROC="$SANDBOX/no-such-proc"
  run agentws locks --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.data.liveness_supported')" = "false" ]
}

@test "case 6: locks --json reports liveness_supported true when proc exists" {
  write_lock_default 1
  run agentws locks --json
  [ "$(printf '%s' "$output" | jq -r '.data.liveness_supported')" = "true" ]
}

@test "case 6: doctor emits the liveness WARN so degradation is never silent" {
  export AGENTWS_PROC="$SANDBOX/no-such-proc"
  run agentws doctor --json 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" |
      jq -r '[.data.slots[].checks[] | select(.id=="liveness" and .status=="warn")] | length')" = "1" ]
}

@test "case 6: lock warns on stderr when liveness is unsupported" {
  export AGENTWS_PROC="$SANDBOX/no-such-proc"
  run agentws lock 1 "work"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TTL only"* ]] || [[ "$output" == *"ttl_hours"* ]]
}

# ------------------------------------------------------- cross: --ignore-pid
# --ignore-pid forces every pid verdict to alive, leaving ttl as the only way a
# lock goes stale. Crossed with the dead cases and with both sides of the ttl.

@test "cross: --ignore-pid makes case 2 (pid absent) read ALIVE" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "dead" ]
  [ "$(lock_verdict 1 --ignore-pid)" = "alive" ]
}

@test "cross: --ignore-pid makes case 3 (pid reused) read ALIVE" {
  mkproc 4242 999
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  [ "$(lock_verdict 1)" = "dead" ]
  [ "$(lock_verdict 1 --ignore-pid)" = "alive" ]
}

@test "cross: --ignore-pid still lets a lock expire by ttl" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 13
  [ "$(lock_reason 1 --ignore-pid)" = "ttl" ]
}

@test "cross: --ignore-pid blocks takeover of a dead-pid lock below ttl" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  run agentws --ignore-pid lock 1 "my turn"
  [ "$status" -eq 1 ]
  [[ "$output" == *BUSY* ]]
}

# ------------------------------------------------------------ cross: ttl
# Every dead-pid case must stay dead on both sides of the ttl boundary, and a
# live pid must survive a ttl that has not yet elapsed.

@test "cross: dead pid below ttl is still dead" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 1
  [ "$(lock_reason 1)" = "process_dead" ]
}

@test "cross: dead pid above ttl reports process_dead, which is checked first" {
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 40
  [ "$(lock_reason 1)" = "process_dead" ]
}

@test "cross: live pid above ttl expires by ttl" {
  mkproc 4242 777
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 13
  [ "$(lock_reason 1)" = "ttl" ]
}

@test "cross: live pid below ttl is alive" {
  mkproc 4242 777
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  set_lock_age_hours 1 11
  [ "$(lock_verdict 1)" = "alive" ]
}

# --------------------------------------------------- owner_pid provenance
# owner_pid comes only from a long-lived session pid the caller exports. It is
# never the agentws process's own $$, which has already exited by the time
# anyone reads the lock.

@test "owner_pid is written only when AGENTWS_PID is exported and live" {
  mkproc 4242 777
  AGENTWS_PID=4242 agentws lock 1 "work" >/dev/null
  grep -q '^owner_pid=4242$' "$(lock_path 1)"
  grep -q '^owner_start=777$' "$(lock_path 1)"
}

@test "owner_pid is absent when AGENTWS_PID is not exported" {
  agentws lock 1 "work" >/dev/null
  ! grep -q '^owner_pid=' "$(lock_path 1)"
}

@test "owner_pid is absent when AGENTWS_PID names a process that is not there" {
  AGENTWS_PID=4242 agentws lock 1 "work" >/dev/null
  ! grep -q '^owner_pid=' "$(lock_path 1)"
}

@test "the recorded pid field is never equal to owner_pid by accident" {
  # pid= is forensic only. It records the agentws process, which is gone.
  mkproc 4242 777
  AGENTWS_PID=4242 agentws lock 1 "work" >/dev/null
  [ "$(sed -n 's/^pid=//p' "$(lock_path 1)")" != "4242" ]
}

@test "legacy WSCTL_PID is honoured as a fallback" {
  mkproc 4242 777
  WSCTL_PID=4242 agentws lock 1 "work" >/dev/null
  grep -q '^owner_pid=4242$' "$(lock_path 1)"
}

# --------------------------------------------------------- unlock scoping
@test "unlock refuses a lock owned by someone else" {
  write_lock_default 1
  run agentws unlock 1
  [ "$status" -eq 1 ]
  [[ "$output" == *REFUSE* ]]
  [ -f "$(lock_path 1)" ]
}

@test "unlock --force releases someone else's lock" {
  write_lock_default 1
  run agentws unlock 1 --force
  [ "$status" -eq 0 ]
  [ ! -f "$(lock_path 1)" ]
}

@test "unlock releases your own lock without --force" {
  agentws lock 1 "work" >/dev/null
  run agentws unlock 1
  [ "$status" -eq 0 ]
  [ ! -f "$(lock_path 1)" ]
}

@test "locking a slot you already hold is a no-op success" {
  agentws lock 1 "work" >/dev/null
  run agentws lock 1 "work again"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already hold"* ]]
}

@test "claim skips a slot held by a live lock and takes the next one" {
  mkproc 4242 777
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  # stdout only: under --json the narrative goes to stderr on purpose.
  local out
  out="$(agentws claim --json "some task" 2>/dev/null)"
  [ "$(printf '%s' "$out" | jq -r '.data.slot')" = "2" ]
  [ "$(printf '%s' "$out" | jq -r '.data.path')" = "$ROOT/2_proj" ]
}

@test "claim fails with ENOSLOT rather than stealing a live lock" {
  mkproc 4242 777
  local s
  for s in 1 2 3; do
    write_lock_default "$s" "owner_pid=4242" "owner_start=777"
  done
  run agentws claim "some task"
  [ "$status" -eq 5 ]
}
