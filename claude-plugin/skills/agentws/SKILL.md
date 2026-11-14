---
name: agentws
description: Claim, bootstrap, use, and recycle an isolated agentws slot for any task that needs its own checkout — parallel workers, a second branch, a headless worker dispatch, or "check out the repo for a worker". Use whenever `agentws status` works on this machine or the cwd is inside a slot farm; never create ad-hoc worktrees of a farmed repo.
---

# agentws slot lifecycle

One slot = one task = one lock. If anything below is unclear, `AGENTS.md` in
the agentws repository
(<https://github.com/esola-thomas/agentws/blob/main/AGENTS.md>) is the full
contract.

This skill drives the `agentws` CLI. If `agentws status` is not found, the CLI
is not installed: say so and point to `/agentws:init`. Do not run a remote installer
from this skill; tell the developer to install the CLI separately and use plain git.

## Am I an orchestrator or a worker?

- **Worker** (launched by an orchestrator, cwd already inside `N_<top>`):
  skip to "Inside the slot". Do not claim, lock, or recycle.
- **Orchestrator / interactive**: claim first.

## Claim (orchestrator)

```bash
export AGENTWS_PID=$$ AGENTWS_OWNER="<harness>:<task>"   # e.g. claude:fix-parser
agentws free                                   # or MCP workspace_status
eval "$(agentws claim '<task>' --print-env)"   # AGENTWS_SLOT, AGENTWS_WS, WS
agentws claim '<task>' --json | jq -r .data.bootstrap_hint   # run it in the slot
```

Prefer the MCP tools (`workspace_claim`, `workspace_status`, `workspace_recycle`)
when they are loaded; they are the same CLI without `--force`. A refusal
(busy, stale lock, not claimable) is final: report it, or pick another slot.
Never loop on a claim, never force, never ask the human to force. Chain
anything that needs the lock with `&&`, never `;`, so a refusal stops it.

```bash
agentws claim --slot 3 '<task>'                # one specific slot, same refusals
AGENTWS_PID=$$ agentws lock --takeover "$AGENTWS_SLOT"   # after a restart: re-bind your own lock
```

Never `unlock N; lock N` to re-enter a slot: `--takeover` does it atomically
and only for the same owner.

Dispatching a headless worker into the slot (Claude Code shown; any headless
harness works the same way, with cwd set to the slot):

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
2. **Label shared resources.** The claim notice (stderr of `claim`, or the
   session-start hook inside a locked slot) names the slot's label, for
   example `myrepo_3` (`AGENTWS_LABEL`). Suffix every database, container,
   compose project, and temp dir you create outside the checkout with it,
   offset ports by the slot number, and follow the notice's project lines.
3. **Branch now.** `git checkout -b <branch> origin/<base>`. An idle slot is
   parked detached at `origin/<default>`; a commit made there is on no branch.
4. **Foreground only.** Every gate, test, and reviewer call is a plain Bash
   call with an explicit `timeout: 600000`. Never `run_in_background`, never
   Monitor or task tools to wait, never end a turn saying what you will run
   next. A headless session dies when the turn ends; notifications never
   arrive.
5. **Checkpoint at each milestone**, from inside the slot:
   `agentws checkpoint set --phase <phase> --pr <url> --next '<next step>'`
   (MCP `workspace_checkpoint`). It lives beside the lock, not in the
   checkout. On resume, `agentws checkpoint show` first; it also prints what
   the previous owner left.
6. **Verify against CI's shape**, not a source checkout: same build artifact,
   same pinned linter versions, `git status` clean after any formatter.
7. **Finish** with the project's PR pipeline, or `STATUS: BLOCKED` after three
   failed fix iterations. Print the PR URL as the last line.

## Recycle (orchestrator, after merge)

```bash
agentws recycle "$AGENTWS_SLOT"     # fetch, park at origin/<default>, drop branch, unlock
agentws refresh                     # park idle slots at the new origin/<default>
agentws reap                        # recycle every finished slot with a stale or no lock
```

Submodule pointer merges are handled: `recycle` and `refresh` resync submodules
to the revision they reset to. If one cannot be restored, the command fails and
keeps the lock rather than handing on a dirty slot.

## Never

`git worktree remove` / `rm -rf` / `reset --hard` on a slot · `git checkout
<default>` inside a slot · editing a slot you do not hold · a second task in
the same claim.

In Claude Code, the `agentws hook pre-tool-use` guard denies edits to another
slot or the reference slot, `git checkout <default>`, and `git reset --hard`
when the session is inside a slot. A denial is the contract, not a bug: do
not work around it.
