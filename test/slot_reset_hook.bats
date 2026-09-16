#!/usr/bin/env bats
#
# Issue #9. `recycle` returns the parent worktree to the default branch, but a
# checkout does not move a submodule working tree. Without provider_slot_reset
# the slot is left dirty and unclaimable, and the lock is released anyway.
#
# Every assertion here is about the SLOT ($ROOT/1_proj), never about $SRC. A
# linked worktree gets its own submodule git dir
# ($SRC/.git/worktrees/<wt>/modules/sub), so the slot's submodule HEAD is
# independent of the source repo's and of every other slot's.

load helper

setup() {
  SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agentws-submodule.XXXXXX")"
  ROOT="$SANDBOX/ws"
  LOCKS="$SANDBOX/locks"
  SRC="$SANDBOX/source"
  REMOTE="$SANDBOX/remote.git"
  SUBREMOTE="$SANDBOX/subremote.git"
  CONFIG="$SANDBOX/.agentws.yml"
  mkdir -p "$ROOT" "$LOCKS"

  # Hermetic git config. git refuses local-path submodule transport by default
  # since the 2.38.1/2.34.6 backport, and the sandbox must not depend on, or
  # touch, whatever the developer has configured.
  export GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
  export GIT_CONFIG_SYSTEM=/dev/null
  git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always
  git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
  git config --file "$GIT_CONFIG_GLOBAL" user.name tester
  # The bare remotes are `init --bare`d here, so their HEAD must agree with the
  # branch the tests push, or `submodule add` clones a branch yet to be born.
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main

  # The submodule: two commits, SUB_A then SUB_B.
  git init -q --bare "$SUBREMOTE"
  git clone -q "$SUBREMOTE" "$SANDBOX/sub"
  git -C "$SANDBOX/sub" switch -q -c main
  printf 'a\n' > "$SANDBOX/sub/f"
  git -C "$SANDBOX/sub" add f
  git -C "$SANDBOX/sub" commit -q -m a
  git -C "$SANDBOX/sub" push -q -u origin main
  SUB_A="$(git -C "$SANDBOX/sub" rev-parse HEAD)"
  printf 'b\n' > "$SANDBOX/sub/f"
  git -C "$SANDBOX/sub" add f
  git -C "$SANDBOX/sub" commit -q -m b
  git -C "$SANDBOX/sub" push -q
  SUB_B="$(git -C "$SANDBOX/sub" rev-parse HEAD)"

  # The superproject: main pins sub at SUB_A.
  git init -q --bare "$REMOTE"
  git clone -q "$REMOTE" "$SRC"
  git -C "$SRC" switch -q -c main
  printf 'old\n' > "$SRC/file"
  git -C "$SRC" add file
  git -C "$SRC" commit -q -m old
  git -C "$SRC" submodule add -q "$SUBREMOTE" sub
  git -C "$SRC/sub" checkout -q "$SUB_A"
  git -C "$SRC" add .gitmodules sub
  git -C "$SRC" commit -q -m "pin sub at A"
  git -C "$SRC" push -q -u origin main

  git -C "$SRC" worktree add -q --force "$ROOT/1_proj" main
  git -C "$ROOT/1_proj" submodule update --init -q

  {
    printf 'version: 1\n'
    printf 'root: %s\n' "$ROOT"
    printf 'top: proj\n'
    printf 'provider: worktree\n'
    printf 'default_branch: main\n'
    printf 'slots: [1]\n'
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
}

teardown() { teardown_sandbox; }

# Put the slot in the state the issue describes: on a task branch whose gitlink
# is SUB_B while origin/main still pins SUB_A. The slot is CLEAN here, which is
# why the old recycle sailed through its gates.
on_branch_with_bumped_submodule() {
  git -C "$ROOT/1_proj" switch -q -c feat/sub
  git -C "$ROOT/1_proj/sub" checkout -q "$SUB_B"
  git -C "$ROOT/1_proj" add sub
  git -C "$ROOT/1_proj" commit -q -m "bump sub to B"
  [ -z "$(git -C "$ROOT/1_proj" status --porcelain)" ]
}

slot_claimable_json() {
  agentws status --json | jq -r '.data.slots[] | select(.slot=="1") | .claimable'
}

@test "recycle resyncs submodules so the slot is left claimable" {
  on_branch_with_bumped_submodule
  agentws lock 1 work >/dev/null

  run agentws recycle --json 1
  [ "$status" -eq 0 ]

  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "main" ]
  [ "$(git -C "$ROOT/1_proj/sub" rev-parse HEAD)" = "$SUB_A" ]
  [ -z "$(git -C "$ROOT/1_proj" status --porcelain)" ]
  [ "$(slot_claimable_json)" = "true" ]
  [ ! -f "$(lock_path 1)" ]
}

@test "recycle unsticks a slot an older recycle left dirty" {
  # Exactly what the pre-fix recycle left behind: parent on main, submodule
  # still at the task branch's commit. The old tracked-dirt gate refused this
  # with "has tracked changes that recycle will not discard", forever.
  on_branch_with_bumped_submodule
  git -C "$ROOT/1_proj" checkout --ignore-other-worktrees -B main origin/main --quiet
  [ -n "$(git -C "$ROOT/1_proj" status --porcelain)" ]
  [ "$(slot_claimable_json)" = "false" ]

  run agentws recycle --json 1
  [ "$status" -eq 0 ]
  [ "$(git -C "$ROOT/1_proj/sub" rev-parse HEAD)" = "$SUB_A" ]
  [ "$(slot_claimable_json)" = "true" ]
}

@test "recycle refuses uncommitted work inside a submodule and keeps the lock" {
  on_branch_with_bumped_submodule
  agentws lock 1 work >/dev/null
  printf 'mine\n' >> "$ROOT/1_proj/sub/f"

  run agentws recycle --json --clean-untracked 1
  [ "$status" -eq 8 ]
  local json="${lines[${#lines[@]}-1]}"
  printf '%s' "$json" | jq -r '.error.message' | grep -q submodule
  [ -f "$(lock_path 1)" ]
  grep -q mine "$ROOT/1_proj/sub/f"
  git -C "$ROOT/1_proj" show-ref --verify --quiet refs/heads/feat/sub
}

@test "recycle reports untracked files inside a submodule and removes them on consent" {
  on_branch_with_bumped_submodule
  printf 'scratch\n' > "$ROOT/1_proj/sub/SCRATCH"
  [ "$(slot_claimable_json)" = "false" ]

  run agentws recycle --json 1
  [ "$status" -eq 8 ]
  printf '%s' "$output" | grep -q 'sub/SCRATCH'
  [ -e "$ROOT/1_proj/sub/SCRATCH" ]

  run agentws recycle --json --clean-untracked 1
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.removed_untracked[0]')" = "sub/SCRATCH" ]
  [ ! -e "$ROOT/1_proj/sub/SCRATCH" ]
  [ "$(slot_claimable_json)" = "true" ]
}

@test "refresh heals a slot whose only dirt is a lagging submodule" {
  on_branch_with_bumped_submodule
  git -C "$ROOT/1_proj" checkout --ignore-other-worktrees -B main origin/main --quiet
  [ "$(git -C "$ROOT/1_proj/sub" rev-parse HEAD)" = "$SUB_B" ]

  run agentws refresh --json 1
  [ "$status" -eq 0 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.data.slots[0].status')" = "refreshed" ]
  [ "$(git -C "$ROOT/1_proj/sub" rev-parse HEAD)" = "$SUB_A" ]
  [ "$(slot_claimable_json)" = "true" ]
}

@test "--dry-run reports the submodule sync without performing it" {
  on_branch_with_bumped_submodule

  run agentws --dry-run recycle 1
  [ "$status" -eq 0 ]
  printf '%s' "$output" | grep -q 'dry-run.*submodule update --init --recursive --checkout'
  [ "$(git -C "$ROOT/1_proj" branch --show-current)" = "feat/sub" ]
  [ "$(git -C "$ROOT/1_proj/sub" rev-parse HEAD)" = "$SUB_B" ]
}

@test "recycling one slot does not disturb another slot's submodule" {
  git -C "$SRC" worktree add -q --force "$ROOT/2_proj" main
  git -C "$ROOT/2_proj" submodule update --init -q
  sed -i.bak 's/^slots: \[1\]$/slots: [1,2]/' "$CONFIG" && rm -f "$CONFIG.bak"
  git -C "$ROOT/2_proj/sub" checkout -q "$SUB_B"

  on_branch_with_bumped_submodule
  run agentws recycle --json 1
  [ "$status" -eq 0 ]

  [ "$(git -C "$ROOT/1_proj/sub" rev-parse HEAD)" = "$SUB_A" ]
  [ "$(git -C "$ROOT/2_proj/sub" rev-parse HEAD)" = "$SUB_B" ]
}

# --------------------------------------------------- the hook itself, wired
# These override the contract default, so they prove the dispatch rather than
# the default's behaviour: that core passes slot, path, and target ref, that a
# provider's own implementation wins, and that a refusal is honoured.

install_reset_provider() { # install_reset_provider <body>
  local priv="$SANDBOX/private-providers"
  mkdir -p "$priv"
  {
    printf '#!/usr/bin/env bash\n'
    printf '. "$AGENTWS_LIB_DIR/../providers/worktree.sh"\n'
    printf 'provider_slot_reset() { %s\n}\n' "$1"
  } > "$priv/mine.sh"
  sed -i.bak 's/^provider: worktree$/provider: mine/' "$CONFIG" && rm -f "$CONFIG.bak"
  printf 'provider_path: "%s"\n' "$priv" >> "$CONFIG"
}

@test "core calls provider_slot_reset with the slot, path, and target ref" {
  # The hook also writes to stdout. That is the guard against a chatty provider
  # being captured as the recycle envelope's data.
  install_reset_provider 'printf "%s|%s|%s\n" "$1" "$2" "$3" >> "'"$SANDBOX"'/hook.log"
  printf "provider noise on stdout\n"
  git -C "$2" submodule update --init --recursive --checkout --quiet'
  on_branch_with_bumped_submodule

  run agentws recycle --json 1
  [ "$status" -eq 0 ]
  [ "$(cat "$SANDBOX/hook.log")" = "1|$ROOT/1_proj|origin/main" ]

  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.ok')" = "true" ]
  [ "$(printf '%s' "$json" | jq -r '.data.slot')" = "1" ]
}

@test "a failing provider_slot_reset fails recycle and keeps the lock" {
  install_reset_provider 'return 3'
  on_branch_with_bumped_submodule
  agentws lock 1 work >/dev/null

  run agentws recycle --json 1
  [ "$status" -eq 7 ]
  local json="${lines[${#lines[@]}-1]}"
  [ "$(printf '%s' "$json" | jq -r '.error.code')" = "EPROVIDER" ]
  [ -f "$(lock_path 1)" ]
}

@test "a silent provider_slot_reset that leaves submodules stale still fails" {
  # The post-condition: recycle reporting success has to mean claimable, even
  # when a provider returns 0 without doing the work.
  install_reset_provider ':'
  on_branch_with_bumped_submodule
  agentws lock 1 work >/dev/null

  run agentws recycle --json 1
  [ "$status" -eq 7 ]
  [ -f "$(lock_path 1)" ]
  printf '%s' "$output" | grep -q 'would not be claimable'
}
