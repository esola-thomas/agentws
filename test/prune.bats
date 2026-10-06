#!/usr/bin/env bats

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-prune.XXXXXX")"
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

# stale is checked out nowhere; a is checked out in slot 2.
make_merged_branches() {
  git -C "$SRC" branch stale main
  git -C "$SRC" branch a main
  git -C "$ROOT/2_proj" switch -q a
}

@test "prune dry-run says would delete and removes nothing" {
  make_merged_branches
  run agentws prune --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would delete stale"* ]]
  [[ "$output" != *"    deleted "* ]]
  git -C "$SRC" show-ref --verify -q refs/heads/stale
}

@test "prune lists a candidate once per repo, not once per slot" {
  make_merged_branches
  run agentws prune --dry-run
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^    stale$')" -eq 1 ]
}

@test "prune never lists a branch checked out in another slot" {
  make_merged_branches
  run agentws prune --dry-run 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale"* ]]
  [ "$(printf '%s\n' "$output" | grep -c '^    a$')" -eq 0 ]
}

@test "prune --yes deletes only unprotected branches, honoring a foreign lock" {
  make_merged_branches
  write_lock_default 2
  run agentws prune --yes --json
  [ "$status" -eq 0 ]
  ! git -C "$SRC" show-ref --verify -q refs/heads/stale
  git -C "$SRC" show-ref --verify -q refs/heads/a
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.pruned[] | select(.deleted|length>0) | .deleted | join(",")')" = "stale" ]
}

@test "prune json dry-run reports would_delete, not deleted" {
  make_merged_branches
  run agentws prune --dry-run --json
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '[.data.pruned[].would_delete[]] | join(",")')" = "stale" ]
  [ "$(printf '%s' "$json" | jq -r '[.data.pruned[].deleted[]] | length')" -eq 0 ]
}
