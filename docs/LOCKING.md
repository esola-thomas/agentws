# Locking

This is the part of `agentws` that matters. Everything else is convenience.

## The guarantee

**`agentws` will never tell you a live lock is dead.**

It may tell you a dead lock is alive. That is the intended failure direction and
it is not a bug.

The two errors are not symmetric:

- A wrong "alive" verdict costs an agent up to `ttl_hours` of waiting for a slot
  that was actually free.
- A wrong "dead" verdict puts two agents in one working tree. They overwrite
  each other's files. The reconciliation afterwards costs more than the work
  either agent did, and some of the work is simply gone.

Waiting is recoverable. Overwriting is not. So every uncertain case resolves to
alive, and there is no configuration option to change that.

## The lock file

One file per slot, in a central registry, `KEY=VALUE` lines:

```
owner=claude:refactor-parser
reason=refactor the parser
epoch=1770000000
host=devbox
pid=48213
owner_pid=47990
owner_start=91433711
ttl=12
```

The registry lives **outside** the workspaces. If it lived inside a slot,
cleaning that slot would destroy the lock that says someone is using it.

| Field | Meaning |
|---|---|
| `owner` | Caller-supplied identity string. Advisory. |
| `reason` | Free text. Shown to anyone who is blocked. |
| `epoch` | Acquisition time, seconds. Drives TTL. |
| `host` | `hostname -s` at acquisition. Gates all pid reasoning. |
| `pid` | The `agentws` process that wrote the file. **Forensics only.** |
| `owner_pid` | The long-lived session process, from `AGENTWS_PID`. The only liveness source. |
| `owner_start` | That process's start time in clock ticks. Detects pid reuse. |
| `ttl` | Lifetime in hours. |

### `pid` is not `owner_pid`, and the difference is the whole design

`agentws lock 1 "reason"` runs for a fraction of a second and exits. Its pid is
dead before you read the next line of output.

If liveness tested `pid`, then every lock would be judged dead almost
immediately, and `agentws` would confidently hand a slot that is actively being
worked in to a second agent. That is the precise catastrophe this tool exists to
prevent, and it is a very easy mistake to make while rewriting this code.

So `pid` is recorded for post-mortem reading by a human and is consulted by no
code path.

`owner_pid` comes only from `AGENTWS_PID`, which the caller exports and which
must be a process that lives as long as the work does, normally the agent
session's shell:

```bash
export AGENTWS_PID=$$
```

It is written only when `AGENTWS_PID` is set **and** that pid exists in `/proc`
at lock time. If either is false, no `owner_pid` is written and the lock expires
by TTL alone. There is no other liveness source and no fallback that infers one.

## The state machine

A lock is in exactly one of four states.

```
                       no lock file
                            |
                    agentws lock <slot>
                  ( set -o noclobber; > f )
                       /          \
                 wins /            \ loses
                     v              v
                  HELD            BUSY (rc 1, holder reported)
                     |
        +------------+------------+
        |                         |
  lock_owner_alive == 0     lock_owner_alive == 1
        |                         |
   age < ttl ? HELD          STALE(process_dead)
   age >= ttl ? STALE(ttl)         |
        |                         |
        +-----------+-------------+
                    |
             takeover permitted
             ( agentws lock, or agentws claim skipping past it )
                    |
             agentws unlock  ->  no lock file
```

- **HELD**: file exists, owner alive, age below TTL. Anyone else is refused.
- **BUSY**: what a second acquirer sees. Return code 1, message names the
  current holder, reason, and age.
- **STALE(process_dead)**: the owning process is definitively gone. Reclaimable.
- **STALE(ttl)**: age has reached `ttl_hours`. Reclaimable regardless of
  liveness.

`lock_stale_reason` returns `""`, `process_dead`, or `ttl`, and checks them in
that order: a dead process is reported as dead even if it is also past TTL,
because that is the more informative answer.

## Acquisition is one atomic operation

```bash
( set -o noclobber; printf '...' > "$lockfile" )
```

`noclobber` makes `>` fail if the target exists, and the shell does the create
and the existence check as one operation. Exactly one of N concurrent writers
wins. The subshell keeps `noclobber` out of the caller's shell.

This is never rewritten as `[ -f "$f" ] || write`, which has a window between
the test and the write wide enough for two agents to both pass the test.

Verified by `test/lock_race.bats`: 20 concurrent lockers, exactly one return
code 0, nineteen return code 1, one well-formed file.

## Every uncertain case, and why it is ALIVE

`lock_owner_alive` returns 0 for alive-or-unknowable and 1 for definitively
dead. Here is every rung, in evaluation order.

### 1. `--ignore-pid` was passed. ALIVE.

The caller explicitly asked for TTL-only behaviour. Honour it. This exists so a
user on a platform with a strange `/proc`, or debugging a suspected false-dead,
can turn the ladder off without editing code. Turning it off can only make
verdicts more conservative, never less.

### 2. The lock's `host` differs from this machine, or either value is empty. ALIVE.

A pid is meaningful only within one machine's process table. Pid 47990 on
`devbox` and pid 47990 on this node are unrelated numbers.

If a lock was taken on another host, this machine cannot answer the question at
all, so it does not try. It does not even read the local `/proc`, which is
asserted by the tests: reading it would be meaningless and could only produce a
coincidental match or a wrong "dead".

The empty case is included for the same reason. If `host` was never recorded, or
`hostname -s` fails here, there is nothing to compare and the answer is unknown.

This matters most on a shared filesystem. A job running on a compute node can
read the lock directory over NFS, see a lock taken on a workstation, and
correctly refuse to judge it.

### 3. No `owner_pid` recorded, or it is not a number. ALIVE, subject to TTL.

The caller did not export `AGENTWS_PID`, or that process was already gone at
lock time. There is no liveness information in this lock. It expires by TTL and
nothing else.

The non-numeric check is defensive: a corrupted or hand-edited lock file must
not be interpreted, and an unparseable value is treated as absent rather than
guessed at.

### 4. `/proc` does not exist on this platform. ALIVE, always.

macOS, Git Bash, MSYS2. See the section below.

### 5. `/proc/<owner_pid>` does not exist, same host, `/proc` present. **DEAD.**

This is the only rung that can be reached with a definitive negative from an
absence. Every precondition has been established: the lock was taken on this
machine, a real pid was recorded, and this platform has an authoritative process
table. The process is gone.

### 6. `/proc/<owner_pid>` exists but its start time differs from `owner_start`. **DEAD.**

Pids are recycled. A long-running machine will reuse pid 47990 within days, and
the replacement process has nothing to do with the lock.

Field 22 of `/proc/<pid>/stat` is the process start time in clock ticks since
boot. It is fixed for the life of a process and effectively never matches across
a reuse, because it has clock-tick granularity and a reused pid is by definition
a later process.

This rung is easy to omit, and omitting it produces a lock that never expires
until TTL on a busy machine, plus an occasional live-lock-looks-held-forever.
The failure is quiet, which is why it has its own test case.

If `owner_start` is absent, the check is skipped and the verdict from rung 5
stands: the pid exists, so alive. Missing data never upgrades a verdict to dead.

### 7. Everything checked, nothing said dead. ALIVE.

The default answer. There is no rung after this one that can flip it.

## The six-case matrix

`test/lock_matrix.bats` runs these. `/proc` is faked through the `AGENTWS_PROC`
seam, so every case is deterministic and sub-second, with no real process
spawning or killing. Each is crossed with `--ignore-pid` and with age above and
below TTL.

| # | Situation | Verdict | `stale_reason` |
|---|---|---|---|
| 1 | Same host, `owner_pid` live, `owner_start` matches | ALIVE | `""` |
| 2 | Same host, `owner_pid` absent from `/proc` | DEAD | `process_dead` |
| 3 | Same host, `owner_pid` present, `owner_start` differs (pid reused) | DEAD | `process_dead` |
| 4 | Different host recorded, or `host` empty | ALIVE, even if that pid is absent locally | `""` or `ttl` |
| 5 | No `owner_pid` recorded | ALIVE below TTL | `""` below TTL, `ttl` at or above |
| 6 | `AGENTWS_PROC` points at nothing (macOS, Git Bash) | ALIVE, whatever the pid | `""` or `ttl` |

Case 4 additionally asserts that the local `/proc` is not read at all. Case 6
additionally asserts that `agentws locks --json` reports
`"liveness_supported": false` and that `agentws doctor` emits the warning, so the
degradation is never silent.

## macOS: TTL-only locking

**There is no `/proc` on macOS.** Rung 4 therefore returns alive
unconditionally, and the consequences are:

- Process-death detection never fires. A lock whose owning agent was killed,
  crashed, or was closed in a terminal is held for the full `ttl_hours`.
- Pid start-time reuse detection is impossible, because it is downstream of a
  process table that is not there.

There is no substitute planned. The obvious one, parsing `ps -o lstart=`, does
not work as a reuse discriminator: its format is locale-dependent and its
granularity is one second, so two processes can share both a pid and a start
second. That would produce a wrong liveness answer some of the time, and a wrong
liveness answer is worse than no liveness answer, because the wrong direction
frees a live lock.

**The net effect on macOS is a TTL-only lock.** It is strictly safe, since it
never frees a live lock, and strictly less convenient, since dead agents pin
slots until TTL.

This is never silent:

- `agentws doctor` emits:
  `WARN liveness no /proc on this platform; locks expire by TTL only (ttl_hours=12). To reclaim early: agentws unlock <slot> --force`
- `agentws locks --json` carries `"liveness_supported": false` at the top level
  and on every lock object.
- `agentws lock` prints the same one-line warning to stderr, once per day.

**Recommended macOS config: `ttl_hours: 4`, not 12.** Shorter TTL is how you buy
back the convenience the missing `/proc` costs you, and 4 hours is long enough
that an active session does not lose its own slot.

Git Bash and MSYS2 on Windows degrade identically and report the same
`liveness_supported: false`. They carry an extra caveat: `noclobber` atomicity on
an NTFS mount is unverified, so they are best-effort rather than supported. WSL2
is Linux and is fully featured.

## Reclaiming early

When you know an agent is gone and you do not want to wait out the TTL:

```bash
agentws unlock <slot> --force
```

`--force` is a CLI-only escape hatch for a human who has confirmed the situation.
It is not available over MCP, in any form, and the MCP server exposes no
parameter that reaches it. A model that hits a busy lock gets a structured
refusal and reports it. It cannot decide on its own that another agent is
probably dead, because that decision is exactly the one that destroys work.

## For maintainers

Four invariants. Breaking any of them breaks the guarantee at the top of this
file.

1. **Every uncertain case returns alive.** Exit 1 means definitively dead. If
   you add a rung, its default path must be `return 0`.
2. **The plain `pid=` field is never consulted by liveness.** It has already
   exited.
3. **`owner_pid` and `owner_start` are written only from `AGENTWS_PID`,** and
   only when that pid exists at lock time. Do not add another source.
4. **Acquisition stays `( set -o noclobber; ... > f )`.** Not test-then-write.

Any change to `lock_owner_alive`, `lock_stale_reason`, or `lock_is_stale` needs
a stated safety argument in the pull request and a case in
`test/lock_matrix.bats`.
