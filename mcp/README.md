# agentws MCP server

`agentws-mcp` is a JSON-RPC 2.0 stdio server that exposes six agentws
operations to an MCP client. It contains no workspace logic. Every tool shells
out to `agentws <cmd> --json`, the same interface a human uses at the terminal,
and returns that envelope unchanged. If the server and the CLI ever disagree,
the server is wrong.

## Requirements

- bash 4.1 or newer (the framing reader uses `read -r -N`). The agentws CLI
  itself still runs on bash 3.2; only this server needs 4.1. On a 3.2-only host,
  skip MCP and call `agentws --json` from a shell tool instead.
- `jq` on PATH.
- `agentws` on PATH, or `AGENTWS_BIN` set to its absolute path.

## Environment

| Variable | Meaning |
|---|---|
| `AGENTWS_BIN` | Absolute path to the agentws CLI. Defaults to `../bin/agentws` next to this script, then PATH. |
| `AGENTWS_CONFIG` | Path to the `.agentws.yml` to serve. |
| `AGENTWS_OWNER_PREFIX` | Prefix for lock owner strings. Default `mcp`. Owners are `<prefix>:<session>`. |

## Tools

Six tools, no more. Each schema is paid for in the context of every session of
every user, so anything not needed mid-task stays CLI-only.

| Tool | Required arguments |
|---|---|
| `workspace_status` | `session` |
| `workspace_claim` | `session`, `reason` (optional `session_pid`) |
| `workspace_lock` | `session`, `slot`, `reason` (optional `session_pid`) |
| `workspace_release` | `session`, `slot` |
| `workspace_sync` | `session` (optional `slot`) |
| `workspace_doctor` | `session` (optional `slot`) |

Each returns one text content block holding the exact agentws envelope:

```json
{"ok":true,"command":"claim","data":{"slot":"1","path":"/ws/1_demo", ...},"error":null}
```

`isError` is true whenever the envelope says `ok:false`.

### `session` is required everywhere

One server process can serve several agent sessions. Without a caller-supplied
identity they would all share one lock owner string, and session B's release
would silently free session A's lock. So every call carries a `session` string,
the lock owner is `<prefix>:<session>`, and `workspace_release` re-reads the
lock and refuses with `not_owner` when the recorded owner is not this session's.
Use one stable value for the whole session.

### `session_pid` is optional and rarely needed

The server never records its own pid as the lock's `owner_pid`. It clears
`AGENTWS_PID` for every child invocation. If it did not, a server restart would
make every live lock read as process-dead and become takeover-able, and a
surviving server would make a dead agent's lock look alive.

The default is therefore TTL-only expiry. A caller that has a genuinely
long-lived process of its own may pass its pid as `session_pid`, and the lock
will then also expire the moment that process dies. Passing the pid of a shell
spawned for a single command is worse than passing nothing.

### There is no force

No tool takes a force flag, and a `busy` result is never retried. Taking over
another agent's lock stays a human action at the CLI (`agentws unlock --force`).
A `busy` answer is final; pick another slot or wait.

### Exit trap

On shutdown the server releases locks it recorded as taken by its sessions.
This is an optimisation, not a correctness dependency: a lock that outlives the
trap is still correct, it just waits out its TTL.

## Wiring

### Claude Code

Copy `claude_code.example.json` into `~/.claude.json`, or into `.mcp.json` at a
project root for a project-scoped server. Edit the three paths — MCP clients do
not expand `$HOME`, so write them out in full.

```bash
claude mcp list        # expect: agentws  connected
```

Smoke test: have the agent call `workspace_status`, then run
`agentws status --json | jq .` in a terminal. They must agree field for field,
because they are the same exec.

### Copilot CLI

Copy `copilot.example.json` into the Copilot CLI MCP config. Same server, same
schemas. Confirm exactly six tools appear in the client's tool list.

### Other clients

Codex CLI, Cursor, Aider, Windsurf, Continue, and Zed are untested here. Their
config schema and stdio support are unverified, so no fragment is shipped for
them.

## Fallback: no MCP required

Nothing in agentws is reachable only through MCP. Any tool that can run a shell
command uses the CLI directly:

```bash
agentws status --json
agentws claim --json "fp legality migration"
eval "$(agentws claim --print-env 'fp legality migration')"
agentws release 2 --json
```

stdout under `--json` is exactly one line of valid JSON; narrative goes to
stderr.

## Manual smoke test

```bash
printf 'Content-Length: 72\r\n\r\n{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | ./agentws-mcp
```

The server also accepts bare line-delimited JSON when no `Content-Length`
header is present, and replies in whichever framing the peer used.
