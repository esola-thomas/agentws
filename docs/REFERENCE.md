# agentws reference

## Commands

| Command | What it does |
|---|---|
| `init [repo] [--slots N] [--root DIR]` | Create a farm for a checkout: `<repo>-ws/.agentws.yml` plus N worktree slots. The first farm becomes the default. |
| `setup [harness...]` | Wire AI tools to this install. `--check`, `--remove`. Harnesses: `claude codex copilot cursor gemini all`. With no names, every tool whose command is on PATH (Cursor: `cursor`, `cursor-agent`, or a `~/.cursor` dir). An existing `AGENTWS_OWNER_PREFIX` on the agentws MCP entry is kept. `--check` shows `mcp:stale` for an entry that needs `agentws setup` again. |
| `use [config]` | Make a farm the default, so agents find it from any directory. |
| `update` | Update a managed install now. `--check` only reports. |
| `version` | Installed version. |
| `status` | Every slot: branch, dirty, lock, claimable, environment. |
| `free` | Idle slots. |
| `claim "reason"` | Lock the first claimable slot. `--print-env` for `eval`. |
| `lock <slot> "reason"` / `unlock <slot>` | Lock or release a specific slot. |
| `locks` | All locks with age and remaining TTL. |
| `recycle <slot>` / `done <slot>` | After merge: fetch, reset to `origin/<default>`, delete the task branch, release. |
| `refresh [slot...]` | Heal phantom-dirty idle slots. |
| `sync [slot...]` / `prune [slot...]` | Fetch; delete merged local branches. |
| `create <slot>` / `destroy <slot>` | Make or remove a slot through the provider. |
| `doctor [slot...]` | Health checks. `--fix-env` provisions environments. |
| `submodules` | Update submodule pointers in a claimed slot, push, and open a PR. See below. |
| `config` | The configuration exactly as the parser read it. |

Every command takes `--json` and prints exactly one envelope line on stdout;
human narrative goes to stderr, so piping to `jq` is always safe:

```json
{"ok":true,"command":"claim","data":{"slot":"1","path":"/home/u/code/myrepo-ws/1_myrepo"},"error":null}
```

The envelope is the stable interface. MCP is a convenience on top of it.

## Lock ownership

Export `AGENTWS_PID=$$` (a shell that outlives the task) and
`AGENTWS_OWNER="<harness>:<task>"` before claiming. The lock then goes stale the
moment that process dies, instead of waiting out its TTL. `--force` exists on
the CLI only, for a human who has confirmed an agent is gone.

## Configuration

Discovery order, first hit wins:

1. `--config PATH` or `$AGENTWS_CONFIG` (absolute)
2. `.agentws.yml` in the current directory or a parent, up to `$HOME`
3. `$AGENTWS_ROOT/.agentws.yml`
4. The default farm, `~/.config/agentws/default.yml` (a symlink set by `init` or `use`)

Every key is documented in [.agentws.yml.example](../.agentws.yml.example). The
parser accepts a strict subset of YAML and refuses anything else with a
`file:line` error; a key is never silently dropped.

## Slot lifecycle

`status` and `free` report `env: ready | missing | stale`. `claim` prefers a
ready environment; `claim --require-env` refuses to fall back. Providers can
return a bootstrap hint with the claimed slot.

Worktree slots become `phantom-dirty` when another worktree advances the shared
default branch ref. `refresh` heals only a tree whose index matches an ancestor
of `origin/<default_branch>` with no extra changes; all other dirt is refused.
`auto_refresh: true` runs the same proof at claim time.

`recycle` refuses untracked files unless `--clean-untracked` is explicit, and
never discards tracked changes. Claims can carry `--task-id`, `--branch`,
`--agent`, and a `--ttl` capped by `ttl_hours`. `auto_release: true` lets
`doctor` release a locked slot that stays clean on the default branch for
`auto_release_minutes`.

## Providers

A provider decides what a slot physically is. It is one `.sh` file
implementing the contract in `providers/_contract.sh`, and it may never touch
the lock directory.

| Provider | A slot is | Use it when |
|---|---|---|
| `worktree` | `git worktree add` off one source repo | Default. Fast, one object store. |
| `fullclone` | An independent `git clone` | Slots need separate untracked state or build trees. |

A project-specific provider can live beside its config: set
`provider_path: "{root}/.agentws/providers"`. See
[ARCHITECTURE.md](ARCHITECTURE.md) for the hooks.

## Submodule pointer updates

`agentws submodules` claims a slot, branches `agentws/submodules-<time>` off
`origin/<base>`, and checks each direct submodule's tracking branch: the
`.gitmodules` `branch` (`.` means the base branch), else the submodule
remote's default branch. A candidate is a newer commit that fast-forwards the
recorded pointer; anything else (fetch error, unknown branch, diverged
history) is reported and left alone. For each candidate it shows the commits
and asks; then it shows the exact staged gitlink diff and asks once more before
committing only those gitlinks, pushing with `git push`, and opening the PR
with `gh` if it is installed. The slot is recycled at the end either way.

| Option | Effect |
|---|---|
| `--yes` | Take every candidate without asking per submodule. Still asks before pushing. |
| `--push` | Skip the question before pushing, for automation. |
| `--dry-run` | Report candidates; change, commit, and push nothing. |
| `--base BRANCH` | Branch from and target `BRANCH` instead of `default_branch`. |
| `--json` | One envelope with candidates, errors, branch, and PR URL. |

Answers are read from stdin, so `printf 'y\nn\ny\n' | agentws submodules`
scripts it; end of input means no. Nested submodules are checked out, but only
the managed repository's own gitlinks change: a nested pointer belongs to its
parent submodule's repository. `AGENTWS_GH` names a different `gh` binary.

## Updates

`install.sh` run through `curl | bash` clones into `~/.local/share/agentws` and
marks it managed. A managed install checks for a new version at most once a day,
in a detached background process, and only fast-forwards: the target must
descend from the current commit, so it never downgrades. Files are replaced
under running processes safely, because git writes new inodes.

| Variable | Effect |
|---|---|
| `AGENTWS_NO_AUTO_UPDATE=1` | No background checks |
| `AGENTWS_UPDATE_CHANNEL` | `stable` (newest `v*` tag, default) or `main` |
| `AGENTWS_UPDATE_INTERVAL_HOURS` | Check interval, default 24 |

A checkout you cloned and ran `./install.sh` from is a dev install: it is linked
as is and never updated automatically. The background log is
`~/.local/state/agentws/update.log`.

Processes from different versions can share one lock directory. A lock written
in a lock format the reading process does not support is treated as held and
alive, and every command that would take, release, or rewrite it refuses with
`ELOCKFORMAT` (exit 9) and the hint `agentws update`. See
[LOCKING.md](LOCKING.md#lock-format-version).

## Platform support

| Platform | Status | Lock liveness |
|---|---|---|
| Linux | Supported | Full, including pid-reuse detection through `/proc` |
| WSL2 | Supported | Full |
| macOS | Supported | TTL only (no `/proc`). Use `ttl_hours: 4`. |
| Git Bash / MSYS2 | Best effort | TTL only |
| Windows native | Not supported | Use WSL2 |

TTL-only is safe, not unsafe: a live lock is never freed, a dead one just waits
out its TTL. `doctor` and `locks --json` (`"liveness_supported": false`) say so.
A lock recorded on another host is always treated as alive.

The CLI runs on bash 3.2. The MCP server needs bash 4.1 or newer and `jq`
(`brew install bash jq` on macOS). `agentws setup` checks `bash` on PATH, then
`/opt/homebrew/bin/bash`, then `/usr/local/bin/bash`, and registers the server
as `<absolute path of the first bash 4.1+> <server>`, so tools launched with a
minimal PATH still get it. When no candidate is new enough, setup skips MCP
for every tool, still links the skill and the Claude hook, and
`setup --check` shows `mcp:no`.

## Non-goals

Settled decisions, not a backlog:

- No forge API integration: agentws calls no forge API and holds no tokens or
  credentials. The one hand-off is `submodules`, which runs `gh pr create`
  when `gh` is installed; without it, the pushed branch is all it produces.
- No CI/CD, build, or test orchestration.
- No GUI, TUI, dashboard, daemon, or network port.
- No authentication. Locks are advisory and assume one trusted user per machine.
- No distributed locking. Cross-host locks are never judged dead.
- No arbitrary cleanup. Tracked changes are never discarded.
- No telemetry.
