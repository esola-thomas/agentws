#!/usr/bin/env bats
# orphan.bats - a stale lock on a slot whose task is unfinished is surfaced as
# orphaned; nothing about it is released, taken over, or resumed.

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-orphan.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  ROOT="$SANDBOX/ws"
  LOCKS="$SANDBOX/locks"
  SRC="$SANDBOX/source"
  REMOTE="$SANDBOX/remote.git"
  CONFIG="$SANDBOX/.agentws.yml"
  PROC="$SANDBOX/proc"
  mkdir -p "$ROOT" "$LOCKS" "$PROC"
  git init -q --bare "$REMOTE"
  git clone -q "$REMOTE" "$SRC" 2>/dev/null
  git -C "$SRC" config user.email t@example.invalid
  git -C "$SRC" config user.name tester
  git -C "$SRC" switch -q -c main
  printf 'old\n' > "$SRC/file"
  git -C "$SRC" add file
  git -C "$SRC" commit -q -m old
  git -C "$SRC" push -q -u origin main
  {
    printf 'version: 1\nroot: %s\ntop: proj\nprovider: worktree\n' "$ROOT"
    printf 'default_branch: main\nslots: [1,2,3,4,5]\nslot_name_format: "{slot}_{top}"\n'
    printf 'ttl_hours: 12\nlock_dir: %s\nprovider_opts:\n  source_repo: %s\n' "$LOCKS" "$SRC"
  } > "$CONFIG"
  export AGENTWS_CONFIG="$CONFIG" AGENTWS_PROC="$PROC"
  export AGENTWS_OWNER=tester AGENTWS_NO_AUTO_UPDATE=1
  export XDG_CONFIG_HOME="$SANDBOX/xdg-config" XDG_STATE_HOME="$SANDBOX/xdg-state"
  unset AGENTWS_PID WSCTL_PID WSCTL_OWNER AGENTWS_TTL WSCTL_TTL
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"
  local s
  for s in 1 2 3 4 5; do agentws create "$s" >/dev/null 2>&1; done
}
teardown() { teardown_sandbox; }

last_json() { printf '%s' "${lines[${#lines[@]}-1]}"; }
dead_lock() { write_lock_default "$1" "owner_pid=4242" "owner_start=777"; }

task_branch() { # task_branch <slot> <branch>: one unmerged commit
  local d="$ROOT/${1}_proj"
  git -C "$d" switch -q -c "$2"
  printf '%s\n' "$2" > "$d/$1.task"
  git -C "$d" add "$1.task"
  git -C "$d" -c user.email=t@example.invalid -c user.name=tester commit -q -m "$2"
}

slot_json() { # slot_json <slot> <jq-filter>
  agentws status --json 2>/dev/null | jq -r --arg s "$1" ".data.slots[] | select(.slot==\$s) | $2"
}

# Five slots, five shapes:
#   1 stale (process_dead) + unmerged branch     -> orphaned
#   2 stale (process_dead) + merged, but dirty    -> orphaned
#   3 stale (process_dead) + merged, clean        -> reapable, not orphaned
#   4 active lock + unmerged branch               -> not orphaned
#   5 no owner_pid, below TTL, unmerged branch    -> not orphaned
build_farm() {
  task_branch 1 feat/one
  dead_lock 1
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase implement --next "finish the parser" >/dev/null)

  task_branch 2 feat/two
  git -C "$SRC" merge -q --no-ff feat/two -m "merge two"
  git -C "$SRC" push -q
  git -C "$ROOT/2_proj" fetch -q origin
  printf 'local edit\n' >> "$ROOT/2_proj/file"
  dead_lock 2

  task_branch 3 feat/three
  git -C "$SRC" merge -q --no-ff feat/three -m "merge three"
  git -C "$SRC" push -q
  git -C "$ROOT/3_proj" fetch -q origin
  dead_lock 3

  task_branch 4 feat/four
  mkproc 4243 888
  write_lock_default 4 "owner_pid=4243" "owner_start=888"

  task_branch 5 feat/five
  write_lock_default 5
  set_lock_age_hours 5 6
  (cd "$ROOT/5_proj" && agentws checkpoint set --phase waiting >/dev/null)
}

@test "status --json marks exactly the stale, unfinished slots as orphaned" {
  build_farm
  [ "$(slot_json 1 .orphaned)" = true ]
  [ "$(slot_json 1 .orphan_reason)" = process_dead ]
  [ "$(slot_json 2 .orphaned)" = true ]
  [ "$(slot_json 3 .orphaned)" = false ]
  [ "$(slot_json 3 .orphan_reason)" = null ]
  [ "$(slot_json 4 .orphaned)" = false ]
  [ "$(slot_json 5 .orphaned)" = false ]
}

@test "a ttl-expired lock on an unfinished slot is orphaned by ttl" {
  task_branch 1 feat/one
  write_lock_default 1
  set_lock_age_hours 1 13
  [ "$(slot_json 1 .orphan_reason)" = ttl ]
}

@test "a stale lock on a parked clean slot is not orphaned" {
  dead_lock 1
  [ "$(slot_json 1 .orphaned)" = false ]
  [ "$(slot_json 1 .claimable)" = true ]
}

@test "a stale lock on a clean slot still on the default branch is not orphaned" {
  git -C "$SRC" checkout -q --detach
  git -C "$ROOT/1_proj" switch -q main
  write_lock_default 1
  set_lock_age_hours 1 13
  [ "$(slot_json 1 .orphaned)" = false ]
  printf 'edit\n' >> "$ROOT/1_proj/file"
  [ "$(slot_json 1 .orphaned)" = true ]
}

@test "status names the orphan and its resume point" {
  build_farm
  run agentws status
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep '^1_proj' | grep -q 'ORPHANED (process_dead).*: implement · finish the parser'
  printf '%s\n' "$output" | grep '^2_proj' | grep -q 'ORPHANED (process_dead).*: no checkpoint; lock by other'
  printf '%s\n' "$output" | grep '^3_proj' | grep -q 'stale lock (other)'
  [ -z "$(printf '%s\n' "$output" | grep '^3_proj' | grep ORPHANED)" ]
  printf '%s\n' "$output" | grep '^5_proj' | grep -q 'last checkpoint 0m ago'
  [ -z "$(printf '%s\n' "$output" | grep '^4_proj' | grep 'last checkpoint')" ]
}

@test "orphan state changes nothing: locks, branches, claimability stay as they were" {
  build_farm
  local s before
  before="$(for s in 1 2 3 4 5; do cat "$(lock_path "$s")"; done | cksum)"
  agentws status >/dev/null
  agentws status --json >/dev/null
  [ "$before" = "$(for s in 1 2 3 4 5; do cat "$(lock_path "$s")"; done | cksum)" ]
  [ "$(slot_json 1 .claimable)" = false ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = feat/one ]
}

@test "tend reports each orphan as a problem with its resume point" {
  build_farm
  run agentws tend --json --no-reap
  last_json | jq -e '.data.problems | any(test("^1: orphaned \\(process_dead\\): implement · finish the parser"))' >/dev/null
  last_json | jq -e '.data.problems | any(test("^2: orphaned \\(process_dead\\)"))' >/dev/null
  [ "$(last_json | jq '[.data.problems[] | select(test("^[345]: orphaned"))] | length')" -eq 0 ]
  [ -f "$(lock_path 1)" ]
  [ -f "$(lock_path 2)" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = feat/one ]
}
