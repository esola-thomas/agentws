#!/usr/bin/env bats
# Option parsing, claim --slot, lock --takeover, stale-lock reaping by tend and
# recycle, and the recycle and doctor messages that name their remedy.

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-friction.XXXXXX")"
  ROOT="$SANDBOX/ws"
  LOCKS="$SANDBOX/locks"
  SRC="$SANDBOX/source"
  REMOTE="$SANDBOX/remote.git"
  CONFIG="$SANDBOX/.agentws.yml"
  mkdir -p "$ROOT" "$LOCKS"

  git init -q --bare "$REMOTE"
  git clone -q "$REMOTE" "$SRC" 2>/dev/null
  git -C "$SRC" config user.email t@example.invalid
  git -C "$SRC" config user.name tester
  git -C "$SRC" switch -q -c main
  printf 'old\n' > "$SRC/file"
  git -C "$SRC" add file
  git -C "$SRC" commit -q -m old
  git -C "$SRC" push -q -u origin main
  git -C "$SRC" checkout -q --detach

  {
    printf 'version: 1\nroot: %s\ntop: proj\nprovider: worktree\n' "$ROOT"
    printf 'default_branch: main\nslots: [1,2,3,lab]\nexclude_from_claim: [lab]\n'
    printf 'slot_name_format: "{slot}_{top}"\nttl_hours: 12\nlock_dir: %s\n' "$LOCKS"
    printf 'provider_opts:\n  source_repo: %s\n' "$SRC"
  } > "$CONFIG"
  export AGENTWS_CONFIG="$CONFIG" AGENTWS_OWNER=tester AGENTWS_NO_AUTO_UPDATE=1
  export AGENTWS_PROC="$SANDBOX/proc"
  unset AGENTWS_PID WSCTL_PID AGENTWS_TTL WSCTL_TTL
  PROC="$AGENTWS_PROC"
  mkdir -p "$PROC"
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"
  local s
  for s in 1 2 3 lab; do agentws create "$s" >/dev/null 2>&1; done
}

teardown() { teardown_sandbox; }

commit_in() { # commit_in <dir> <file> <content>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.email=t@example.invalid -c user.name=tester commit -q -m "$2"
}

# A task branch pushed, squash-merged into main, and deleted upstream.
squash_merged() { # squash_merged <slot> <branch>
  local d="$ROOT/${1}_proj"
  git -C "$d" switch -q -c "$2"
  commit_in "$d" "$1.task" "$2"
  git -C "$d" push -q -u origin "$2" 2>/dev/null
  git -C "$SRC" checkout -q main
  git -C "$SRC" pull -q
  printf '%s\n' "$2" > "$SRC/$1.task"
  git -C "$SRC" add "$1.task"
  git -C "$SRC" commit -q -m "squash $2"
  git -C "$SRC" push -q
  git -C "$SRC" checkout -q --detach
  git -C "$REMOTE" branch -q -D "$2"
  git -C "$d" fetch -q --prune origin
}

dead_lock() { write_lock_default "$1" "owner_pid=4242" "owner_start=777"; }
last_json() { printf '%s' "${lines[${#lines[@]}-1]}"; }
action_for() { jq -r --arg s "$1" '.data.slots[] | select(.slot==$s) | .action'; }

# ------------------------------------------------------------ option parsing

@test "an unknown option is refused and never becomes a lock reason" {
  run agentws claim --sesion x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option '--sesion' for claim"* ]]
  [ -z "$(ls "$LOCKS")" ]

  run agentws --json lock 1 -x work
  [ "$status" -eq 2 ]
  printf '%s' "$output" | jq -e '.ok == false and .error.code == "EUSAGE"' >/dev/null
  [ ! -f "$(lock_path 1)" ]

  run agentws --slot 1 lock 1 work
  [ "$status" -eq 2 ]
  [[ "$output" == *"--slot applies only to claim"* ]]
  run agentws --takeover unlock 1
  [ "$status" -eq 2 ]
}

@test "--session is --owner, and -- lets a reason start with a dash" {
  run agentws --session claude:abc claim -- -5 hotfix
  [ "$status" -eq 0 ]
  local s
  s="$(grep -l '^owner=claude:abc$' "$LOCKS"/*.lock)"
  grep -q '^reason=-5 hotfix$' "$s"
}

@test "subcommand options still reach their commands" {
  run agentws tend --check --no-reap --json
  [ "$status" -eq 0 ]
  run agentws update --check --bogus
  [ "$status" -eq 2 ]
}

# ------------------------------------------------------------- claim --slot

@test "claim --slot takes that slot and returns the claim envelope" {
  run agentws claim --slot 2 --json fix parser
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.slot')" = 2 ]
  [ "$(last_json | jq -r '.data.path')" = "$ROOT/2_proj" ]
  grep -q '^reason=fix parser$' "$(lock_path 2)"
  [ ! -f "$(lock_path 1)" ]
  # Claiming a slot you already hold is not an error.
  run agentws claim --slot 2 again
  [ "$status" -eq 0 ]
}

@test "claim --slot honours claim's refusals and never substitutes a slot" {
  write_lock_default 1
  mkproc 4243 888
  write_lock_default 1 "owner_pid=4243" "owner_start=888"
  run agentws claim --slot 1 work
  [ "$status" -eq 4 ]
  [[ "$output" == *"held by other"* ]]

  git -C "$ROOT/2_proj" switch -q -c feat/x
  run agentws claim --slot 2 work
  [ "$status" -eq 5 ]
  [[ "$output" == *"not parked"* ]]

  run agentws claim --slot lab work
  [ "$status" -eq 5 ]
  [[ "$output" == *"excluded from claim"* ]]

  run agentws claim --slot 9 work
  [ "$status" -eq 6 ]

  [ ! -f "$(lock_path 2)" ] && [ ! -f "$(lock_path 3)" ] && [ ! -f "$(lock_path lab)" ]
}

# ------------------------------------------------------------ lock --takeover

@test "lock --takeover re-binds your own lock to a new pid and reason" {
  mkproc 5001 111
  AGENTWS_PID=5001 agentws lock 1 --task-id T-1 -- original task >/dev/null
  grep -q '^owner_pid=5001$' "$(lock_path 1)"

  mkproc 5002 222
  run env AGENTWS_PID=5002 "$AGENTWS_BIN" lock 1 work
  [[ "$output" == *"you already hold"* ]]
  grep -q '^owner_pid=5001$' "$(lock_path 1)"

  run env AGENTWS_PID=5002 "$AGENTWS_BIN" --takeover lock 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"re-bound"* ]]
  grep -q '^owner_pid=5002$' "$(lock_path 1)"
  grep -q '^owner_start=222$' "$(lock_path 1)"
  grep -q '^reason=original task$' "$(lock_path 1)"
  grep -q '^task_id=T-1$' "$(lock_path 1)"

  # After the session died, the same owner can still re-bind with a new reason.
  rmproc 5002
  mkproc 5003 333
  run env AGENTWS_PID=5003 "$AGENTWS_BIN" --takeover --json lock 1 task "(resumed)"
  [ "$status" -eq 0 ]
  grep -q '^owner_pid=5003$' "$(lock_path 1)"
  grep -q '^reason=task (resumed)$' "$(lock_path 1)"
}

@test "lock --takeover never takes another owner's live lock" {
  mkproc 4243 888
  write_lock_default 1 "owner_pid=4243" "owner_start=888"
  local before
  before="$(cat "$(lock_path 1)")"
  run agentws --takeover lock 1 mine
  [ "$status" -eq 1 ]
  [[ "$output" == *"only re-binds a lock whose owner is tester"* ]]
  [ "$(cat "$(lock_path 1)")" = "$before" ]
}

# --------------------------------------------------- stale locks: tend, recycle

@test "tend reaps a squash-merged slot whose lock is stale" {
  squash_merged 1 feat/sq
  dead_lock 1
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | action_for 1)" = reaped ]
  [[ "$(last_json | jq -r '.data.slots[] | select(.slot=="1") | .detail')" == *"stale lock of other released"* ]]
  [ ! -f "$(lock_path 1)" ]
  ! git -C "$ROOT/1_proj" symbolic-ref -q HEAD
  ! git -C "$ROOT/1_proj" show-ref --verify --quiet refs/heads/feat/sq
}

@test "tend keeps a stale lock untouched when anything could be lost" {
  # gone upstream, but the last commit never reached origin
  squash_merged 1 feat/more
  commit_in "$ROOT/1_proj" extra "unpushed"
  dead_lock 1
  # merged, but an untracked file in the tree
  squash_merged 2 feat/untracked
  printf 'scratch\n' > "$ROOT/2_proj/notes.txt"
  dead_lock 2
  # merged, but its lock is alive
  squash_merged 3 feat/live
  mkproc 4243 888
  write_lock_default 3 "owner_pid=4243" "owner_start=888"
  local l1 l2 l3
  l1="$(cat "$(lock_path 1)")"; l2="$(cat "$(lock_path 2)")"; l3="$(cat "$(lock_path 3)")"

  run agentws tend --json
  [ "$(last_json | action_for 1)" = skipped:task-branch ]
  [ "$(last_json | action_for 2)" = skipped:dirty ]
  [ "$(last_json | action_for 3)" = skipped:locked ]
  last_json | jq -e '.data.problems | any(test("1: stale lock left for manual review .*unpushed commits"))' >/dev/null
  [ "$(cat "$(lock_path 1)")" = "$l1" ]
  [ "$(cat "$(lock_path 2)")" = "$l2" ]
  [ "$(cat "$(lock_path 3)")" = "$l3" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = feat/more ]
  [ -f "$ROOT/2_proj/notes.txt" ]
}

@test "recycle takes over a stale lock only on a provably finished slot" {
  squash_merged 1 feat/done
  dead_lock 1
  run agentws recycle 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale lock from other (process_dead)"*"taking over"* ]]
  [ ! -f "$(lock_path 1)" ]

  squash_merged 2 feat/wip
  commit_in "$ROOT/2_proj" wip "unpushed"
  dead_lock 2
  local before
  before="$(cat "$(lock_path 2)")"
  run agentws recycle 2
  [ "$status" -eq 4 ]
  [[ "$output" == *"the lock is stale, but unpushed commits"* ]]
  [ "$(cat "$(lock_path 2)")" = "$before" ]
  [ "$(git -C "$ROOT/2_proj" branch --show-current)" = feat/wip ]

  squash_merged 3 feat/live
  mkproc 4243 888
  write_lock_default 3 "owner_pid=4243" "owner_start=888"
  run agentws recycle 3
  [ "$status" -eq 4 ]
  [ "$(git -C "$ROOT/3_proj" branch --show-current)" = feat/live ]
}

# ---------------------------------------------------------- remedy messages

@test "recycle names the other checkout that holds the branch" {
  agentws lock 1 work >/dev/null
  git -C "$ROOT/1_proj" switch -q -c feat/shared
  git -C "$ROOT/1_proj" checkout -q --detach
  git -C "$ROOT/2_proj" switch -q feat/shared
  git -C "$ROOT/1_proj" switch -q --ignore-other-worktrees feat/shared
  run agentws recycle 1
  [ "$status" -eq 8 ]
  [[ "$output" == *"feat/shared is still checked out in $ROOT/2_proj (slot 2)"* ]]
  [[ "$output" == *"switch --detach"*"agentws recycle 1"* ]]
  [ -f "$(lock_path 1)" ]
}

@test "doctor flags a worktree whose admin back-link is dead" {
  local admin
  admin="$(sed -n 's/^gitdir: //p' "$ROOT/1_proj/.git")"
  printf '%s\n' "$SANDBOX/moved/1_proj/.git" > "$admin/gitdir"
  run agentws doctor 1
  [ "$status" -eq 8 ]
  [[ "$output" == *"worktree-link"* ]]
  [[ "$output" == *"worktree repair $ROOT/1_proj"* ]]
  git -C "$SRC" worktree repair "$ROOT/1_proj"
  run agentws doctor 1
  [ "$status" -eq 0 ]
}

@test "full clones: tend puts back a stale lock it took for a skipped slot" {
  local clones="$SANDBOX/clones" s before
  mkdir "$clones"
  for s in 1 2; do git clone -q "$REMOTE" "$clones/${s}_proj"; done
  sed -e 's/provider: worktree/provider: fullclone/' -e "s|root: .*|root: $clones|" \
    -e 's/slots: .*/slots: [1,2]/' -e '/exclude_from_claim/d' \
    -e "s|source_repo: .*|source_repo: $REMOTE|" "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  ROOT="$clones"
  git -C "$clones/1_proj" switch -q -c feat/open
  commit_in "$clones/1_proj" open "never pushed"
  dead_lock 1
  before="$(cat "$(lock_path 1)")"
  run agentws tend --json
  [ "$(last_json | action_for 1)" = skipped:task-branch ]
  [ "$(cat "$(lock_path 1)")" = "$before" ]
}
