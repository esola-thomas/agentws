# Changelog

All notable changes to this project are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `claim --slot N` claims one specific slot with claim's refusals and output;
  `workspace_claim` takes `slot`.
- `lock --takeover N [reason]` re-binds a lock you already own to the current
  `AGENTWS_PID` (and a new reason, if given) in one atomic rewrite, replacing
  `unlock N; lock N` after a session restart; `workspace_lock` takes
  `takeover`. It never takes another owner's lock.
- `--session ID` is an alias of `--owner ID`.
- `checkpoint set|show|clear [slot]` records where a slot's task stands
  (`--phase`, `--pr`, `--next`, `--note`, `--body-file`) in
  `<lock_dir>/<slot>.checkpoint`, beside the lock and outside the checkout.
  The slot defaults to the one holding the current directory, so a worker
  that did not claim its slot can still checkpoint it. Releasing the lock
  deletes it; a takeover by a different owner keeps it as the previous
  checkpoint; the last 50 calls are kept in `<slot>.checkpoint.log`.
  `status` shows `phase · PR`, `status --json` has a `checkpoint` object, and
  MCP has `workspace_checkpoint`. No lock or claim decision reads it.
- Every slot has a label, `<top>_<slot>` (`label` in JSON,
  `AGENTWS_LABEL` from `claim --print-env`), for naming databases,
  containers, temp dirs, and ports outside the checkout.
- Every claim prints a notice (label, port base, provider env and lines, how
  to checkpoint) to stderr, returns it as `notice` in `claim --json`, and
  stores it as `<lock_dir>/<slot>.notice`. Inside a locked slot,
  `agentws hook session-start` prints that notice and the checkpoint instead
  of the farm table, so a worker that never claimed sees them.
- Orphan state: a slot whose lock is stale by the existing ladder and whose
  task is unfinished (branch neither merged nor gone, or real changes; see
  REFERENCE.md for the exact rule) shows `ORPHANED (<reason>): <phase> ·
  <next>` in `status`, `orphaned` and
  `orphan_reason` in `status --json`, and a `tend` problem. Nothing is
  released or taken over. A lock without `owner_pid` shows its checkpoint
  age in `status`, as information only.
- `agentws hook pre-tool-use`, a Claude Code PreToolUse guard that
  `agentws setup` installs next to the session-start hook. For a session
  inside a slot it denies writes to another slot or the reference slot, and
  `git checkout <default-branch>` and `git reset --hard`. Sessions outside
  every slot are not guarded; no farm or no `jq` allows silently.
- Provider hooks `provider_slot_claimed` (run once per claim; a failure is a
  claim warning and never releases the lock) and `provider_claim_notice`
  (extra notice lines). Both have defaults, so the provider API stays 1.
- `doctor` fails `worktree-link` when a worktree's admin dir points back at a
  missing path, which the next `git worktree prune` would orphan, and prints
  the `git worktree repair` command.

### Changed

- `provider_claim_env` is evaluated on every claim, not only `--print-env`,
  and its `export K=V` lines are returned as the `claim_env` object of
  `claim --json`.
- Unknown options are refused with exit 2 (`EUSAGE`) instead of being kept as
  arguments, where `claim` made them the lock reason. `--` ends options, so a
  reason may start with a dash. The MCP server always passes `--` before free
  text.
- `tend` reaps by default (`tend_reap: true`), and only a provably finished
  slot: stale or no lock, branch merged into or gone from origin, no tracked or
  untracked change, and every commit on origin or its content already in
  `origin/<default>`, so squash-merged branches qualify. A stale lock that
  fails any of these is left byte-for-byte as it was, and the tend problem
  names the reason.
- `recycle` takes over another owner's stale lock under the same rule;
  `workspace_recycle` passes stale locks to it instead of refusing them.
- When `recycle` cannot delete the task branch because another checkout has it,
  it names that checkout (and its slot) and the command that frees it.

## [0.0.6] - 2026-10-28

### Changed

- The Claude plugin's listing icon is now a vector `icon.svg` instead of a
  PNG, so the plugin ships no binary files for the directory to hold for review.

## [0.0.5] - 2026-10-28

### Changed

- Claude skills direct users to install the CLI separately instead of running
  the remote installer from a skill.

## [0.0.4] - 2026-10-13

### Added

- The Claude plugin is ready for Anthropic's plugin directory: its folder now
  carries its own README (what the skills run, fetch, send, and store), the MIT
  license, and a listing icon, and the manifest declares `license`,
  `repository`, `keywords`, `icon`, and `supportUrl`.

### Changed

- `scripts/check-release.sh` fails when the plugin manifest or the marketplace
  entry version differs from `VERSION`.
- The `agentws` skill links the contract by URL instead of a path outside the
  plugin, and tells the agent what to do when the CLI is not installed.

## [0.0.3] - 2026-10-10

### Added

- `agentws tend` for safe farm maintenance, with `--check`, `--dry-run`,
  machine-readable results, and opt-in reap, environment repair, and update checks.
  Session-start hooks show maintenance notices without running maintenance.
- `agentws tend schedule install|uninstall|status` registers one user job per
  canonical config path: systemd user timers, cron fallback, or launchd on
  macOS. Arbitrary positive minute intervals, jitter, and independent farm
  schedules are supported. Existing unrelated jobs are preserved. (#34)

### Changed

- Automatic update checks are suppressed for `tend` and `--check`. Maintenance
  update checks require `tend_self_update: true`.

## [0.0.2] - 2026-10-06

### Added

- `agentws reap [--dry-run] [--yes] [--json]` and the `workspace_reap` MCP tool
  recycle every slot whose branch is gone upstream or merged into
  `origin/<default>`, has a stale or no lock, and is clean or only lagging in
  submodules. Active locks, the reference and excluded slots, and slots with
  real uncommitted changes are never touched; the last are listed. `status`
  notes such a slot with `merged/gone: run agentws recycle N`, and `claim` and
  `free` name the reapable slots when none is claimable. (#24)

### Changed

- Idle slots are parked detached at `origin/<default>` instead of sharing the
  default branch. `create` (worktree and fullclone), `recycle`, and `refresh`
  leave a slot there, and `claim`, `free`, and `status` call a slot claimable
  only when it is clean and detached at a commit `origin/<default>` contains.
  With no shared ref, recycling or refreshing one slot no longer re-creates
  phantom dirt in its siblings. The worktree provider no longer uses
  `worktree add --force` and needs `origin/<default>` in the source repo.
  `recycle --json` reports `parked_at` in place of `branch`. After updating,
  run `agentws refresh` once: it parks idle slots still on the default branch.
  (#21)
- `refresh` also moves a clean parked slot to the current `origin/<default>`,
  and refuses a detached slot with commits `origin/<default>` lacks.
  `auto_refresh` runs it on every unlocked work slot that is not claimable.
- `sync` parks the reference slot detached at `origin/<default>` instead of
  fast-forwarding the default branch, so it never needs a branch another
  worktree has checked out, and heals its phantom dirt first. It exits `EGIT`
  (8) when a fetch fails, the reference is dirty (the dirty paths are
  printed), or the reference could not be parked. It never moves a work slot.
  (#22)
- `status`, `free`, and the slot JSON show a detached HEAD as
  `detached@<short-sha>` instead of `?` or an empty string. A detached slot is
  measured against `origin/<default>` as its upstream, so parked slots no
  longer warn `no_upstream`.

### Fixed

- `doctor` passes a slot with a detached HEAD instead of reporting
  `HEAD unresolvable`, and warns (`shared_branch`) when a slot's branch is
  checked out in more than one worktree.
- `doctor` printed `upstream` and `worktree` twice, once from the core and
  once from the provider. The bundled providers now report only their own
  checks. A reference slot that is neither parked nor on the default branch
  is a `branch` WARN. (#22)
- `agentws prune`: `--dry-run` says `would delete` instead of `deleted`; each
  repo is scanned once instead of once per slot; any branch checked out in any
  worktree is never a candidate. `--json` records gain `would_delete`. (#23)

## [0.0.1] - 2026-10-01

### Added

- `agentws submodules`: in a claimed slot, find submodules whose tracking
  branch has moved ahead of the recorded pointer, ask per submodule (`--yes`
  for all), show the staged gitlink diff, ask before pushing (`--push` skips
  that), then commit only those gitlinks, `git push`, open the PR with `gh`
  when installed, and recycle the slot. `--dry-run`, `--base`, `--json`.
  (#12)
- `--json` envelopes report an interrupt as `EINTR` (exit 130) instead of
  printing nothing: the command's own cleanup runs first.

### Fixed

- `agentws update` failed for good once a release tag had moved on the remote
  (`would clobber existing tag`). Tags are now force-fetched; the move is
  still taken only when it fast-forwards. Re-running the install one-liner
  heals an install that still has the old update code.

## [0.0.0] - 2026-10-01

First release. Extracted from an internal tool in daily use coordinating agents
across several workspaces.

### Added

- **Install and updates.** `curl -fsSL .../install.sh | bash` clones a managed
  install into `~/.local/share/agentws`, links the CLI, and wires every detected
  AI harness. The install updates itself: every command starts a detached,
  once-a-day check that fast-forwards to the newest `v*` tag (or `origin/main`
  with `AGENTWS_UPDATE_CHANNEL=main`), never downgrades, and refuses a dirty
  install. `agentws update` runs it now; `AGENTWS_NO_AUTO_UPDATE=1` turns it
  off. Running `install.sh` from a checkout links that checkout and never
  updates it.
- **Harness wiring.** `agentws setup [harness...]` registers the MCP server and
  links the skill for Claude Code, Codex CLI, Copilot CLI, Cursor, and Gemini
  CLI, plus a Claude Code SessionStart hook (`agentws hook session-start`).
  `--check` and `--remove`. Skills go to `~/.claude/skills` and the cross-tool
  `~/.agents/skills`. Harnesses are detected by their command on PATH. The MCP
  server is registered as `<absolute bash 4.1+> <server>`, so a harness started
  with a minimal PATH (a macOS GUI app) cannot fall back to bash 3.2; with no
  such bash, MCP registration is skipped with instructions, and `--check` marks
  an entry that cannot start as `mcp:stale`. An existing `AGENTWS_OWNER_PREFIX`
  is kept, so locks taken over MCP are never orphaned.
- **One-step farms.** `agentws init [repo]` writes `<repo>-ws/.agentws.yml`
  beside the checkout, creates the slots as worktrees of it (`--slots N`,
  default 3; `--root DIR`), and makes it the default farm
  (`~/.config/agentws/default.yml`, switchable with `agentws use`), so an MCP
  server or hook finds it from any directory.
- **CLI.** `bin/agentws`, pure bash 3.2: `status`, `free`, `claim`, `lock`,
  `unlock`, `locks`, `sync`, `prune`, `refresh`, `recycle`/`done`, `create`,
  `destroy`, `doctor`, `config`, `version`. `--json` on every command emits one
  envelope line on stdout with stable error and exit codes; narrative goes to
  stderr.
- **Locking.** Advisory lock files created with `noclobber`, atomic against
  concurrent acquirers, in a registry outside the workspaces. A conservative
  liveness ladder: every uncertain case resolves to alive, and pid reuse is
  detected on Linux through process start time. Locks record `format=1`; a lock
  in a newer or unreadable format is treated as held and alive and refused with
  `ELOCKFORMAT` (exit 9), so an older install never releases a newer one's
  lock. See `docs/LOCKING.md`.
- **Slot lifecycle.** Environment-aware claims (`--require-env`,
  `create --with-env`, `doctor --fix-env`), provider bootstrap hints, safe
  phantom-dirty healing (`refresh`, opt-in `auto_refresh`), per-lock TTLs,
  structured task metadata, and opt-in finished-slot auto-release. `recycle`
  resyncs submodules, verifies the slot is claimable before releasing, and
  keeps the lock if it is not.
- **Providers.** A twelve-function contract with core defaults; `worktree`
  (default) and `fullclone`; `provider_path` for private, project-specific
  providers. Providers may not touch the lock directory.
- **Configuration.** A strict-subset YAML parser: unrecognised syntax is a
  `file:line` error, never a silently dropped key. `root` and `lock_dir` are
  canonicalised, so symlinked paths cannot produce two lock files.
- **MCP server.** `mcp/agentws-mcp`, bash and jq, eleven `workspace_*` tools,
  each one `exec` of `agentws --json`. No force parameter, per-session lock
  owners, lifecycle `instructions`, protocol version negotiation (2025-06-18,
  2025-03-26, 2024-11-05).
- **Agent docs.** `AGENTS.md`, the harness-neutral contract, and the
  `skills/agentws` skill with the same ritual plus headless-worker rules.
- **Tests and CI.** bats suite (liveness matrix over a faked `/proc`, a 20-way
  acquisition race, slot lifecycle, lock format, onboarding and self-update),
  shellcheck, and `scripts/check-release.sh` (VERSION, CHANGELOG, and tag
  agree) run on every pull request. Pushing a `v*` tag runs the check and
  publishes the GitHub release from this file.

### Known limitations

- macOS, Git Bash, and MSYS2 have no `/proc`, so locks expire by TTL only.
  `ttl_hours: 4` is recommended there. `doctor` and `locks --json`
  (`"liveness_supported": false`) report it.
- Git Bash and MSYS2 are best-effort; `noclobber` atomicity on NTFS is
  unverified. Windows is supported through WSL2 only.
- The MCP server needs bash 4.1 or newer and `jq`; the CLI needs neither.
  bash 3.2 compatibility of the CLI is checked by review, not yet by CI.
- `agentws setup` has been run against Claude Code and Codex CLI. The Copilot
  CLI, Cursor, and Gemini CLI entries follow their documented formats and have
  not been run here.

[Unreleased]: https://github.com/esola-thomas/agentws/compare/v0.0.1...HEAD
[0.0.1]: https://github.com/esola-thomas/agentws/releases/tag/v0.0.1
[0.0.0]: https://github.com/esola-thomas/agentws/releases/tag/v0.0.0
