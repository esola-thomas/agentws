# Changelog

All notable changes to this project are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-08-10

First public release. Extracted from an internal tool that had been in daily use
coordinating agents across five workspaces.

### Added

- `bin/agentws`, a pure bash CLI with the commands `status`, `free`, `claim`,
  `lock`, `unlock`, `locks`, `sync`, `prune`, `create`, `destroy`, `doctor`,
  `config`, and `init`.
- Advisory file locking with a conservative liveness ladder. Every uncertain
  case resolves to alive: cross-host locks, locks with no recorded session pid,
  and platforms without `/proc` are never judged dead. Pid reuse is detected on
  Linux via process start time. Documented in `docs/LOCKING.md`.
- Lock acquisition through `set -o noclobber` in a subshell, atomic against
  concurrent acquirers on a local filesystem.
- A central lock registry outside the workspaces, so cleaning a workspace cannot
  destroy a lock.
- `--json` on every command, emitting exactly one envelope line on stdout with
  stable error codes and exit codes. Human narrative always goes to stderr.
- Provider contract with eight hooks and core-supplied defaults. Providers may
  not touch the lock directory.
- Providers: `worktree` (default) and `fullclone`.
- Strict-subset YAML config parser. Unrecognised syntax is a `file:line` error,
  never a silently dropped key. `agentws config --json` prints exactly what the
  parser saw.
- Path canonicalisation with `pwd -P` on `root` and `lock_dir`, so two symlinked
  paths to one checkout cannot produce two lock files.
- `mcp/agentws-mcp`, an optional JSON-RPC stdio server in bash and jq exposing
  six tools: `workspace_status`, `workspace_claim`, `workspace_lock`,
  `workspace_release`, `workspace_sync`, `workspace_doctor`. It never opens a
  lock file; every action is one `exec` of `agentws --json`.
- Drop-in MCP config fragments for Claude Code and GitHub Copilot CLI in
  `mcp/claude_code.example.json` and `mcp/copilot.example.json`.
- `install.sh`, two symlinks with `--check` and `--uninstall` modes. No package
  manager, no build step.
- bats test suite: the six-case liveness matrix over a faked `/proc`, a 20-way
  concurrent acquisition race, provider contract conformance, and JSON shape
  checks including the empty-lock-directory case.
- Documentation: `README.md`, `docs/ARCHITECTURE.md`, `docs/LOCKING.md`,
  `docs/PROVIDERS.md`, `CONTRIBUTING.md`.

### Known limitations

- macOS, Git Bash, and MSYS2 have no `/proc`, so locks expire by TTL only.
  Process death is never detected there. `ttl_hours: 4` is recommended on those
  platforms. Reported by `doctor`, by `locks --json` as
  `"liveness_supported": false`, and by a daily warning from `lock`.
- Git Bash and MSYS2 are best-effort. `noclobber` atomicity on NTFS is
  unverified.
- Windows is not supported natively. Use WSL2, which is fully featured.
- `mcp/agentws-mcp` requires bash 4.1 or newer and `jq`. The CLI needs neither.
  macOS users get the full CLI on system bash and need a newer bash only for the
  MCP server.
- Claude Code and GitHub Copilot CLI are the only MCP clients that have been run
  against the server. Codex, Cursor, Aider, and others are untested. The plain
  CLI with `--json` is the fallback for any tool.

[0.1.0]: https://example.invalid/agentws/releases/tag/v0.1.0
