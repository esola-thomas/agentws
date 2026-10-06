# Changelog

All notable changes to this project are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
