# Contributing

## Ground rules

1. **Pure bash. The floor is bash 3.2**, which is the system bash on macOS.
   There is no Python, Node, Go, or compiled component in this project, and
   there will not be one.
2. **The lock ladder does not change.** `lib/lock.sh` is a semantically verbatim
   port of the reference implementation. Changes to `lock_owner_alive`,
   `lock_stale_reason`, or `lock_is_stale` need a stated safety argument and a
   test in `test/lock_matrix.bats`. Read [docs/LOCKING.md](docs/LOCKING.md)
   before touching any of it.
3. **No forge APIs.** Plain git porcelain only.
4. **Providers may not touch the lock directory.** Locking is core-only. A
   provider that reads `$AGENTWS_LOCK_DIR` will be rejected.
5. **No em-dashes, no buzzwords** in code, comments, docs, or commit messages.
   Direct factual language.
6. **Comments are minimal.** A TODO, a non-obvious why, or a short section
   header. Never a restatement of the next line. One line is the target.

## bash 3.2 compatibility

This host may run bash 4.x. **A 3.2 violation will not fail here.** You have to
catch it by inspection, and so does the reviewer.

Banned outright:

| Construct | Use instead |
|---|---|
| `declare -A` (associative arrays) | Parallel indexed arrays, or a space-separated string parsed by `case` |
| `${var,,}` / `${var^^}` | `tr '[:upper:]' '[:lower:]'` |
| `mapfile` / `readarray` | `while IFS= read -r line; do ... done` |
| `&>>`, `|&` | `>>file 2>&1`, `2>&1 |` |
| `local -n` (nameref) | Print to stdout and capture |

The single exception is `mcp/agentws-mcp`, which requires bash 4.1 for
`read -r -N` framing and asserts that at startup. Nothing in `bin/`, `lib/`, or
`providers/` may depend on bash 4.

### The array-guard review rule

The whole codebase runs under `set -u`. In bash 3.2, expanding an **empty**
array as `"${arr[@]}"` is an unbound-variable error. bash 4.4 quietly allows it,
so this is exactly the class of bug that passes locally and breaks on a
contributor's Mac.

Every array expansion must carry the `+` guard:

```bash
# WRONG. Fails under bash 3.2 + set -u when objs is empty.
printf '%s\n' "${objs[@]}"

# RIGHT.
printf '%s\n' "${objs[@]+"${objs[@]}"}"
```

The same applies to `for x in "${arr[@]+"${arr[@]}"}"` and to passing an array
to a function.

Reviewers run this and read every hit:

```bash
grep -rn '\[@\]' bin lib providers mcp | grep -v '\[@\]+' | grep -v '\${#'
```

`${#arr[@]}` is excluded because taking the length of an empty array is safe in
bash 3.2. Only value expansions are affected.

Any hit that is not `${arr[@]+...}` needs a justification in the pull request or
gets fixed. `test/json_shape.bats` exercises the empty-lock-directory path,
which is the case that trips the unguarded form.

## Running the tests

Tests are [bats](https://github.com/bats-core/bats-core).

```bash
# Debian/Ubuntu
sudo apt-get install bats shellcheck
# macOS
brew install bats-core shellcheck

# everything
bats test/

# one file
bats test/lock_matrix.bats

# lint
shellcheck -s bash bin/agentws lib/*.sh providers/*.sh mcp/agentws-mcp install.sh
```

The lock tests never read the real `/proc`. They point `AGENTWS_PROC` at a fake
process tree built in a temp directory, so every liveness case is deterministic
and runs in well under a second. Do not add a test that depends on spawning a
real process and killing it.

`test/lock_race.bats` spawns 20 concurrent `agentws lock` processes and asserts
exactly one succeeds. If you change acquisition, that test is the gate.

### Testing the bash 3.2 path for real

If you have a real bash 3.2 (macOS system bash at `/bin/bash`), run the suite
under it before sending anything that touches array handling:

```bash
BATS_SHELL=/bin/bash bats test/
/bin/bash -c 'set -u; source lib/core.sh'
```

## Pull requests

- One change per pull request. State what you changed and why in the
  description, not in the source comments.
- Include a test for any behaviour change in `lib/lock.sh`, `lib/slots.sh`, or
  the JSON envelope shape.
- If you add a config key, document it in `.agentws.yml.example` and make the
  parser reject the old spelling loudly rather than silently ignoring it.
- New providers go in `providers/`, implement `provider_api_version` returning
  `1`, and come with a `test/provider_contract.bats` case.

## Reporting bugs

Include your platform, `bash --version`, the output of `agentws doctor --json`,
and `agentws config --json`. The config dump prints exactly what the parser saw,
which is usually where the problem is.

Please check the non-goals in the README first. Requests for forge integration,
a web UI, a daemon, or distributed locking will be closed.
