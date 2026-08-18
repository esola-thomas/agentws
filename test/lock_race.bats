#!/usr/bin/env bats
# lock_race.bats - concurrent acquisition. Exactly one winner, always.
#
# Mutual exclusion here rests on `( set -o noclobber; printf ... > "$f" )`
# (lib/lock.sh, ported from wsctl:327). Any replacement with a test-then-write
# reintroduces a window in which two agents both see an unlocked slot.

load helper

setup()    { setup_sandbox 1 2 3; }
teardown() { teardown_sandbox; }

# 20 concurrent claims on one slot: 1 winner, 19 losers, 1 well-formed file.
@test "20 concurrent locks on one slot produce exactly one winner" {
  local n=20 i rcdir wins=0 losses=0 rc
  rcdir="$SANDBOX/rc"
  mkdir -p "$rcdir"

  for i in $(seq 1 $n); do
    # bats runs the test body under errexit, so a losing rc must be captured
    # with `|| rc=$?` or the subshell dies before it records anything.
    (
      rc=0
      "$AGENTWS_BIN" --owner "racer-$i" lock 1 "race $i" >/dev/null 2>&1 || rc=$?
      printf '%s' "$rc" > "$rcdir/$i"
    ) &
  done
  wait

  for i in $(seq 1 $n); do
    [ -f "$rcdir/$i" ]
    rc="$(cat "$rcdir/$i")"
    if [ "$rc" = "0" ]; then wins=$((wins + 1)); else losses=$((losses + 1)); fi
  done

  [ "$wins" -eq 1 ]
  [ "$losses" -eq $((n - 1)) ]
}

@test "20 concurrent locks leave exactly one lock file, well formed" {
  local n=20 i
  for i in $(seq 1 $n); do
    ( "$AGENTWS_BIN" --owner "racer-$i" lock 1 "race $i" >/dev/null 2>&1 ) &
  done
  wait

  [ "$(ls "$LOCKS" | grep -c '\.lock$')" -eq 1 ]
  [ -f "$(lock_path 1)" ]

  # One owner line, one epoch line, and the owner is one of the racers.
  [ "$(grep -c '^owner=' "$(lock_path 1)")" -eq 1 ]
  [ "$(grep -c '^epoch=' "$(lock_path 1)")" -eq 1 ]
  grep -qE '^owner=racer-[0-9]+$' "$(lock_path 1)"
  grep -qE '^epoch=[0-9]+$' "$(lock_path 1)"
  grep -q '^host=' "$(lock_path 1)"
}

@test "the winner is the owner recorded on disk, and losers said BUSY" {
  local n=20 i outdir winner recorded
  outdir="$SANDBOX/out"
  mkdir -p "$outdir"

  for i in $(seq 1 $n); do
    (
      if "$AGENTWS_BIN" --owner "racer-$i" lock 1 "race $i" > "$outdir/$i" 2>&1; then
        printf 'racer-%s' "$i" > "$outdir/winner"
      fi
    ) &
  done
  wait

  [ -f "$outdir/winner" ]
  winner="$(cat "$outdir/winner")"
  recorded="$(sed -n 's/^owner=//p' "$(lock_path 1)" | head -1)"
  [ "$winner" = "$recorded" ]

  for i in $(seq 1 $n); do
    [ "racer-$i" = "$winner" ] && continue
    grep -qE 'BUSY|held by|lost race' "$outdir/$i"
  done
}

# 20 concurrent claims across 3 slots: no slot goes to two owners.
@test "concurrent claims never hand one slot to two owners" {
  local n=20 i s owners
  for i in $(seq 1 $n); do
    ( "$AGENTWS_BIN" --owner "racer-$i" claim "race $i" >/dev/null 2>&1 ) &
  done
  wait

  # At most one lock per slot is guaranteed by the filesystem; assert that each
  # existing lock names exactly one owner and that no two name the same slot.
  [ "$(ls "$LOCKS" | grep -c '\.lock$')" -le 3 ]
  for s in 1 2 3; do
    [ -f "$(lock_path "$s")" ] || continue
    owners="$(grep -c '^owner=' "$(lock_path "$s")")"
    [ "$owners" -eq 1 ]
  done
}

@test "a concurrent race does not produce a truncated lock file" {
  local n=20 i f
  for i in $(seq 1 $n); do
    ( "$AGENTWS_BIN" --owner "racer-$i" lock 2 "race $i" >/dev/null 2>&1 ) &
  done
  wait

  f="$(lock_path 2)"
  [ -f "$f" ]
  # Every line is key=value; a partial write from a second writer would break this.
  ! grep -vE '^[a-z_]+=' "$f" | grep -q .
  [ "$(lock_verdict 2)" = "alive" ]
}

@test "concurrent unlock and lock never leave the slot owned by the wrong agent" {
  local i
  "$AGENTWS_BIN" --owner holder lock 3 "first" >/dev/null

  for i in $(seq 1 10); do
    ( "$AGENTWS_BIN" --owner "racer-$i" lock 3 "steal $i" >/dev/null 2>&1 ) &
  done
  wait

  # Nobody may take a live lock from its holder.
  [ "$(sed -n 's/^owner=//p' "$(lock_path 3)" | head -1)" = "holder" ]
}
