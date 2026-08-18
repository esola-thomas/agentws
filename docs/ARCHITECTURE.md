# Architecture

## One direction of dependency

```
  MCP client (Claude Code / Copilot CLI)
        |  JSON-RPC over stdio
        v
  mcp/agentws-mcp        framing, schemas, owner scoping.
        |                NEVER opens a lock file, /proc, or git.
        |  exec: agentws --json --owner "$SESSION_OWNER" <cmd>
        v
  bin/agentws            locks, git, slot policy. The stable ABI.
        |  source
        v
  providers/{worktree,fullclone}.sh
                         may NOT read or write $AGENTWS_LOCK_DIR.
```

Nothing points back up. The MCP server is a client of the CLI, exactly like a
human at a terminal, and has no privileged path. Providers are called by the
core and never call it back.

There is exactly one place that acquires a lock, one place that decides whether
a lock is dead, and one place that builds a slot's JSON representation. Every
consumer goes through those. This is why `status` and `free` can never disagree
about whether a slot is claimable: they call the same `slot_claimable`.

## Layout

| Path | Responsibility |
|---|---|
| `bin/agentws` | Argument parsing and dispatch. A `case`, not a table. |
| `lib/core.sh` | Colour, JSON escaping, `run`/`confirm`/`die`. `jq` with a sed fallback, so the core has no hard dependency. |
| `lib/config.sh` | The single config parser. Strict-subset YAML to `AGENTWS_*` and `AGENTWS_P_*`. Loud on unrecognised syntax. |
| `lib/lock.sh` | The lock ladder. See below and [LOCKING.md](LOCKING.md). |
| `lib/slots.sh` | Slot naming, enumeration, role assignment, and the shared per-slot JSON object. |
| `lib/provider.sh` | Loads contract defaults, then the chosen provider over them, then asserts `provider_api_version` is `1`. |
| `lib/envelope.sh` | One JSON line on stdout under `--json`; human narrative always to stderr. Maps error codes to stable exit codes. |
| `lib/commands.sh` | The command implementations. |
| `providers/*.sh` | What a slot physically is. |
| `mcp/agentws-mcp` | Optional JSON-RPC stdio server, bash plus jq. |

## Core versus provider

The split is: **the core owns policy and safety, the provider owns materialisation.**

The core decides which slot is next, whether a slot is claimable, who holds a
lock, whether that lock is dead, and what the JSON looks like. None of that
varies by project.

The provider decides what a slot is made of: a `git worktree add`, a
`git clone`, or a clone plus a project-specific bootstrap step. That is the only
thing that varies.

### The provider contract

Seven functions. `providers/_contract.sh` supplies a default for each, so a
provider only implements what it actually changes.

| Hook | Purpose | Default |
|---|---|---|
| `provider_api_version` | Must print `1`. Asserted at load. | `1` |
| `provider_slot_path <slot>` | Absolute path of a slot. | `$AGENTWS_ROOT/$(slot_name)` |
| `provider_slot_exists <slot>` | Does the slot exist? | `.git` present at the slot path |
| `provider_slot_create <slot> <path>` | Materialise a slot. | Dies with a clear message |
| `provider_slot_destroy <slot> <path>` | Remove a slot. Core has already checked the lock. | Dies with a clear message |
| `provider_slot_doctor <slot> <path>` | Extra health checks. | Prints one OK line |
| `provider_commands` | Space-separated extra subcommand names. | Empty |
| `provider_claim_env <slot> <path>` | Extra shell assignments for `claim --print-env`. | No-op |

`provider_slot_exists` is a hook rather than a core `-d "$d/.git"` test because
not every provider materialises a `.git` at all. A worktree writes a `.git`
*file*, not a directory, and the default reflects that with `-e`.

Extra subcommands are registered as a space-separated string parsed by a `case`,
not by an associative array. bash 3.2 has no associative arrays and macOS ships
bash 3.2.

### The rule providers must not break

**A provider may not read or write `$AGENTWS_LOCK_DIR`.** Locking is core-only.
If a provider could take or release a lock, there would be more than one place
that decides safety, and the guarantee in LOCKING.md would be unverifiable. This
is a review rule, and it is the reason the lock directory lives outside the
workspaces rather than inside each slot.

## The lock ladder, in brief

Full detail in [LOCKING.md](LOCKING.md). The shape of it:

`lock_owner_alive` answers "is the process that took this lock still running?"
and its contract is asymmetric on purpose.

- **Exit 0 means alive, or unknowable.**
- **Exit 1 means definitively dead.**

Every uncertain case returns 0. A wrong "alive" costs at most `ttl_hours` of
waiting. A wrong "dead" puts two agents in one checkout and destroys work. Those
costs are not comparable, so the code never guesses toward "dead".

The ladder, in order, each rung returning alive on doubt:

1. `--ignore-pid` set, so the caller asked for TTL-only. Alive.
2. The lock's recorded `host` differs from this machine, or either is empty. The
   pid refers to another machine's process table. Alive.
3. No `owner_pid` recorded. Alive, subject to TTL.
4. No `/proc` on this platform. Alive.
5. `/proc/<pid>` absent, same host. **Dead.**
6. `/proc/<pid>` present but its start time differs from the recorded
   `owner_start`, meaning the pid was reused. **Dead.**
7. Otherwise alive.

Two details carry most of the weight:

**`owner_pid` comes only from `AGENTWS_PID`, never from `$$`.** The `agentws`
process itself exits within a second of taking the lock. If liveness tested that
pid, every lock would read as dead immediately, and the tool would free live
locks as a matter of routine. The lock file does record a plain `pid=` field,
but it is forensics only and no code path consults it.

**Rung 6 is the one a naive rewrite loses.** Checking only that `/proc/<pid>`
exists is not enough, because pids are recycled. `stat` field 22 is the process
start time in clock ticks since boot; it is stable for the life of a process and
differs across reuse.

## Acquisition

```bash
( set -o noclobber; printf '...' > "$lockfile" )
```

The subshell keeps `noclobber` from leaking into the caller. This is atomic
against concurrent creators on a local filesystem: exactly one writer wins, and
every loser gets a non-zero return and a message naming the current holder. It
is never replaced with a test-then-write, which has a window between the test
and the write.

`test/lock_race.bats` spawns 20 concurrent lockers and asserts exactly one
success and one well-formed lock file.

## Force policy

`--force` exists on the CLI only, for a human who has confirmed an agent is
gone.

`mcp/agentws-mcp` never passes `--force`, exposes no force parameter in any of
its six schemas, and never retries on a busy result. A busy lock comes back to
the model as a structured refusal with an error code, an owner, a reason, and an
age, mapped to an MCP tool error. The model then reports the block rather than
grinding at it. A test greps the server source to enforce this.

## Configuration

One parser, in `lib/config.sh`, producing shell variables. There is no second
representation and no cache to go stale.

The accepted grammar is a documented strict subset of YAML: flat `key: value`
scalars, `key: [a, b, c]` inline lists, `- item` block lists, and exactly one
level of nesting under `provider_opts`. Anchors, aliases, tabs, multi-line
scalars, quoted keys, and nested maps elsewhere are refused with a `file:line`
error. Nothing is ever silently dropped, because a silently dropped key in a
lock manager's config is a safety bug.

`agentws config --json` prints exactly what the parser saw, so any parse is
auditable without reading the parser.

Paths get `~/` expanded and the placeholders `{root}`, `{top}`, `{slot}`,
`{user}` substituted, then `root` and `lock_dir` are canonicalised with
`pwd -P`. Canonicalisation matters: two symlinked paths to one physical checkout
must not produce two different lock files.

`provider_opts` becomes `AGENTWS_P_*`. Core code never reads `AGENTWS_P_*`, and
providers never read the config file directly.
