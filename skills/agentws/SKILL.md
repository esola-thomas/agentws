---
name: agentws
description: Claim, bootstrap, use, and recycle an isolated agentws slot for any task that needs its own checkout — parallel workers, a second branch, a headless worker dispatch, or "check out the repo for a worker". Use whenever `agentws status` works on this machine or the cwd is inside a slot farm; never create ad-hoc worktrees of a farmed repo.
---

# agentws slot lifecycle

One slot = one task = one lock. Read `AGENTS.md` next to this skill if anything
below is unclear; it is the full contract.

## Am I an orchestrator or a worker?

- **Worker** (launched by an orchestrator, cwd already inside `N_<top>`):
  skip to "Inside the slot". Do not claim, lock, or recycle.
- **Orchestrator / interactive**: claim first.

## Claim (orchestrator)

```bash
export AGENTWS_PID=$$ AGENTWS_OWNER="claude:<task>"
agentws free                                   # or MCP workspace_status
eval "$(agentws claim '<task>' --print-env)"   # AGENTWS_SLOT, AGENTWS_WS, WS
agentws claim '<task>' --json | jq -r .data.bootstrap_hint   # run it in the slot
```

Prefer the MCP tools (`workspace_claim`, `workspace_status`, `workspace_recycle`)
when they are loaded; they are the same CLI without `--force`. A refusal
(busy, stale lock, not claimable) is final: report it, or pick another slot.
Never loop on a claim, never force, never ask the human to force.

Dispatching a headless worker into the slot:

```bash
cd "$AGENTWS_WS" && <render brief> | \
  API_TIMEOUT_MS=600000 NODE_OPTIONS=--dns-result-order=ipv4first \
  claude -p --model <tier> --dangerously-skip-permissions > <task>.log 2>&1
```

Run that as ONE foreground Bash call with `timeout: 600000`, or background the
whole script and wait for its exit; never background pieces of it. Recovery
for a stalled or killed worker is `claude --continue -p "<ruling>"` in the same
cwd with the same env and flags; the work on disk is always intact.

## Inside the slot (everyone)

1. **Bootstrap before the first gate.** Run the bootstrap hint or the
   project's setup doc (`uv sync`, `npm ci`, the project's setup script,
   submodule init). A first gate that fails on missing tooling is not a code problem.
2. **Branch now.** `git checkout -b <branch> origin/<base>`. Never commit on
   the default branch inside a slot: the ref is shared with every other slot.
3. **Foreground only.** Every gate, test, and reviewer call is a plain Bash
   call with an explicit `timeout: 600000`. Never `run_in_background`, never
   Monitor or task tools to wait, never end a turn saying what you will run
   next. A headless session dies when the turn ends; notifications never
   arrive.
4. **Verify against CI's shape**, not a source checkout: same build artifact,
   same pinned linter versions, `git status` clean after any formatter.
5. **Finish** with the project's PR pipeline, or `STATUS: BLOCKED` after three
   failed fix iterations. Print the PR URL as the last line.

## Recycle (orchestrator, after merge)

```bash
agentws recycle "$AGENTWS_SLOT"     # fetch, reset to origin/<default>, drop branch, unlock
agentws refresh                     # heal phantom-dirty idle slots the merge created
```

Submodule pointer merges are handled: `recycle` and `refresh` resync submodules
to the revision they reset to. If one cannot be restored, the command fails and
keeps the lock rather than handing on a dirty slot.

## Never

`git worktree remove` / `rm -rf` / `reset --hard` on a slot · `git checkout
<default>` inside a slot · editing a slot you do not hold · a second task in
the same claim.
