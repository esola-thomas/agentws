---
name: init
description: Guide a developer through setting up an agentws farm for a Git repository, including workspace location, provider, Git remotes, and submodules. Use when they ask to initialize agentws or create their first workspaces.
argument-hint: [repository path]
---

# Set up an agentws workspace

Guide the developer interactively. Explain each choice, ask one question at a
time, and wait for an answer. Do not create directories, clone repositories,
change Git configuration, initialize submodules, or write config until the
developer has reviewed and approved the proposed setup.

## 1. Identify the repository and current setup

Use the supplied repository path, or ask whether to use the current directory.
Inspect it without changing anything:

```bash
pwd -P
git -C "<repo>" rev-parse --show-toplevel
git -C "<repo>" branch --show-current
git -C "<repo>" remote
git -C "<repo>" symbolic-ref --quiet --short refs/remotes/origin/HEAD
```

Do not print or expose remote URLs, since they can contain credentials. If the
repository has no `origin` remote or `origin/<default-branch>` reference, explain
that worktree slots need that reference and ask the developer how they want to
make it available. Respect the Git transport already configured for the repo.
For SSH, HTTPS, a corporate proxy, or a custom Git transport, ask the developer
to configure and verify access themselves; never request or store tokens.

Check whether `agentws` is installed and whether this repository already has an
`.agentws.yml` or an existing farm. Do not overwrite an existing config or use
`--force` as a shortcut. If the CLI is missing, explain the documented install
command from the project README and ask before installing it.

## 2. Choose a workspace layout

Ask how many slots are wanted and where the farm should live. The defaults are
three slots in `<repo>-ws` beside the source repository. Explain that the first
farm becomes the user's default farm.

Ask which provider fits the project:

- `worktree` is the default. Slots share the source checkout's Git object store.
  `agentws init <repo> --slots N --root DIR` writes the config and creates slots
  from the existing checkout. It uses `origin/<default-branch>`.
- `fullclone` creates a separate clone per slot, useful when slots need
  independent untracked files or build trees. `agentws init` always selects
  `worktree`; for `fullclone`, make a config based on `.agentws.yml.example`
  with `provider: fullclone` and `provider_opts.source_repo` set to the
  developer-approved local path or clone URL, then create slots with
  `agentws create <slot>`.
- A project-specific provider needs a reviewed provider file and
  `provider_path`. Do not invent or install a custom provider without the
  developer's approval. Explain that providers may not access the lock
  directory.

For nonstandard Git transport or authentication, keep the source URL and
credentials out of chat and command output. Prefer the existing local checkout
as the source for `worktree`; for `fullclone`, use a credential helper or a
developer-configured remote rather than embedding credentials in the config.

## 3. Review and create the farm

Summarize the repository, provider, slot count, destination, default branch,
submodule plan, and any transport requirements. Ask for explicit approval.

After approval, use `agentws init "<repo>" --slots N --root "<root>"` for the
default worktree setup. For `fullclone` or a custom provider, use the approved
config path and create the listed slots with `agentws create`. Do not run
`agentws init --force`, replace an existing config, or discard existing work.

If `agentws init` reports that `origin/<default-branch>` is missing, stop and
explain the error. Do not fetch, switch branches, or alter remotes without
asking first.

## 4. Set up submodules if requested

Check for a `.gitmodules` file and explain that slots may need each project's
submodules initialized. Ask whether to initialize them, including nested
submodules. Only after approval, run `git -C "<slot-path>"
submodule update --init --recursive` for each created slot. If a submodule
cannot be fetched, preserve the slot and report the failing path; do not change
its URL, branch, or credentials without permission.

## 5. Verify and hand off

Run `agentws status` and, if useful, `agentws doctor`. Confirm the config path,
slot count, and whether submodules initialized successfully. Explain:

- `agentws use <config>` can make this farm the default later.
- `agentws setup claude` separately wires the CLI's MCP server and SessionStart
  hook. The plugin provides skills; it does not install the CLI or MCP server.
- The `/agentws:agentws` skill explains how agents claim and recycle slots.

If any step fails, stop before retrying a mutation and explain what remains to
be done.
