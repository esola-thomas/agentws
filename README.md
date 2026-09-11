# agentws

Coordinate AI coding agents across isolated git workspaces.

`agentws` is a single bash script that arbitrates which agent owns which checkout.
It hands out advisory locks, reports which workspaces are free, syncs and prunes
them, and exposes the same operations to agent tooling over MCP.

## The problem

Two coding agents in one checkout is a data-loss event. One writes a file, the
other overwrites it, and the reconciliation afterwards costs more than the work
either of them did. The usual answers do not hold:

- A single agent at a time wastes the machine.
- One branch per agent still shares a working tree.
- Ad-hoc "I'm using slot 2" messages in chat are not enforceable and are not
  readable by a tool.

`agentws` gives each agent a real directory of its own, with a lock file that
records who holds it, why, since when, and on which host. Any agent, or any
human, can ask which slots are free and get a machine-readable answer.

The hard part is not taking a lock. It is deciding when a lock is dead. That is
what most of this codebase is: see [docs/LOCKING.md](docs/LOCKING.md).

## 60-second quickstart

```bash
git clone <this repo> ~/src/agentws
~/src/agentws/install.sh                 # two symlinks into ~/.local/bin

cd ~/work/myproj
agentws init                             # write a starter .agentws.yml
$EDITOR .agentws.yml                     # set root, top, slots, default_branch

agentws create 1                         # make a slot via the provider
agentws status                           # branch, dirty, lock, claimable

export AGENTWS_PID=$$                    # your long-lived shell; enables liveness
export AGENTWS_OWNER="claude:refactor"
eval "$(agentws claim 'refactor the parser' --print-env)"
cd "$AGENTWS_WS"
# ... work ...
agentws done 1                         # after the task branch has merged
```

Every command takes `--json` and prints exactly one envelope line on stdout:

```json
{"ok":true,"command":"claim","data":{"slot":"1","path":"/home/u/work/myproj/1_myproj"},"error":null}
```

Human narrative always goes to stderr, so `--json` output is safe to pipe into
`jq` without filtering.

## For coding agents

[AGENTS.md](AGENTS.md) is the contract an AI agent follows on a machine with a
slot farm: claim, bootstrap from the claim's `bootstrap_hint`, branch off
`origin/<base>`, work, `recycle`. It is harness-neutral. Claude Code
additionally gets the `/agentws` skill (`skills/agentws/`, linked by
`install.sh` into `~/.claude/skills`) and the MCP server below; Codex and
other tools read `AGENTS.md` and call the CLI.

## Forge-agnostic

`agentws` uses plain git porcelain only: `fetch`, `branch`, `status`,
`rev-parse`, `worktree`, `clone`, `checkout`, `reset`, and `clean`. It never calls a forge API. There is no `gh`,
no `az`, no `glab`, no REST client, no token, no PAT storage.

That means it works identically against GitHub, Azure DevOps, GitLab,
Bitbucket, Gerrit, a self-hosted Gitea, or a bare repository on a shared
filesystem with no server at all. If `git fetch` works, `agentws` works.

This is a deliberate scope limit, not a gap. `gh` and the vendor MCP servers
already read issues and open pull requests. Adding that here would make a lock
manager hold credentials.

## Providers

A provider decides what a slot physically is. It implements a 7-function
contract and is a single `.sh` file under `providers/`. Providers may not read
or write the lock directory: locking is core-only.

| Provider | What a slot is | When to use it |
|---|---|---|
| `worktree` | `git worktree add` off one source repo | Default. Fast, one object store, low disk. |
| `fullclone` | An independent `git clone` per slot | When slots need untracked per-slot state, or separate build trees, that a worktree cannot carry. |

Write your own by copying `providers/_contract.sh`, implementing the hooks you
need, and naming it in `provider:` in your config. A provider that belongs to
one project (private setup scripts, submodule lists) can live outside this
checkout: set `provider_path: "{root}/.agentws/providers"` and put
`<name>.sh` there; those directories are searched before the bundled ones. Project-aware providers can
also implement `provider_env_check`, `provider_env_setup`, and
`provider_bootstrap_hint`. There is no plugin registry and nothing is downloaded.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and `providers/_contract.sh` for the contract.

## Agent tool integration

`mcp/agentws-mcp` is an optional JSON-RPC stdio server in bash and jq. It
exposes the full slot lifecycle and never touches a lock file itself; every
action is one `exec` of `agentws --json`, the same ABI the CLI uses.

| Tool | Arguments |
|---|---|
| `workspace_status` | none |
| `workspace_claim` | `reason`; optional `ttl`, `task_id`, `branch`, `agent`, `require_env` |
| `workspace_lock` | `slot`, `reason`; optional TTL and metadata |
| `workspace_release` | `slot` |
| `workspace_sync` | `slot` (optional) |
| `workspace_doctor` | `slot` (optional), `fix_env` (optional) |
| `workspace_refresh` | `slot` (optional) |
| `workspace_prune` | `slot`, `confirm` (both optional) |
| `workspace_create` | `slot`, `with_env` (optional) |
| `workspace_recycle` | `slot`, `branch`, `clean_untracked` (last two optional) |
| `workspace_done` | same as `workspace_recycle` |

There is no `force` parameter on any of them, by design. A busy slot returns a
structured refusal so the model reports the block instead of retrying into it.
Only a human at the CLI can pass `--force`.

### Tool support

| Tool | Status | How |
|---|---|---|
| Claude Code | Verified working | Merge `mcp/claude_code.example.json` into `~/.claude.json` |
| GitHub Copilot CLI | Verified working | Merge `mcp/copilot.example.json` into its MCP config |
| Codex | CLI via `AGENTS.md` | Reads `AGENTS.md` at the repo root; runs the CLI fallback below |
| Cursor | Untested | Use the CLI fallback below |
| Aider | Untested | Use the CLI fallback below |
| Anything else | Untested | Use the CLI fallback below |

"Untested" means exactly that. These tools are not claimed to be compatible and
have not been run against this server. If you test one, report what happened.

**Universal fallback.** Any tool that can run a shell command can use
`agentws`, MCP or not:

```bash
agentws status --json
agentws claim "reason" --json
agentws unlock 1 --json
```

## Slot lifecycle

`status` and `free` report `env: ready | missing | stale`. `claim` prefers a
ready environment, while `claim --require-env` refuses to fall back. Providers
can return a bootstrap hint with the claimed slot. Use `create --with-env` to
provision a new slot or `doctor --fix-env` to repair one.

Worktree slots can become `phantom-dirty` when another worktree advances the
shared default branch ref. `refresh` heals only a tree whose index exactly
matches an ancestor of `origin/<default_branch>` and whose working tree has no
extra tracked or untracked changes. All other dirt is refused. Set
`auto_refresh: true` to run the same proof before claim skips such a slot.

After a task branch has merged, `recycle <slot>` fetches, returns the slot to
the remote default branch, deletes the local task branch, and releases the
caller's lock. Untracked files are listed and block recycling unless
`--clean-untracked` is explicit. `done` is the shorter spelling of `recycle`.

Claims can carry `--task-id`, `--branch`, and `--agent` metadata. A per-claim
`--ttl H` is stored on the lock and capped by `ttl_hours`. `status` and `locks`
show the remaining TTL. Optional finished-slot reaping is configured with
`auto_release: true` and `auto_release_minutes: N`; `doctor` starts a quiet
observation period and releases only a locked, clean slot that remains on the
default branch at the same commit for that period.

The JSON envelope is the stable interface. MCP is a convenience on top of it,
not a requirement.

## Platform support

| Platform | Status | Liveness detection |
|---|---|---|
| Linux | Fully supported | Full. `/proc` present, including pid start-time reuse detection. |
| macOS | Supported, degraded locking | **TTL only.** There is no `/proc`, so process death is never detected. A lock held by a killed agent survives until `ttl_hours` elapses. Recommended config: `ttl_hours: 4`. |
| WSL2 on Windows | Fully supported | Full. It is Linux. The recommended Windows route. |
| Git Bash / MSYS2 | Best-effort, not supported | TTL only, same as macOS. `noclobber` atomicity on NTFS is unverified. |
| Windows native | Not supported | No cmd.exe or PowerShell path exists. |

The macOS degradation is safe, not unsafe: `agentws` never frees a live lock
there, it just cannot free a dead one early. It is also never silent.
`agentws doctor` warns, `agentws locks --json` carries
`"liveness_supported": false`, and `agentws lock` prints a one-line warning to
stderr once per day.

Cross-host is handled the same way on every platform: if a lock records a
different `host` than the current machine, its pid means nothing locally and the
lock is treated as alive. This matters on shared filesystems, where a job on
another node reading the lock directory must not conclude the lock is dead.

## Requirements

- bash 3.2 or newer for the CLI. That is macOS system bash; nothing newer is
  required.
- git, coreutils, sed, awk.
- `jq` is optional for the CLI (there is a sed escaping fallback) and required
  only for `mcp/agentws-mcp`, which also needs bash 4.1 or newer for its
  framing. On macOS you get the full CLI on system bash and need a newer bash
  only if you want the MCP server.

No compiler, no package manager, no Python, no Node. `install.sh` makes two
symlinks.

## Non-goals

These are settled decisions, not a backlog. Please do not open issues asking for
them.

- **No forge API integration.** No pull request creation, no issue reading, no
  status checks, no tokens, no credential storage.
- **No CI/CD orchestration.** No pipeline generation, no release automation, no
  version bumping, no changelog generation.
- **No GUI, TUI, dashboard, watch mode, or progress bars.** `agentws status`
  prints a table and exits.
- **No daemon, server, socket, or port.** The MCP server is a stdio child of the
  client and dies with it. There is no persistent state beyond the lock files.
- **No authentication or authorisation.** Locks are advisory and cooperative;
  the owner field is whatever string the caller supplies. This assumes a single
  trusted user on a single machine. It is not a security control and must not be
  described as one.
- **No distributed or network locking.** No etcd, no Redis, no lease renewal.
  One file created with `noclobber`. The cross-host case is handled by refusing
  to judge, not by coordinating.
- **No build, test, or regression orchestration.** `agentws` does not know what
  a testsuite is.
- **No arbitrary cleanup.** `refresh` resets only verified phantom dirt, and
  `recycle --clean-untracked` removes only reported untracked files after an
  explicit flag. Tracked user changes are never discarded.
- **No plugin registry or provider downloads.** A provider is a file you place
  in `providers/`.
- **No telemetry.**

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - core and provider split, layering rules
- [docs/LOCKING.md](docs/LOCKING.md) - the lock state machine and every uncertain case
- [mcp/README.md](mcp/README.md) - the MCP server, its tools, and client setup
- [CONTRIBUTING.md](CONTRIBUTING.md) - bash 3.2 rules and how to run the tests

## Licence

MIT. See [LICENSE](LICENSE).
