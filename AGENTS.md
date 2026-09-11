# agentws for AI agents

This file is for the coding agent reading it: Claude Code, Codex, Copilot CLI,
Cursor, Aider, or anything else that can run a shell command. It is the whole
contract. Nothing in the rest of the repo overrides it.

## When this applies

If `agentws status` prints a table, or `AGENTWS_CONFIG` is set, you are on a
machine with a slot farm: a set of isolated checkouts, each claimable by
exactly one agent at a time. On such a machine:

- Never edit files inside a slot you do not hold the lock on.
- Never create ad-hoc `git worktree`s or clones of the farmed repository when
  a free slot exists. Claim a slot instead.
- If `agentws` is not installed at all, none of this applies; use plain git.

## The ritual

```bash
export AGENTWS_PID=$$                        # the shell that outlives the task
export AGENTWS_OWNER="<harness>:<task>"      # e.g. claude:mc7-mission-home

eval "$(agentws claim '<one-line task>' --print-env)"
cd "$AGENTWS_WS"                             # also exported: AGENTWS_SLOT, WS

# 1. Bootstrap BEFORE the first build or test. The claim envelope carries a
#    provider hint: agentws claim '<task>' --json | jq -r .data.bootstrap_hint
#    If it is empty, follow the project's own setup doc. A slot whose first
#    quality gate fails on missing tooling is a bootstrap you skipped.

# 2. Branch immediately. Slots share the default-branch ref; a commit on the
#    default branch inside a slot moves it for every other slot.
git checkout -b <branch> origin/<base>

# 3. Work. Commit. Push. Open the PR the way the project says to.

# 4. After the PR merges (or when abandoning the task):
agentws recycle "$AGENTWS_SLOT"              # fetch, reset to origin/<default>,
                                             # delete the task branch, release
```

`agentws done` is the same command as `recycle`. Untracked files block
recycling; pass `--clean-untracked` only for files you created.

## Refusals are final

- A busy slot, a stale-lock refusal, or a "not claimable" answer is the
  answer. Report it and stop, or claim a different slot. Never retry the same
  claim in a loop, never pass `--force`, never ask a human to force it for you.
  The MCP server has no force parameter by design.
- Never `git worktree remove`, `rm -rf`, or `git reset --hard` a slot. Slots
  are permanent; `recycle` is the only reset you run, and only on your own.
- Never `git checkout <default-branch>` inside a slot to "clean up". It is
  refused (the branch is held by the reference slot). `recycle` handles it.

## Things that look like your problem and are not

- `phantom-dirty` on idle slots after a merge is shared-ref drift, not
  uncommitted work. `agentws refresh` heals it; it refuses anything that is
  real dirt.
- A slot showing `N files dirty` that you do not hold belongs to someone
  else's in-flight task. Leave it.
- Lock liveness is tied to `AGENTWS_PID`. If you fork a subprocess to do the
  work, the lock still belongs to the shell you exported.

## Orchestrator vs worker

An **orchestrator** claims one slot per worker, launches each worker with
`cwd` set to that slot, and recycles the slot after the worker's PR merges.
A **worker** is already inside its slot when it starts: it does not claim,
lock, or recycle unless its brief says so. It bootstraps, branches, works,
and ends with a PR URL or `STATUS: BLOCKED`.

Both read `agentws status --json`; the JSON envelope (`ok`, `command`, `data`,
`error`) is the stable interface. Human text goes to stderr, so piping to `jq`
is always safe.

## Claude Code specifics

`skills/agentws/SKILL.md` in this repo is a Claude Code skill with the same
ritual plus the headless-worker rules; `install.sh` links it into
`~/.claude/skills/agentws`. The MCP server (`mcp/agentws-mcp`) exposes the
lifecycle as `workspace_*` tools. Either path runs the same CLI.
