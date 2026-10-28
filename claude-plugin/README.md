# agentws

**Run many AI coding agents on one repo without them overwriting each other.**

Two agents in one checkout is a data-loss event. agentws gives every agent its
own isolated checkout of your repository (a *slot*) and a lock that says who
holds it. Agents claim a free slot, work on their own branch, and hand the slot
back when the pull request merges.

This plugin teaches Claude how to use an agentws slot farm. It contains two
skills and nothing else: no executables, no MCP server, no hooks.

| Skill | What it does |
|---|---|
| `/agentws:init` | Walks you through creating a slot farm for a Git repository: location, slot count, provider, remotes, and submodules. It proposes a setup and waits for your approval before changing anything. |
| `/agentws:agentws` | The slot lifecycle for agents: claim a slot, bootstrap it, branch, work, and recycle it after the pull request merges. |

## Requirements

The skills drive the `agentws` command-line tool, which is installed separately
and is not part of this plugin:

```bash
curl -fsSL https://raw.githubusercontent.com/esola-thomas/agentws/main/install.sh | bash
```

The CLI needs bash, git, and jq, on Linux, macOS, or WSL2. Because the skills
run local shell commands, the plugin is useful where Claude has a shell on your
machine: Claude Code, or a Cowork session running on your computer. In a chat
without a local shell the skills can explain agentws but cannot operate it.

After installing the CLI, `agentws setup claude` optionally registers its MCP
server and a session-start hook that shows the farm. Those come from the CLI,
not from this plugin.

## What the plugin runs, fetches, and sends

- **Runs.** The skills instruct Claude to run `agentws` and `git` commands in
  your local shell, inside the repository and slot farm you point it at. The
  `init` skill inspects the repository read-only first and asks before it
  creates directories, writes config, or initializes submodules.
- **Fetches.** The skills do not fetch or install the CLI. If it is missing,
  the `init` skill points you to the project README; installation is left to
  you. Once installed, the CLI checks `github.com/esola-thomas/agentws` for a
  new release at most once a day; `AGENTWS_NO_AUTO_UPDATE=1` turns that off.
- **Sends.** Nothing goes to the plugin author or to any service the plugin
  operates, because there is none. The only network traffic is git: fetches
  from and pushes to the remotes already configured in your own repository,
  using your existing git credentials. The plugin never asks for, reads, or
  stores tokens.
- **Stores.** Lock files (owner label, process id, task description) and farm
  config stay on your local disk. No telemetry, no account, no analytics.

## Learn more

- [Project README](https://github.com/esola-thomas/agentws#readme): install, commands, connected tools
- [AGENTS.md](https://github.com/esola-thomas/agentws/blob/main/AGENTS.md): the contract agents follow
- [Reference](https://github.com/esola-thomas/agentws/blob/main/docs/REFERENCE.md): configuration, platforms, non-goals
- [Issues](https://github.com/esola-thomas/agentws/issues): bugs and questions

MIT licensed.
