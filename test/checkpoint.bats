#!/usr/bin/env bats
# checkpoint.bats - per-slot checkpoints: commands, lifecycle, and the proof
# that no claimability or staleness decision reads them.

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-cp.XXXXXX")"
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
    printf 'default_branch: main\nslots: [1,2,3]\nslot_name_format: "{slot}_{top}"\n'
    printf 'ttl_hours: 12\nlock_dir: %s\nprovider_opts:\n  source_repo: %s\n' "$LOCKS" "$SRC"
  } > "$CONFIG"
  export AGENTWS_CONFIG="$CONFIG" AGENTWS_PROC="$PROC"
  export AGENTWS_OWNER=tester AGENTWS_NO_AUTO_UPDATE=1
  export XDG_CONFIG_HOME="$SANDBOX/xdg-config" XDG_STATE_HOME="$SANDBOX/xdg-state"
  unset AGENTWS_PID WSCTL_PID WSCTL_OWNER AGENTWS_TTL WSCTL_TTL
  HOSTNAME_SHORT="$(hostname -s 2>/dev/null || echo host)"
  local s
  for s in 1 2 3; do agentws create "$s" >/dev/null 2>&1; done
}

teardown() { teardown_sandbox; }

cp_file() { printf '%s/%s.checkpoint%s' "$LOCKS" "$1" "${2-}"; }
last_json() { printf '%s' "${lines[${#lines[@]}-1]}"; }

# A lock held by "other" whose owner process is gone.
dead_lock() { write_lock_default "$1" "owner_pid=4242" "owner_start=777"; }

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

# The core predicates, read straight from the library.
probe() { # probe <slot> -> "claimable free stale reap"
  bash -c '
    set -u
    AGENTWS_LIB_DIR="$1/lib"; OWNER=tester; DRY=0; JSON=0; FORCE=0; IGNORE_PID=0
    for f in core config lock provider slots checkpoint envelope commands; do . "$AGENTWS_LIB_DIR/$f.sh"; done
    config_load; provider_load
    s="$2"
    printf "%s %s %s %s\n" \
      "$(slot_claimable "$s" && echo 1 || echo 0)" "$(slot_free "$s" && echo 1 || echo 0)" \
      "$(lock_is_stale "$s" && echo 1 || echo 0)" "$(slot_reap_state "$s")"
  ' probe "$AGENTWS_REPO_ROOT" "$1"
}

@test "set, show, and clear a checkpoint from inside the slot" {
  agentws lock 1 work >/dev/null
  cd "$ROOT/1_proj"
  run agentws checkpoint set --phase build --pr https://example.invalid/pr/1 --next "run tests"
  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1)")" = build ]
  [ "$(sed -n 's/^owner=//p' "$(cp_file 1)")" = tester ]
  sed -n 's/^updated=//p' "$(cp_file 1)" | grep -Eq '^[0-9]+$'

  run agentws checkpoint show
  [ "$status" -eq 0 ]
  [[ "$output" == *"phase: build"* ]]
  [[ "$output" == *"next:  run tests"* ]]

  run agentws checkpoint show --json
  [ "$(last_json | jq -r '.data.checkpoint.pr')" = https://example.invalid/pr/1 ]
  [ "$(last_json | jq -r '.data.previous')" = null ]

  run agentws checkpoint clear
  [ "$status" -eq 0 ]
  [ ! -e "$(cp_file 1)" ]
  run agentws checkpoint show --json
  [ "$(last_json | jq -r '.data.checkpoint')" = null ]
}

@test "set merges the given fields and keeps the rest" {
  agentws lock 1 work >/dev/null
  cd "$ROOT/1_proj"
  agentws checkpoint set --phase build --next "run tests" >/dev/null
  agentws checkpoint set --pr https://example.invalid/pr/2 >/dev/null
  agentws checkpoint set --next "" >/dev/null
  run agentws checkpoint show --json
  [ "$(last_json | jq -r '.data.checkpoint.phase')" = build ]
  [ "$(last_json | jq -r '.data.checkpoint.pr')" = https://example.invalid/pr/2 ]
  [ "$(last_json | jq -r '.data.checkpoint.next')" = "" ]
}

@test "set with no field is a usage error and writes nothing" {
  agentws lock 1 work >/dev/null
  cd "$ROOT/1_proj"
  run agentws checkpoint set
  [ "$status" -eq 2 ]
  [ ! -e "$(cp_file 1)" ]
  run agentws checkpoint show --phase x
  [ "$status" -eq 2 ]
  run agentws status --phase x
  [ "$status" -eq 2 ]
}

@test "a body file is stored beside the checkpoint and shown" {
  agentws lock 1 work >/dev/null
  printf 'line one\nline two\n' > "$SANDBOX/body with space.md"
  cd "$ROOT/1_proj"
  run agentws checkpoint set --phase review --body-file "$SANDBOX/body with space.md"
  [ "$status" -eq 0 ]
  [ "$(cat "$(cp_file 1 .md)")" = "$(printf 'line one\nline two')" ]
  run agentws checkpoint show
  [[ "$output" == *"| line two"* ]]
  run agentws checkpoint show --json
  [ "$(last_json | jq -r '.data.checkpoint.body')" = "$(printf 'line one\nline two')" ]
  run agentws status --json
  [ "$(last_json | jq -r '.data.slots[0].checkpoint.has_body')" = true ]
  run agentws checkpoint set --body-file "$SANDBOX/missing"
  [ "$status" -eq 2 ]
}

@test "newlines in a field cannot forge another key" {
  agentws lock 1 work >/dev/null
  cd "$ROOT/1_proj"
  run agentws checkpoint set --note "$(printf 'x\nowner=evil\nphase=forged')" --next "a=b=c"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^owner=' "$(cp_file 1)")" -eq 1 ]
  [ "$(sed -n 's/^owner=//p' "$(cp_file 1)")" = tester ]
  [ "$(grep -c '^phase=' "$(cp_file 1)")" -eq 1 ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1)")" = "" ]
  [ "$(sed -n 's/^next=//p' "$(cp_file 1)")" = "a=b=c" ]
  [ "$(wc -l < "$(cp_file 1 .log)" | tr -d ' ')" -eq 1 ]
}

@test "the history log keeps the last 50 calls" {
  agentws lock 1 work >/dev/null
  cd "$ROOT/1_proj"
  local i
  for i in $(seq 1 55); do agentws checkpoint set --phase "p$i" >/dev/null; done
  [ "$(wc -l < "$(cp_file 1 .log)" | tr -d ' ')" -eq 50 ]
  head -1 "$(cp_file 1 .log)" | grep -q 'phase=p6 '
  tail -1 "$(cp_file 1 .log)" | grep -q 'phase=p55 '
}

@test "the slot is resolved from a nested directory and through a symlink" {
  agentws lock 2 work >/dev/null
  mkdir -p "$ROOT/2_proj/deep/er"
  ln -s "$ROOT/2_proj/deep" "$SANDBOX/link to slot"
  cd "$ROOT/2_proj/deep/er"
  run agentws checkpoint set --phase nested
  [ "$status" -eq 0 ]
  [ -f "$(cp_file 2)" ]
  cd "$SANDBOX/link to slot"
  run agentws checkpoint set --phase linked
  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 2)")" = linked ]
}

@test "set refuses an unlocked slot, a non-holder outside it, and a cwd in no slot" {
  cd "$ROOT/1_proj"
  run agentws checkpoint set --phase x
  [ "$status" -eq 4 ]
  [[ "$output" == *"not locked"* ]]
  [ ! -e "$(cp_file 1)" ]

  write_lock_default 1
  cd "$ROOT/2_proj"
  run agentws checkpoint set 1 --phase x
  [ "$status" -eq 4 ]
  [ ! -e "$(cp_file 1)" ]
  run agentws checkpoint clear 1
  [ "$status" -eq 4 ]

  cd "$SANDBOX"
  run agentws checkpoint set --phase x
  [ "$status" -eq 6 ]
  run agentws checkpoint set 1 --phase x --json
  [ "$status" -eq 4 ]
  [ "$(last_json | jq -r '.error.code')" = ELOCKED ]
}

@test "the lock holder may checkpoint from outside the slot; anyone may read" {
  agentws lock 1 work >/dev/null
  cd "$SANDBOX"
  run agentws checkpoint set 1 --phase remote
  [ "$status" -eq 0 ]
  run env AGENTWS_OWNER=someone-else "$AGENTWS_BIN" checkpoint show 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"phase: remote"* ]]
}

@test "writes are atomic renames: no temp files, symlinks replaced and never followed" {
  agentws lock 1 work >/dev/null
  printf 'victim\n' > "$SANDBOX/victim"
  ln -s "$SANDBOX/victim" "$(cp_file 1)"
  ln -s "$SANDBOX/victim" "$(cp_file 1 .log)"
  ln -s "$SANDBOX/victim" "$(cp_file 1 .md)"
  run agentws checkpoint show 1 --json
  [ "$(last_json | jq -r '.data.checkpoint')" = null ]
  cd "$ROOT/1_proj"
  printf 'body\n' > "$SANDBOX/body"
  run agentws checkpoint set --phase safe --body-file "$SANDBOX/body"
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/victim")" = victim ]
  [ ! -L "$(cp_file 1)" ]
  [ ! -L "$(cp_file 1 .log)" ]
  [ ! -L "$(cp_file 1 .md)" ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1)")" = safe ]
  [ -z "$(find "$LOCKS" -name '.cp.*')" ]
}

@test "a symlink to a directory at a checkpoint path is replaced, never written into" {
  agentws lock 1 work >/dev/null
  mkdir -p "$SANDBOX/victimdir"
  ln -s "$SANDBOX/victimdir" "$(cp_file 1)"
  ln -s "$SANDBOX/victimdir" "$(cp_file 1 .log)"
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase safe >/dev/null)
  [ -z "$(ls -A "$SANDBOX/victimdir")" ]
  [ -f "$(cp_file 1)" ]
  [ ! -L "$(cp_file 1)" ]

  # The same for the previous generation on a takeover.
  agentws unlock 1 >/dev/null
  write_lock_default 1 "owner_pid=4242" "owner_start=777"
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase old >/dev/null)
  ln -s "$SANDBOX/victimdir" "$(cp_file 1 .prev)"
  agentws lock 1 newtask >/dev/null
  [ -z "$(ls -A "$SANDBOX/victimdir")" ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1 .prev)")" = old ]
}

@test "unlock, recycle, and reap delete the checkpoint" {
  agentws lock 1 work >/dev/null
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase a >/dev/null)
  [ -f "$(cp_file 1)" ]
  agentws unlock 1 >/dev/null
  [ ! -e "$(cp_file 1)" ]

  agentws lock 2 work >/dev/null
  (cd "$ROOT/2_proj" && git switch -q -c feat/two && agentws checkpoint set --phase b >/dev/null)
  agentws recycle 2 >/dev/null 2>&1
  [ ! -e "$(cp_file 2)" ]

  finish_merged 3 feat/three
  dead_lock 3
  (cd "$ROOT/3_proj" && agentws checkpoint set --phase c >/dev/null)
  [ -f "$(cp_file 3)" ]
  run agentws reap --yes
  [ "$status" -eq 0 ]
  [ ! -e "$(lock_path 3)" ]
  [ ! -e "$(cp_file 3)" ]
}

@test "unlock drops the advisory files before the lock, so the next holder's survive" {
  agentws lock 1 work >/dev/null
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase mine >/dev/null)
  # rm shim: right after the lock file goes, a second holder writes its notice
  # and checkpoint, as a claim racing in at that moment would.
  local real_rm; real_rm="$(command -v rm)"
  mkdir -p "$SANDBOX/shim"
  cat > "$SANDBOX/shim/rm" <<SH
#!/usr/bin/env bash
"$real_rm" "\$@"; rc=\$?
case " \$* " in *" $LOCKS/1.lock "*)
  printf 'next holder\n' > "$LOCKS/1.notice"
  printf 'phase=theirs\nowner=next\n' > "$LOCKS/1.checkpoint" ;;
esac
exit \$rc
SH
  chmod +x "$SANDBOX/shim/rm"
  PATH="$SANDBOX/shim:$PATH" agentws unlock 1 >/dev/null
  [ ! -e "$(lock_path 1)" ]
  [ "$(cat "$LOCKS/1.notice")" = "next holder" ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1)")" = theirs ]
}

@test "tend reap, doctor auto-release, and destroy delete the checkpoint and notice" {
  finish_merged 1 feat/one
  dead_lock 1
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase done >/dev/null)
  printf 'old notice\n' > "$LOCKS/1.notice"
  run agentws tend --json
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots[] | select(.slot=="1") | .action')" = reaped ]
  [ ! -e "$(lock_path 1)" ]
  [ ! -e "$(cp_file 1)" ]
  [ ! -e "$LOCKS/1.notice" ]

  printf 'auto_release: true\nauto_release_minutes: 0\n' >> "$CONFIG"
  agentws claim --slot 2 work >/dev/null 2>&1
  (cd "$ROOT/2_proj" && agentws checkpoint set --phase idle >/dev/null)
  [ -f "$LOCKS/2.notice" ]
  agentws doctor 2 >/dev/null 2>&1 || true
  [ ! -e "$(lock_path 2)" ]
  [ ! -e "$(cp_file 2)" ]
  [ ! -e "$LOCKS/2.notice" ]

  agentws lock 3 work >/dev/null
  (cd "$ROOT/3_proj" && agentws checkpoint set --phase gone >/dev/null)
  run agentws destroy 3 --yes
  [ "$status" -eq 0 ]
  [ ! -e "$(lock_path 3)" ]
  [ ! -e "$(cp_file 3)" ]
}

@test "a takeover by a different owner moves the checkpoint to .prev" {
  dead_lock 1
  printf 'notes\n' > "$SANDBOX/body"
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase half --next "finish it" --body-file "$SANDBOX/body" >/dev/null)
  run agentws lock 1 newtask
  [ "$status" -eq 0 ]
  [ ! -e "$(cp_file 1)" ]
  [ "$(sed -n 's/^next=//p' "$(cp_file 1 .prev)")" = "finish it" ]
  [ -f "$(cp_file 1 .prev.md)" ]
  run agentws checkpoint show 1 --json
  [ "$(last_json | jq -r '.data.checkpoint')" = null ]
  [ "$(last_json | jq -r '.data.previous.owner')" = other ]
  [ "$(last_json | jq -r '.data.previous.body')" = notes ]
}

@test "the same owner re-locking its own stale lock keeps the checkpoint and notice" {
  write_lock_default 1 "owner=tester" "owner_pid=4242" "owner_start=777"
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase mine >/dev/null)
  printf 'my notice\n' > "$LOCKS/1.notice"
  run agentws lock 1 again
  [ "$status" -eq 0 ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1)")" = mine ]
  [ "$(cat "$LOCKS/1.notice")" = "my notice" ]
  [ ! -e "$(cp_file 1 .prev)" ]
}

@test "tend's maintenance lock keeps the checkpoint of a stale lock it puts back" {
  # fullclone: tend takes its maintenance lock before it decides to skip.
  ROOT="$SANDBOX/fc"; mkdir -p "$ROOT"
  sed -e "s|^root: .*|root: $ROOT|" -e 's|^provider: .*|provider: fullclone|' \
      -e "s|source_repo: .*|source_repo: $REMOTE|" "$CONFIG" > "$SANDBOX/fc.yml"
  export AGENTWS_CONFIG="$SANDBOX/fc.yml"
  agentws create 1 >/dev/null 2>&1
  git -C "$ROOT/1_proj" switch -q -c feat/open
  printf 'wip\n' > "$ROOT/1_proj/wip"
  git -C "$ROOT/1_proj" add wip
  git -C "$ROOT/1_proj" -c user.email=t@example.invalid -c user.name=tester commit -q -m wip
  dead_lock 1
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase orphaned-work >/dev/null)
  run agentws tend --json --reap
  [ -f "$(lock_path 1)" ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1)")" = orphaned-work ]
  [ ! -e "$(cp_file 1 .prev)" ]
}

@test "a checkpoint never changes claimable, free, stale, or reap state" {
  # 1: stale lock on a merged branch (reapable)
  finish_merged 1 feat/one
  dead_lock 1
  # 2: active lock
  mkproc 4243 888
  write_lock_default 2 "owner_pid=4243" "owner_start=888"
  # 3: stale lock on a parked clean slot (claimable)
  dead_lock 3
  local s before after
  for s in 1 2 3; do
    before="$(probe "$s")"
    (cd "$ROOT/${s}_proj" && agentws checkpoint set --phase p --next n >/dev/null)
    [ -f "$(cp_file "$s")" ]
    after="$(probe "$s")"
    echo "$s: $before -> $after"
    [ "$before" = "$after" ]
  done
  [ "$(probe 1)" = "0 0 1 reap" ]
  [ "$(probe 2)" = "0 0 0 none" ]
  [ "$(probe 3)" = "1 1 1 none" ]
}

@test "status shows phase and PR; status --json carries the checkpoint object" {
  agentws lock 1 work >/dev/null
  (cd "$ROOT/1_proj" && agentws checkpoint set --phase review --pr https://example.invalid/pr/9 >/dev/null)
  run agentws status
  [[ "$output" == *"review · https://example.invalid/pr/9"* ]]
  run agentws status --json
  [ "$(last_json | jq -r '.data.slots[0].checkpoint.phase')" = review ]
  [ "$(last_json | jq -r '.data.slots[1].checkpoint')" = null ]
}

@test "MCP workspace_checkpoint sets, shows, and clears through the CLI" {
  local mcp="$AGENTWS_REPO_ROOT/mcp/agentws-mcp" out
  agentws --owner mcp:s1 lock 1 work >/dev/null
  mcp_call() { printf '%s\n' "$1" | (cd "$ROOT/1_proj" && "$mcp" 2>/dev/null) | sed -e 's/^Content-Length:[^{]*//' | jq -r '.result.content[0].text'; }
  out="$(mcp_call '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"workspace_checkpoint","arguments":{"session":"s1","action":"set","phase":"-x build","next":"ship","body":"long\nnotes"}}}')"
  [ "$(printf '%s' "$out" | jq -r '.ok')" = true ]
  [ "$(sed -n 's/^phase=//p' "$(cp_file 1)")" = "-x build" ]
  [ "$(cat "$(cp_file 1 .md)")" = "$(printf 'long\nnotes')" ]
  out="$(mcp_call '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"workspace_checkpoint","arguments":{"session":"s2","action":"show","slot":"1"}}}')"
  [ "$(printf '%s' "$out" | jq -r '.data.checkpoint.next')" = ship ]
  out="$(mcp_call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"workspace_checkpoint","arguments":{"session":"s1","action":"clear","slot":"1"}}}')"
  [ "$(printf '%s' "$out" | jq -r '.ok')" = true ]
  [ ! -e "$(cp_file 1)" ]
  [ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'agentws-mcp-body.*' -newer "$CONFIG" 2>/dev/null)" ]
}
