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
  agentws create 1 >/dev/null 2>&1
  agentws create 2 >/dev/null 2>&1
}

teardown() { teardown_sandbox; }

replace_source() {
  mv "$SRC" "$SANDBOX/old-source"
  git clone -q -b main "$REMOTE" "$SRC"
}

@test "orphaned slots are broken in status and free, never clean or claimable" {
  printf 'personal\n' >> "$ROOT/1_proj/file"
  printf 'untracked\n' > "$ROOT/1_proj/wip"
  replace_source

  run agentws status --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.data.slots | all(.exists and .dirty == -1 and .dirty_state == "broken" and (.claimable | not) and (.free | not) and (.warnings | index("git_state_unreadable")))' >/dev/null
  run agentws status
  [[ "$output" == *broken* ]]
  run agentws free
  [[ "$output" == *BROKEN* ]]
  run agentws free --json
  printf '%s' "$output" | jq -e '.data.free == [] and .data.claimable == [] and (.data.slots | all(.dirty_state == "broken"))' >/dev/null
  run agentws claim work
  [ "$status" -eq 5 ]
}

@test "doctor fails on orphaned slots and prints the final provider check" {
  replace_source
  run agentws doctor 2
  [ "$status" -eq 8 ]
  [[ "$output" == *FAIL*common-dir* ]]
  [[ "$output" == *"worktree admin dir"* ]]
  [[ "$output" == *"is missing"* ]]
  [[ "$output" != *"PASS worktree"* ]]
  run agentws doctor 2 --json
  [ "$status" -eq 8 ]
  local json="${lines[${#lines[@]}-1]}"
  printf '%s' "$json" | jq -e '(.ok | not) and (.data.ok | not) and .error.code == "EGIT" and (.data.slots[0].checks | any(.id == "common-dir" and .status == "fail"))' >/dev/null
}

@test "orphaned slots cannot be destroyed or recycled without explicit recovery" {
  printf 'personal\n' >> "$ROOT/1_proj/file"
  printf 'untracked\n' > "$ROOT/1_proj/wip"
  replace_source
  write_lock_default 1 owner=tester

  run agentws free
  [[ "$output" == *BROKEN*"locked by tester"* ]]
  run agentws destroy 1 --yes
  [ "$status" -eq 2 ]
  [[ "$output" == *"unreadable git state"* ]]
  run agentws recycle 1 --force --clean-untracked
  [ "$status" -eq 8 ]
  [[ "$output" == *"unreadable git state"* ]]
  run agentws refresh 2
  [ "$status" -eq 8 ]
  [[ "$output" == *"unreadable git state"* ]]
  run agentws reap --yes
  [[ "$output" == *"unreadable git state"* ]]
  grep -q personal "$ROOT/1_proj/file"
  [ -f "$ROOT/1_proj/wip" ]
  [ -f "$(lock_path 1)" ]
}

@test "forced orphan destroy previews differences and preserves all files before re-create" {
  printf 'personal\n' >> "$ROOT/1_proj/file"
  printf 'untracked\n' > "$ROOT/1_proj/wip"
  replace_source
  write_lock_default 1 owner=tester

  run agentws destroy 1 --force --yes --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$output" == *wip* ]]
  [ -d "$ROOT/1_proj" ]
  [ -f "$(lock_path 1)" ]
  [ "$(find "$ROOT" -maxdepth 1 -name '1_proj.orphaned.*' | wc -l)" -eq 0 ]

  run agentws destroy 1 --force --yes --json
  [ "$status" -eq 0 ]
  [[ "$output" == *"Preserved orphaned files at"* ]]
  local backup
  backup="$(find "$ROOT" -maxdepth 1 -name '1_proj.orphaned.*')/checkout"
  [ -d "$backup" ]
  grep -q personal "$backup/file"
  [ -f "$backup/wip" ]
  [ -f "$backup/.git" ]
  [ ! -e "$ROOT/1_proj" ]
  [ ! -f "$(lock_path 1)" ]
  run agentws create 1 --yes
  [ "$status" -eq 0 ]
  parked "$ROOT/1_proj"
}

@test "forced destroy refuses unreadable slots with surviving administration" {
  local admin
  admin="$(sed 's/^gitdir: //' "$ROOT/1_proj/.git")"
  mv "$admin/HEAD" "$admin/HEAD.saved"
  run agentws destroy 1 --force --yes
  [ "$status" -eq 7 ]
  [ -d "$ROOT/1_proj" ]
  [[ "$output" == *git*worktree\ repair* ]]
}

@test "orphan recovery works through a provider wrapping worktree" {
  mkdir "$SANDBOX/providers"
  printf '. "$AGENTWS_LIB/providers/worktree.sh"\n' > "$SANDBOX/providers/wrapped.sh"
  sed 's/provider: worktree/provider: wrapped/' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  printf 'provider_path: %s\n' "$SANDBOX/providers" >> "$CONFIG"
  replace_source
  run agentws doctor 1 --json
  [ "$status" -eq 8 ]
  local json="${lines[${#lines[@]}-1]}"
  printf '%s' "$json" | jq -e '.data.slots[0].checks | any(.id == "common-dir" and .status == "fail")' >/dev/null
  run agentws destroy 1 --force --yes --json
  [ "$status" -eq 0 ]
  json="${lines[${#lines[@]}-1]}"
  [ -f "$(printf '%s' "$json" | jq -r '.data.preserved_at')/file" ]
  run agentws create 1
  [ "$status" -eq 0 ]
  parked "$ROOT/1_proj"
}

@test "orphan recovery refuses without an available default-branch snapshot" {
  replace_source
  git -C "$SRC" branch -r -d origin/main
  run agentws destroy 1 --force --yes --json
  [ "$status" -eq 7 ]
  [ -d "$ROOT/1_proj" ]
  [ "$(find "$ROOT" -maxdepth 1 -name '1_proj.orphaned.*' | wc -l)" -eq 0 ]
}

@test "healthy doctor prints all provider checks and succeeds" {
  run agentws doctor 1
  [ "$status" -eq 0 ]
  [[ "$output" == *PASS*common-dir* ]]
  run agentws doctor 1 --json
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.ok and .data.ok' >/dev/null
}

@test "unreadable status cannot be treated as phantom dirt during reference sync" {
  shared_main_layout
  advance_main
  printf 'reference_slot: "1"\n' >> "$CONFIG"
  git() {
    case "$*" in *"status --porcelain"*) return 1 ;; esac
    command git "$@"
  }
  export -f git
  run agentws sync 1
  [ "$status" -eq 8 ]
  [[ "$output" == *"unreadable git state"* ]]
  [ "$(command git -C "$ROOT/1_proj" branch --show-current)" = "main" ]
  ! command git -C "$ROOT/1_proj" diff --cached --quiet
}

@test "missing reference creation explains prerequisite and warns about dependent slots" {
  printf 'reference_slot: "0"\n' >> "$CONFIG"
  sed 's/slots: \[1,2\]/slots: [0,1,2]/' "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  mv "$SRC" "$ROOT/0_proj"
  git -C "$ROOT/0_proj" worktree repair "$ROOT/1_proj" "$ROOT/2_proj"
  sed "s|source_repo: $SRC|source_repo: $ROOT/0_proj|" "$CONFIG" > "$CONFIG.new"
  mv "$CONFIG.new" "$CONFIG"
  mv "$ROOT/0_proj" "$SANDBOX/old-source"
  run agentws create 0
  [ "$status" -ne 0 ]
  [[ "$output" == *"reference clone must exist first"* ]]
  [[ "$output" == *"re-cloning"* ]]
  [[ "$output" == *"orphan"* ]]
  [[ "$output" != *"set provider_opts.source_repo"* ]]
}

advance_main() {
  printf 'new\n' >> "$SRC/file"
  git -C "$SRC" add file
  git -C "$SRC" commit -q -m new
  git -C "$SRC" push -q
}

parked() { # parked <slot-dir>: detached at origin/main
  ! git -C "$1" symbolic-ref -q HEAD >/dev/null &&
    [ "$(git -C "$1" rev-parse HEAD)" = "$(git -C "$1" rev-parse origin/main)" ]
}

# The layout before slots were parked: every idle slot on the one main ref.
shared_main_layout() {
  git -C "$ROOT/1_proj" checkout -q --ignore-other-worktrees main
  git -C "$ROOT/2_proj" checkout -q --ignore-other-worktrees main
}

@test "create parks slots detached, so a default-branch advance leaves them clean" {
  parked "$ROOT/1_proj"
  parked "$ROOT/2_proj"
  [ "$(git -C "$SRC" worktree list --porcelain | grep -c '^branch refs/heads/main$')" -eq 1 ]

  advance_main
  run agentws status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.data.slots[].dirty_state] | unique | join(",")')" = "clean" ]
  [ "$(printf '%s' "$output" | jq -r '[.data.slots[].claimable] | unique | join(",")')" = "true" ]
}

@test "refresh advances a parked slot that is behind and refuses local commits" {
  advance_main
  run agentws refresh --json 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots[0].status')" = "refreshed" ]
  parked "$ROOT/1_proj"

  run agentws refresh --json 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots[0].status')" = "unchanged" ]

  printf 'mine\n' > "$ROOT/2_proj/mine"
  git -C "$ROOT/2_proj" add mine
  git -C "$ROOT/2_proj" commit -q -m mine
  run agentws refresh --json 2
  [ "$status" -eq 8 ]
  git -C "$ROOT/2_proj" cat-file -e HEAD:mine
}

@test "refresh heals phantom dirt on a shared default branch and parks the slots" {
  shared_main_layout
  advance_main
  run agentws status --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '[.data.slots[].dirty_state] | unique | join(",")')" = "phantom-dirty" ]

  run agentws refresh --json 1
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slots[0].status')" = "refreshed" ]
  [ -z "$(git -C "$ROOT/1_proj" status --porcelain)" ]
  parked "$ROOT/1_proj"

  printf 'personal\n' >> "$ROOT/2_proj/file"
  run agentws refresh --json 2
  [ "$status" -eq 8 ]
  json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.error.code')" = "EGIT" ]
  grep -q personal "$ROOT/2_proj/file"

  # Parked slots share no ref: the next advance leaves slot 1 clean.
  advance_main
  [ -z "$(git -C "$ROOT/1_proj" status --porcelain)" ]
}

@test "doctor flags a branch checked out in more than one worktree" {
  run agentws doctor --json 1
  [ "$(printf '%s' "$output" | jq -r '[.data.slots[0].checks[] | select(.id=="shared_branch")] | length')" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="branch") | .status')" = "pass" ]

  shared_main_layout
  run agentws doctor --json 1
  [ "$(printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="shared_branch") | .status')" = "warn" ]
  printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="shared_branch") | .detail' | grep -q "$ROOT/2_proj"
}

@test "auto_refresh lets claim safely recover a phantom-dirty slot" {
  printf 'auto_refresh: true\n' >> "$CONFIG"
  shared_main_layout
  advance_main
  run agentws claim --json work
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slot')" = "1" ]
  [ "$(printf '%s' "$json" | jq -r '.data.dirty_state')" = "clean" ]
  parked "$ROOT/1_proj"
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
  [ "$(printf '%s' "$json" | jq -r '.data.parked_at')" = "origin/main" ]
  parked "$ROOT/1_proj"
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
  parked "$ROOT/1_proj"
}

@test "destroy refuses a format=2 lock; --force --yes gets past it" {
  write_lock_default 1 "format=2" "owner=other"
  run agentws destroy --json --yes 1
  [ "$status" -eq 9 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.error.code')" = "ELOCKFORMAT" ]
  [ -d "$ROOT/1_proj" ]

  run agentws destroy --force --yes 1
  [ "$status" -eq 0 ]
  [ ! -d "$ROOT/1_proj" ]
  [ ! -f "$(lock_path 1)" ]
}

@test "fullclone create parks the clone detached at origin/main" {
  sed -i.bak -e 's/^provider: worktree$/provider: fullclone/' -e 's/^slots: \[1,2\]$/slots: [3]/' \
    -e "s|^  source_repo: .*|  source_repo: $REMOTE|" "$CONFIG" && rm -f "$CONFIG.bak"
  run agentws create 3
  [ "$status" -eq 0 ]
  parked "$ROOT/3_proj"
  [ "$(agentws status --json | jq -r '.data.slots[0].claimable')" = "true" ]
}

@test "refresh leaves the reference slot on the default branch" {
  git -C "$ROOT/1_proj" checkout -q --ignore-other-worktrees main
  printf 'reference_slot: "1"\n' >> "$CONFIG"
  run agentws refresh --json
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.slots[] | select(.slot=="1") | .status')" = "skipped" ]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "main" ]
}

# ------------------------------------------------------- reference and sync
# Slot 1 as the reference, in the state the old sync left it: on main, which
# the source repo also has checked out.
reference_on_main() {
  git -C "$ROOT/1_proj" checkout -q --ignore-other-worktrees main
  printf 'reference_slot: "1"\n' >> "$CONFIG"
}

@test "sync heals the reference's phantom dirt and parks it at origin/main" {
  reference_on_main
  advance_main
  git -C "$ROOT/1_proj" fetch -q origin
  run agentws sync --json 1
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.data.synced[0].status')" = "ok" ]
  parked "$ROOT/1_proj"

  # Detached now, so the next advance reaches it through sync alone.
  advance_main
  run agentws sync 1
  [ "$status" -eq 0 ]
  parked "$ROOT/1_proj"
}

@test "sync on a dirty reference names the paths and exits non-zero" {
  reference_on_main
  advance_main
  printf 'local\n' >> "$ROOT/1_proj/file"
  run agentws sync 1
  [ "$status" -eq 8 ]
  [[ "$output" == *"M file"* ]]
  [[ "$output" == *"sync failed: 1_proj"* ]]
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "main" ]

  run agentws sync --json 1
  [ "$status" -eq 8 ]
  [ "$(printf '%s' "${lines[${#lines[@]}-1]}" | jq -r '.error.code')" = "EGIT" ]
}

@test "sync refuses a detached reference carrying its own commits" {
  printf 'reference_slot: "1"\n' >> "$CONFIG"
  printf 'mine\n' > "$ROOT/1_proj/mine"
  git -C "$ROOT/1_proj" add mine
  git -C "$ROOT/1_proj" commit -q -m mine
  run agentws sync 1
  [ "$status" -eq 8 ]
  git -C "$ROOT/1_proj" cat-file -e HEAD:mine
}

@test "status and doctor show a detached slot as detached@sha" {
  local sha
  sha="$(git -C "$ROOT/2_proj" rev-parse --short HEAD)"
  run agentws status
  [ "$status" -eq 0 ]
  [[ "$output" == *"detached@$sha"* ]]
  [[ "$output" != *"no upstream"* ]]
  [ "$(agentws status --json | jq -r '.data.slots[] | select(.slot=="2") | .branch')" = "detached@$sha" ]
  [ "$(agentws status --json | jq -r '.data.slots[] | select(.slot=="2") | .warnings | length')" -eq 0 ]

  run agentws doctor --json 2
  [ "$(printf '%s' "$output" | jq -r '.data.ok')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="branch") | .detail')" = "detached@$sha" ]
}

@test "doctor reports each check once and warns for a reference off the default branch" {
  printf 'reference_slot: "1"\n' >> "$CONFIG"
  git -C "$ROOT/1_proj" switch -q -c feat/x
  run agentws doctor --json 1
  [ "$(printf '%s' "$output" | jq -r '[.data.slots[0].checks[].id] | length == (unique | length)')" = "true" ]
  [ "$(printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="branch") | .status')" = "warn" ]

  git -C "$ROOT/1_proj" checkout -q --detach origin/main
  run agentws doctor --json 1
  [ "$(printf '%s' "$output" | jq -r '.data.slots[0].checks[] | select(.id=="branch") | .status')" = "pass" ]
}
