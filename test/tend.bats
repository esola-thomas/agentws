#!/usr/bin/env bats

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-tend.XXXXXX")"
  ROOT="$SANDBOX/ws"
  LOCKS="$SANDBOX/locks"
  SRC="$ROOT/0_proj"
  REMOTE="$SANDBOX/remote.git"
  CONFIG="$SANDBOX/.agentws.yml"
  PROC="$SANDBOX/proc"
  mkdir -p "$ROOT" "$LOCKS" "$PROC"
  git init -q --bare "$REMOTE"
  git init -q "$SRC"
  git -C "$SRC" symbolic-ref HEAD refs/heads/main
  git -C "$SRC" config user.email t@example.invalid
  git -C "$SRC" config user.name tester
  printf 'old\n' > "$SRC/file"
  git -C "$SRC" add file
  git -C "$SRC" commit -q -m old
  git -C "$SRC" remote add origin "$REMOTE"
  git -C "$SRC" push -q -u origin main
  git -C "$SRC" checkout -q --detach
  {
    printf 'version: 1\nroot: %s\ntop: proj\nprovider: worktree\n' "$ROOT"
    printf 'default_branch: main\nslots: [0,1,2,3]\nreference_slot: 0\n'
    printf 'lock_dir: %s\n' "$LOCKS"
  } > "$CONFIG"
  export AGENTWS_CONFIG="$CONFIG" AGENTWS_PROC="$PROC"
  export AGENTWS_OWNER=tester AGENTWS_NO_AUTO_UPDATE=1
  unset AGENTWS_PID WSCTL_PID AGENTWS_TTL WSCTL_TTL
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"
  local s
  for s in 1 2 3; do agentws create "$s" >/dev/null 2>&1; done
  REAL_GIT="$(command -v git)"
  mkdir "$SANDBOX/bin"
  cat > "$SANDBOX/bin/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_TRACE_TEST"
if [[ "$*" == *" fetch "* ]] && [ "${BLOCK_FETCH:-0}" = 1 ]; then
  : > "$FETCH_ENTERED"
  while [ ! -f "$FETCH_RELEASE" ]; do sleep 0.05; done
fi
if [[ "$*" == *" checkout "* ]] && [ "${BLOCK_CHECKOUT:-0}" = 1 ]; then
  : > "$CHECKOUT_ENTERED"
  while [ ! -f "$CHECKOUT_RELEASE" ]; do sleep 0.05; done
fi
exec "$REAL_GIT" "$@"
SH
  chmod +x "$SANDBOX/bin/git"
  export REAL_GIT GIT_TRACE_TEST="$SANDBOX/git.trace"
  export PATH="$SANDBOX/bin:$PATH"
}

teardown() { teardown_sandbox; }

advance_remote() {
  git -C "$SRC" checkout -q main
  printf 'new\n' >> "$SRC/file"
  git -C "$SRC" commit -qam new
  git -C "$SRC" push -q
  git -C "$SRC" checkout -q --detach
}

last_json() { printf '%s' "${lines[${#lines[@]}-1]}"; }
action_for() { jq -r --arg s "$1" '.data.slots[] | select(.slot==$s) | .action'; }

@test "current farm fetches once with no other git writes or slot locks" {
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.fetch')" = ok ]
  [ "$(grep -c ' fetch ' "$GIT_TRACE_TEST")" -eq 1 ]
  ! grep -E ' checkout | reset | branch -d | write-tree' "$GIT_TRACE_TEST"
  [ "$(find "$LOCKS" -name '*.lock' | wc -l)" -eq 0 ]
  [ -f "$ROOT/.agentws/tend.json" ]
  [ -f "$ROOT/.agentws/tend.log" ]
  run agentws status
  [[ "$output" == *"tended "*"m ago"* ]]
}

@test "unchanged cached pass is fast and invalidates when local dirt appears" {
  agentws tend --json >/dev/null
  : > "$GIT_TRACE_TEST"
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.duration_ms')" -lt 1000 ]
  [ "$(grep -c ' fetch ' "$GIT_TRACE_TEST")" -eq 1 ]
  ! grep -E ' checkout | reset | branch -d ' "$GIT_TRACE_TEST"
  printf 'work\n' >> "$SRC/file"
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | action_for 0)" = skipped:dirty ]
}

@test "refresh advances only parked clean unlocked slots" {
  advance_remote
  write_lock_default 2
  printf 'dirty\n' >> "$ROOT/3_proj/file"
  local old
  old="$(git -C "$ROOT/2_proj" rev-parse HEAD)"
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | action_for 1)" = refreshed ]
  [ "$(last_json | action_for 2)" = skipped:locked ]
  [ "$(last_json | action_for 3)" = skipped:dirty ]
  [ "$(git -C "$ROOT/1_proj" rev-parse HEAD)" = "$(git -C "$SRC" rev-parse origin/main)" ]
  [ "$(git -C "$ROOT/2_proj" rev-parse HEAD)" = "$old" ]
  [ "$(git -C "$ROOT/3_proj" rev-parse HEAD)" = "$old" ]
}

@test "task branch and stale lock are preserved unless safe reaping is enabled" {
  git -C "$ROOT/1_proj" checkout -qb task/finished
  write_lock_default 1 epoch=1
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | action_for 1)" = skipped:task-branch ]
  [ -f "$(lock_path 1)" ]
  run agentws tend --reap --json
  [ "$status" -eq 0 ]
  [ "$(last_json | action_for 1)" = reaped ]
  [ ! -f "$(lock_path 1)" ]
  ! git -C "$ROOT/1_proj" symbolic-ref -q HEAD
}

@test "gone upstream never loses unmerged task commits" {
  git -C "$ROOT/1_proj" checkout -qb task/unmerged
  printf 'work\n' > "$ROOT/1_proj/work"
  git -C "$ROOT/1_proj" add work
  git -C "$ROOT/1_proj" -c user.name=tester -c user.email=t@example.invalid commit -qm work
  local head
  head="$(git -C "$ROOT/1_proj" rev-parse HEAD)"
  run agentws tend --reap --json
  [ "$status" -eq 0 ]
  [ "$(last_json | action_for 1)" = skipped:task-branch ]
  [ "$(git -C "$ROOT/1_proj" rev-parse HEAD)" = "$head" ]
}

@test "offline pass exits zero and reports dirty reference locally" {
  git -C "$SRC" remote set-url origin "$SANDBOX/no-remote"
  printf 'work\n' >> "$SRC/file"
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.fetch')" = offline ]
  [ "$(last_json | action_for 0)" = skipped:dirty ]
  [[ "$(last_json | jq -r '.data.problems[]')" == *"dirty reference"*file* ]]
}

@test "orphan is reported offline and preserved in failure JSON and status" {
  local admin
  admin="$(git -C "$ROOT/1_proj" rev-parse --absolute-git-dir)"
  mv "$admin" "$SANDBOX/admin-backup"
  git -C "$SRC" remote set-url origin "$SANDBOX/no-remote"
  run agentws tend --json
  [ "$status" -eq 8 ]
  [ "$(last_json | jq -r '.ok')" = false ]
  [ "$(last_json | action_for 1)" = broken:health ]
  [ "$(jq -r '.problem_count' "$ROOT/.agentws/tend.json")" -gt 0 ]
  [ -f "$ROOT/1_proj/file" ]
  run agentws status
  [[ "$output" == *"tend: "*"problems"* ]]
}

@test "check has no network, lock, state, log, or checkout writes" {
  advance_remote
  run agentws tend --check --json
  [ "$status" -eq 0 ]
  ! grep -E ' fetch | checkout | reset ' "$GIT_TRACE_TEST"
  [ ! -d "$ROOT/.agentws" ]
  [ "$(find "$LOCKS" -type f | wc -l)" -eq 0 ]
}

@test "unsupported lock format is reported and never taken over" {
  write_lock_default 1 format=999 epoch=1
  run agentws tend --json
  [ "$status" -eq 8 ]
  [ "$(last_json | action_for 1)" = broken:health ]
  grep -q format=999 "$(lock_path 1)"
}

@test "ignored files blocking checkout are preserved" {
  printf 'keep\n' > "$ROOT/1_proj/new-file"
  local exclude
  exclude="$(git -C "$SRC" rev-parse --absolute-git-dir)/info/exclude"
  printf 'new-file\n' >> "$exclude"
  git -C "$SRC" checkout -q main
  printf 'tracked\n' > "$SRC/new-file"
  git -C "$SRC" add -f new-file
  git -C "$SRC" commit -qm tracked
  git -C "$SRC" push -q
  git -C "$SRC" checkout -q --detach
  run agentws tend --json
  [ "$status" -eq 8 ]
  [ "$(cat "$ROOT/1_proj/new-file")" = keep ]
  [ "$(last_json | action_for 1)" = broken:refresh ]
}

@test "full clones fetch once per idle slot and preserve locked clones" {
  ROOT="$SANDBOX/clones"
  mkdir "$ROOT"
  local s
  for s in 1 2 3; do make_slot_repo "$s"; done
  sed -e 's/provider: worktree/provider: fullclone/' \
    -e "s|root: .*|root: $ROOT|" -e '/reference_slot:/d' \
    -e 's/slots: .*/slots: [1,2,3]/' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  for s in 1 2 3; do
    git -C "$ROOT/${s}_proj" remote add origin "$REMOTE"
  done
  write_lock_default 2
  : > "$GIT_TRACE_TEST"
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(grep -c ' fetch ' "$GIT_TRACE_TEST")" -eq 2 ]
  [ "$(last_json | action_for 2)" = skipped:locked ]
}

@test "overlapping pass exits successfully without doing work" {
  export BLOCK_FETCH=1 FETCH_ENTERED="$SANDBOX/entered" FETCH_RELEASE="$SANDBOX/release"
  agentws tend --json > "$SANDBOX/first" 2>&1 &
  local pid=$! i
  for i in $(seq 1 100); do [ ! -f "$FETCH_ENTERED" ] || break; sleep 0.05; done
  [ -f "$FETCH_ENTERED" ]
  run agentws tend --json
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.skipped')" = "overlapping pass" ]
  touch "$FETCH_RELEASE"
  wait "$pid"
  [ "$(grep -c ' fetch ' "$GIT_TRACE_TEST")" -eq 1 ]
}

@test "concurrent claim cannot return slot mid-refresh" {
  advance_remote
  git -C "$SRC" checkout -q --detach origin/main
  export BLOCK_CHECKOUT=1 CHECKOUT_ENTERED="$SANDBOX/entered" CHECKOUT_RELEASE="$SANDBOX/release"
  agentws tend --json > "$SANDBOX/pass" 2>&1 &
  local pid=$! i
  for i in $(seq 1 100); do [ ! -f "$CHECKOUT_ENTERED" ] || break; sleep 0.05; done
  [ -f "$CHECKOUT_ENTERED" ]
  [ "$(sed -n 's/^owner=//p' "$(lock_path 1)")" = agentws-tend ]
  run agentws claim racing --json
  [ "$status" -eq 0 ]
  [ "$(last_json | jq -r '.data.slot')" != 1 ]
  touch "$CHECKOUT_RELEASE"
  wait "$pid"
  [ ! -f "$(lock_path 1)" ]
}
