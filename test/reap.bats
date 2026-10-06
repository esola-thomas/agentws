#!/usr/bin/env bats

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-reap.XXXXXX")"
  ROOT="$SANDBOX/ws"
  LOCKS="$SANDBOX/locks"
  SRC="$SANDBOX/source"
  REMOTE="$SANDBOX/remote.git"
  CONFIG="$SANDBOX/.agentws.yml"
  mkdir -p "$ROOT" "$LOCKS"

  git init -q --bare "$REMOTE"
  git clone -q "$REMOTE" "$SRC"
  git -C "$SRC" config user.email t@example.invalid
  git -C "$SRC" config user.name tester
  git -C "$SRC" switch -q -c main
  printf 'old\n' > "$SRC/file"
  git -C "$SRC" add file
  git -C "$SRC" commit -q -m old
  git -C "$SRC" push -q -u origin main

  {
    printf 'version: 1\n'
    printf 'root: %s\n' "$ROOT"
    printf 'top: proj\n'
    printf 'provider: worktree\n'
    printf 'default_branch: main\n'
    printf 'slots: [1,2,3,4]\n'
    printf 'slot_name_format: "{slot}_{top}"\n'
    printf 'ttl_hours: 12\n'
    printf 'lock_dir: %s\n' "$LOCKS"
    printf 'provider_opts:\n'
    printf '  source_repo: %s\n' "$SRC"
  } > "$CONFIG"
  export AGENTWS_CONFIG="$CONFIG"
  export AGENTWS_CONFIG="$CONFIG"
  export AGENTWS_OWNER=tester
  export AGENTWS_PROC="$SANDBOX/proc"
  PROC="$AGENTWS_PROC"
  mkdir -p "$AGENTWS_PROC"
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"
  local s
  for s in 1 2 3 4; do agentws create "$s" >/dev/null 2>&1; done
}

teardown() { teardown_sandbox; }

parked() { # parked <slot-dir>: detached at origin/main
  ! git -C "$1" symbolic-ref -q HEAD >/dev/null &&
    [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse origin/main)" ]
}

# Leave a slot on a task branch whose work is merged into origin/main.
finish_merged() { # finish_merged <slot> <branch>
  local d="$ROOT/${1}_proj"
  git -C "$d" switch -q -c "$2"
  printf '%s\n' "$2" > "$d/$1.task"
  git -C "$d" add "$1.task"
  git -C "$d" -c user.email=t@example.invalid -c user.name=tester commit -q -m "$2"
  git -C "$SRC" merge -q --no-ff "$2" -m "merge $2"
  git -C "$SRC" push -q
  git -C "$d" fetch -q origin
}

stale_lock() { # stale_lock <slot>
  write_lock_default "$1" "owner_pid=4242" "owner_start=777"
}

@test "reap recycles a merged slot with a stale lock and nothing else" {
  finish_merged 1 feat/one
  stale_lock 1
  finish_merged 2 feat/two
  mkproc 4243 888
  write_lock_default 2 "owner_pid=4243" "owner_start=888"

  run agentws reap --json --yes
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slots | length')" -eq 1 ]
  [ "$(printf '%s' "$json" | jq -r '.data.slots[0].status')" = "recycled" ]
  [ "$(printf '%s' "$json" | jq -r '.data.slots[0].reason')" = "merged" ]
  parked "$ROOT/1_proj"
  [ ! -f "$(lock_path 1)" ]
  ! git -C "$ROOT/1_proj" show-ref --verify --quiet refs/heads/feat/one

  # The actively locked slot is untouched.
  [ -f "$(lock_path 2)" ]
  [ "$(git -C "$ROOT/2_proj" branch --show-current)" = "feat/two" ]
}

@test "reap takes a merged slot that has no lock, and a gone upstream with unmerged commits" {
  finish_merged 1 feat/one
  git -C "$ROOT/3_proj" switch -q -c feat/gone
  printf 'x\n' > "$ROOT/3_proj/gone.task"
  git -C "$ROOT/3_proj" add gone.task
  git -C "$ROOT/3_proj" -c user.email=t@example.invalid -c user.name=tester commit -q -m gone
  git -C "$ROOT/3_proj" push -q -u origin feat/gone
  git -C "$REMOTE" branch -q -D feat/gone

  run agentws reap --json --yes
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '[.data.slots[].status] | join(",")')" = "recycled,recycled" ]
  [ "$(printf '%s' "$json" | jq -r '.data.slots[1].reason')" = "gone" ]
  parked "$ROOT/1_proj"
  parked "$ROOT/3_proj"
}

@test "reap refuses a finished slot with real changes and lists it" {
  finish_merged 1 feat/one
  printf 'mine\n' >> "$ROOT/1_proj/file"

  run agentws reap --json --yes
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slots[0].status')" = "refused" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "feat/one" ]
  grep -q mine "$ROOT/1_proj/file"
}

@test "reap leaves a branch that is neither merged nor gone" {
  git -C "$ROOT/1_proj" switch -q -c feat/open
  printf 'wip\n' > "$ROOT/1_proj/wip"
  git -C "$ROOT/1_proj" add wip
  git -C "$ROOT/1_proj" -c user.email=t@example.invalid -c user.name=tester commit -q -m wip

  run agentws reap --json --yes
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots | length')" -eq 0 ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "feat/open" ]
}

@test "reap skips the reference and excluded slots" {
  printf 'reference_slot: "1"\nexclude_from_claim: [2]\n' >> "$CONFIG"
  finish_merged 1 feat/one
  finish_merged 2 feat/two

  run agentws reap --json --yes
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots | length')" -eq 0 ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "feat/one" ]
  [ "$(git -C "$ROOT/2_proj" branch --show-current)" = "feat/two" ]
}

@test "reap --dry-run changes nothing, and --json without --yes only reports" {
  finish_merged 1 feat/one
  stale_lock 1

  run agentws reap --json --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots[0].status')" = "would_recycle" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "feat/one" ]

  run agentws reap --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots[0].status')" = "skipped" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "feat/one" ]
  [ -f "$(lock_path 1)" ]
}

@test "reap asks before recycling and honors a no" {
  finish_merged 1 feat/one
  run bash -c "printf 'n\n' | '$AGENTWS_BIN' reap"
  [ "$status" -eq 0 ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "feat/one" ]
  run bash -c "printf 'y\n' | '$AGENTWS_BIN' reap"
  [ "$status" -eq 0 ]
  parked "$ROOT/1_proj"
}

@test "status notes a finished slot; claim and free say it can be reaped" {
  finish_merged 1 feat/one
  stale_lock 1
  local s
  for s in 2 3 4; do
    git -C "$ROOT/${s}_proj" switch -q -c "feat/busy$s"
    : > "$ROOT/${s}_proj/busy"
    git -C "$ROOT/${s}_proj" add busy
    git -C "$ROOT/${s}_proj" -c user.email=t@example.invalid -c user.name=tester commit -q -m busy
  done

  run agentws status
  printf '%s\n' "$output" | grep -q 'merged/gone: run agentws recycle 1'
  [ "$(printf '%s\n' "$output" | grep -c 'merged/gone')" -eq 1 ]

  run agentws claim work
  [ "$status" -eq 5 ]
  [[ "$output" == *"can be reaped"* ]]
  [[ "$output" == *"1_proj"* ]]

  run agentws free
  [[ "$output" == *"agentws reap"* ]]
}
