#!/usr/bin/env bats

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-lifecycle.XXXXXX")"
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
  git -C "$SRC" worktree add -q --force "$ROOT/1_proj" main
  git -C "$SRC" worktree add -q --force "$ROOT/2_proj" main

  {
    printf 'version: 1\n'
    printf 'root: %s\n' "$ROOT"
    printf 'top: proj\n'
    printf 'provider: worktree\n'
    printf 'default_branch: main\n'
    printf 'slots: [1,2]\n'
    printf 'slot_name_format: "{slot}_{top}"\n'
    printf 'ttl_hours: 12\n'
    printf 'lock_dir: %s\n' "$LOCKS"
    printf 'provider_opts:\n'
    printf '  source_repo: %s\n' "$SRC"
  } > "$CONFIG"
  export AGENTWS_CONFIG="$CONFIG"
  export AGENTWS_OWNER=tester
  export AGENTWS_PROC="$SANDBOX/proc"
  mkdir -p "$AGENTWS_PROC"
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"
}

teardown() { teardown_sandbox; }

advance_main() {
  printf 'new\n' > "$SRC/file"
  git -C "$SRC" add file
  git -C "$SRC" commit -q -m new
  git -C "$SRC" push -q
}

@test "status distinguishes phantom dirt and refresh heals only verified dirt" {
  advance_main
  run agentws status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.data.slots[].dirty_state] | unique | join(",")')" = "phantom-dirty" ]

  run agentws refresh --json 1
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slots[0].status')" = "refreshed" ]
  [ -z "$(git -C "$ROOT/1_proj" status --porcelain)" ]

  printf 'personal\n' >> "$ROOT/2_proj/file"
  run agentws refresh --json 2
  [ "$status" -eq 8 ]
  json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.error.code')" = "EGIT" ]
  grep -q personal "$ROOT/2_proj/file"
}

@test "auto_refresh lets claim safely recover a phantom-dirty slot" {
  printf 'auto_refresh: true\n' >> "$CONFIG"
  advance_main
  run agentws claim --json work
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slot')" = "1" ]
  [ "$(printf '%s' "$json" | jq -r '.data.dirty_state')" = "clean" ]
}

@test "recycle reports untracked files then cleans, resets, deletes, and releases" {
  git -C "$ROOT/1_proj" switch -q -c feat/recycle
  printf 'task\n' > "$ROOT/1_proj/task"
  git -C "$ROOT/1_proj" add task
  git -C "$ROOT/1_proj" -c user.email=t@example.invalid -c user.name=tester commit -q -m task
  git -C "$SRC" merge -q --no-ff feat/recycle -m merge
  git -C "$SRC" push -q
  agentws lock 1 work >/dev/null
  printf 'scratch\n' > "$ROOT/1_proj/SCRATCH"

  run agentws recycle --json 1
  [ "$status" -eq 8 ]
  [ -f "$(lock_path 1)" ]
  git -C "$ROOT/1_proj" show-ref --verify --quiet refs/heads/feat/recycle

  run agentws recycle --json --clean-untracked 1
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.deleted_branch')" = "feat/recycle" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "main" ]
  [ ! -f "$(lock_path 1)" ]
  [ ! -e "$ROOT/1_proj/SCRATCH" ]
  ! git -C "$ROOT/1_proj" show-ref --verify --quiet refs/heads/feat/recycle
}

@test "recycle refuses another owner's lock" {
  write_lock_default 1
  run agentws recycle --json 1
  [ "$status" -eq 4 ]
  [ -f "$(lock_path 1)" ]
}

@test "done is an idempotent recycle alias for a clean unlocked slot" {
  run agentws done --json 1
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.command')" = "done" ]
  [ "$(printf '%s' "$json" | jq -r '.data.released')" = "false" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "main" ]
}
