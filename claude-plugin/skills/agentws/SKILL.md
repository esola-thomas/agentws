---
name: agentws
description: Claim, bootstrap, use, and recycle an isolated agentws slot for any task that needs its own checkout — parallel workers, a second branch, a headless worker dispatch, or "check out the repo for a worker". Use whenever `agentws status` works on this machine or the cwd is inside a slot farm; never create ad-hoc worktrees of a farmed repo.
---

# agentws slot lifecycle

One slot = one task = one lock. This skill is self-contained: everything an
agent needs to use a slot farm is below.

This skill drives the `agentws` CLI already installed on the machine. If
`agentws status` is not found, the CLI is not installed: say so, point the
developer to `/agentws:init`, and continue with plain git. Do not install
anything from this skill. Do not run a remote installer from this skill.

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
when the developer has set them up; they are the same CLI without `--force`. A
refusal (busy, stale lock, not claimable) is final: report it, or pick another
slot. Never loop on a claim, never force, never ask the human to force. Chain a
command that depends on a lock with `&&`, not `;`, so a refusal stops it.

```bash
agentws claim --slot 3 '<task>'                # one specific slot, same refusals
AGENTWS_PID=$$ agentws lock --takeover "$AGENTWS_SLOT"   # after a restart: re-bind your own lock
```

Never `unlock N; lock N` to re-enter a slot: `--takeover` does it atomically
and only for the same owner.

To hand a slot to another agent, start that agent with its working directory
set to `$AGENTWS_WS` and the task in its prompt, using whatever launch method
and permission settings the developer already uses. The worker's work stays on
disk in the slot, so a stopped worker can be resumed in the same directory.

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
4. **Checkpoint at each milestone**, from inside the slot:
   `agentws checkpoint set --phase <phase> --pr <url> --next '<next step>'`
   (MCP `workspace_checkpoint`). It lives beside the lock, not in the
   checkout. On resume, `agentws checkpoint show` first; it also prints what
   the previous owner left.
5. **Verify against CI's shape**, not a source checkout: same build artifact,
   same pinned linter versions, `git status` clean after any formatter.
6. **Finish** with the project's PR process, or report the task as blocked
   with what failed. In a headless run, end with the PR URL.

## Recycle (orchestrator, after merge)

```bash
agentws recycle "$AGENTWS_SLOT"     # fetch, park at origin/<default>, drop branch, unlock
agentws refresh                     # park idle slots at the new origin/<default>
agentws reap                        # recycle every finished slot with a stale or no lock
```

Untracked files block `recycle`; pass `--clean-untracked` only for files you
created. Submodule pointer merges are handled: `recycle` and `refresh` resync
submodules to the revision they reset to. If one cannot be restored, the
command fails and keeps the lock rather than handing on a dirty slot.

## Things that look like your problem and are not

- `phantom-dirty` on an idle slot left on the default branch is shared-ref
  drift, not uncommitted work. `agentws refresh` heals it.
- A slot showing `N files dirty` that you do not hold belongs to someone
  else's task. Leave it.
- Lock liveness follows `AGENTWS_PID`. A subprocess you start does not own the
  lock; the shell you exported it from does.

## Never

`git worktree remove` / `rm -rf` / `reset --hard` on a slot · `git checkout
<default>` inside a slot · editing a slot you do not hold · a second task in
the same claim.

In Claude Code, the `agentws hook pre-tool-use` guard denies edits to another
slot or the reference slot, `git checkout <default>`, and `git reset --hard`
when the session is inside a slot. A denial is the contract, not a bug: do
not work around it.
