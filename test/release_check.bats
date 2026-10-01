#!/usr/bin/env bats
# release_check.bats - scripts/check-release.sh against fixture VERSION/CHANGELOG pairs.

load helper

CHECK="$AGENTWS_REPO_ROOT/scripts/check-release.sh"

setup() {
  FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/agentws-rel.XXXXXX")"
  export AGENTWS_RELEASE_ROOT="$FIXTURE"
  printf '1.2.3\n' > "$AGENTWS_RELEASE_ROOT/VERSION"
  cat > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-10-01

### Fixed

- Something.

## [1.2.2] - 2026-09-01

- Older.

[1.2.3]: https://example.invalid/v1.2.3
EOF
}

teardown() { rm -rf "$FIXTURE"; }

@test "matching VERSION and CHANGELOG pass, with and without the tag" {
  run "$CHECK"
  [ "$status" -eq 0 ]
  run "$CHECK" v1.2.3
  [ "$status" -eq 0 ]
}

@test "--notes prints only the version's section" {
  run "$CHECK" --notes v1.2.3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "### Fixed" ]
  [[ "$output" == *"- Something."* ]]
  [[ "$output" != *"Older"* ]]
  [[ "$output" != *"example.invalid"* ]]
}

@test "VERSION not bumped to the newest CHANGELOG section fails" {
  printf '1.2.2\n' > "$AGENTWS_RELEASE_ROOT/VERSION"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected '## [1.2.2]"* ]]
}

@test "missing CHANGELOG section fails" {
  printf '1.3.0\n' > "$AGENTWS_RELEASE_ROOT/VERSION"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected '## [1.3.0]"* ]]
}

@test "empty CHANGELOG section fails" {
  printf '# Changelog\n\n## [1.2.3] - 2026-10-01\n\n## [1.2.2] - 2026-09-01\n\n- x\n' \
    > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"empty"* ]]
}

@test "CHANGELOG heading without a date fails" {
  printf '# Changelog\n\n## [1.2.3]\n\n- x\n' > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md"
  run "$CHECK"
  [ "$status" -ne 0 ]
}

@test "CHANGELOG heading with a malformed date fails" {
  printf '# Changelog\n\n## [1.2.3] - 2026-1-01\n\n- x\n' > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must end in a YYYY-MM-DD date"* ]]
}

@test "carriage returns are reported as CRLF line endings" {
  printf '1.2.3\r\n' > "$AGENTWS_RELEASE_ROOT/VERSION"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"VERSION contains carriage returns"* ]]

  printf '1.2.3\n' > "$AGENTWS_RELEASE_ROOT/VERSION"
  printf '## [1.2.3] - 2026-10-01\r\n\r\n- x\r\n' > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"CHANGELOG.md contains carriage returns"* ]]
}

@test "a fenced heading inside Unreleased is not the newest section" {
  cat > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

```
## [9.9.9] - 2026-01-01
```

## [1.2.3] - 2026-10-01

- Real.
EOF
  run "$CHECK" --notes v1.2.3
  [ "$status" -eq 0 ]
  [ "$output" = "- Real." ]
}

@test "--notes keeps fenced headings and mid-section link definitions" {
  cat > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md" <<'EOF'
# Changelog

## [1.2.3] - 2026-10-01

- First, see [docs].

[docs]: https://x

- After the link.

```
## [example]
[y]: https://y
```

- After the fence.

## [1.2.2] - 2026-09-01

- Older.

[1.2.3]: https://example.invalid/v1.2.3
EOF
  run "$CHECK" --notes v1.2.3
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "- First, see [docs]." ]
  [[ "$output" == *"[docs]: https://x"* ]]
  [[ "$output" == *"- After the link."* ]]
  [[ "$output" == *"## [example]"* ]]
  [[ "$output" == *"[y]: https://y"* ]]
  [ "${lines[${#lines[@]}-1]}" = "- After the fence." ]
  [[ "$output" != *"Older"* ]]
}

@test "trailing link definitions at end of file are not part of the notes" {
  printf '# Changelog\n\n## [1.2.3] - 2026-10-01\n\n- x\n\n[1.2.3]: https://z\n' \
    > "$AGENTWS_RELEASE_ROOT/CHANGELOG.md"
  run "$CHECK" --notes v1.2.3
  [ "$status" -eq 0 ]
  [ "$output" = "- x" ]
}

@test "bad semver in VERSION fails" {
  for v in 1.2 v1.2.3 01.2.3 '1.2.3 ' 1.2.3+build; do
    printf '%s\n' "$v" > "$AGENTWS_RELEASE_ROOT/VERSION"
    run "$CHECK"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not semver"* ]]
  done
}

@test "multi-line VERSION fails" {
  printf '1.2.3\n1.2.4\n' > "$AGENTWS_RELEASE_ROOT/VERSION"
  run "$CHECK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"exactly one newline-terminated line"* ]]
}

@test "tag that does not match VERSION fails" {
  for t in v1.2.4 1.2.3 v1.2.3.0; do
    run "$CHECK" "$t"
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match"* ]]
  done
}

@test "prerelease tag fails unless VERSION is the same prerelease" {
  run "$CHECK" v1.2.3-rc.1
  [ "$status" -ne 0 ]
  [[ "$output" == *"is a prerelease"* ]]

  printf '1.2.3-rc.1\n' > "$AGENTWS_RELEASE_ROOT/VERSION"
  sed -i.bak 's/^## \[1.2.3\]/## [1.2.3-rc.1]/' "$AGENTWS_RELEASE_ROOT/CHANGELOG.md"
  run "$CHECK" v1.2.3-rc.1
  [ "$status" -eq 0 ]
  run "$CHECK" v1.2.3
  [ "$status" -ne 0 ]
}

@test "the repository's own VERSION and CHANGELOG agree" {
  unset AGENTWS_RELEASE_ROOT
  run "$CHECK" "v$(cat "$AGENTWS_REPO_ROOT/VERSION")"
  [ "$status" -eq 0 ]
}
