# agentws

**Run many AI coding agents on one repo without them overwriting each other.**

Two agents in one checkout is a data-loss event. `agentws` gives every agent its
own isolated checkout of your repo (a *slot*) and a lock that says who holds it.
Agents claim a free slot, work on their own branch, and hand the slot back when
the PR merges. It works with Claude Code, Codex, GitHub Copilot CLI, Cursor, and
Gemini CLI, and with anything else that can run a shell command.

- **Safe by default.** A lock is only freed when its owner is provably dead.
  Agents cannot force their way into a busy slot.
- **Nothing to run.** One bash script and a lock file per slot. No daemon, no
  server, no account, no telemetry.
- **Any git host.** Plain git only: GitHub, GitLab, Azure DevOps, Bitbucket, or
  a bare repo.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/esola-thomas/agentws/main/install.sh | bash
```

This installs the CLI into `~/.local/bin` and connects every AI tool it finds:
MCP server, agent skill, and (for Claude Code) a session-start hook that shows
the farm. The install updates itself to each new release in the background, at
most once a day.

Requirements: bash, git, and jq. Linux, macOS, or WSL2.

## Use

```bash
cd ~/code/myrepo
agentws init          # creates ~/code/myrepo-ws with 3 slots
agentws status        # who holds what
agentws sync          # fetch everywhere; park the reference slot at origin/<default>
```

`sync` updates remote-tracking refs and the reference slot only. It never
moves a work slot or your branch; `agentws refresh` advances idle slots.

That is the whole setup. Start your agents as usual. They see the farm, claim a
slot, work in it, and recycle it. You never assign directories by hand.

What an agent does, whether through MCP or a shell:

```bash
eval "$(agentws claim 'fix the parser' --print-env)"   # lock a free slot
cd "$AGENTWS_WS" && git checkout -b fix/parser origin/main
# ... work, commit, push, open a PR ...
agentws recycle "$AGENTWS_SLOT"                         # after merge: reset and release
```

## Connected tools

| Tool | What `agentws setup` adds |
|---|---|
| Claude Code | MCP server (user scope), `/agentws` skill, SessionStart hook |
| Codex CLI | MCP server in `~/.codex/config.toml`, skill in `~/.agents/skills` |
| GitHub Copilot CLI | MCP server in `~/.copilot/mcp-config.json`, skill |
| Cursor | MCP server in `~/.cursor/mcp.json`, skill |
| Gemini CLI | MCP server in `~/.gemini/settings.json`, skill |
| Anything else | Reads [AGENTS.md](AGENTS.md) and calls `agentws --json` |

Installed a new tool later? Run `agentws setup`. Check the wiring with
`agentws setup --check`, and undo it with `agentws setup --remove`.

## Updates

`agentws update` updates now; `agentws version` shows what you run.
`AGENTWS_NO_AUTO_UPDATE=1` turns background updates off, and
`AGENTWS_UPDATE_CHANNEL=main` follows `main` instead of releases. Updates only
fast-forward and never touch a checkout you cloned yourself.

## Learn more

- [AGENTS.md](AGENTS.md): the contract agents follow
- [docs/REFERENCE.md](docs/REFERENCE.md): commands, configuration, platforms, non-goals
- [docs/LOCKING.md](docs/LOCKING.md): how a lock is judged dead
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): core, providers, MCP server
- [CONTRIBUTING.md](CONTRIBUTING.md)

MIT licensed.
