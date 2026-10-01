#!/usr/bin/env bash
# check-release.sh - verify VERSION, CHANGELOG.md, and an optional release tag agree.
#
# Usage: scripts/check-release.sh [--notes] [vX.Y.Z]
#
# Rules:
#   VERSION is one line of semver X.Y.Z, optionally with a -prerelease suffix.
#   The first versioned heading in CHANGELOG.md (the one after an optional
#   "## [Unreleased]") is "## [VERSION] - YYYY-MM-DD" and its section is not empty.
#   With a tag: the tag is exactly "v" + VERSION, so a prerelease tag needs a
#   prerelease VERSION and the other way round.
# --notes prints that section's body on stdout once every check passes.
# AGENTWS_RELEASE_ROOT overrides the repository root (used by the tests).

set -u

die() { printf 'check-release: %s\n' "$1" >&2; exit 1; }

NOTES=0
if [ "${1:-}" = "--notes" ]; then NOTES=1; shift; fi
[ $# -le 1 ] || die "usage: check-release.sh [--notes] [tag]"
TAG="${1:-}"

ROOT="${AGENTWS_RELEASE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
[ -f "$ROOT/VERSION" ] || die "VERSION not found in $ROOT"
[ -f "$ROOT/CHANGELOG.md" ] || die "CHANGELOG.md not found in $ROOT"

SEMVER='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

[ "$(wc -l < "$ROOT/VERSION" | tr -d ' ')" = "1" ] || die "VERSION must be exactly one newline-terminated line"
VERSION="$(cat "$ROOT/VERSION")"
printf '%s\n' "$VERSION" | grep -Eq "$SEMVER" || die "VERSION '$VERSION' is not semver X.Y.Z[-prerelease]"

FIRST="$(grep -E '^## \[' "$ROOT/CHANGELOG.md" | grep -v '^## \[Unreleased\]' | head -1)"
[ -n "$FIRST" ] || die "CHANGELOG.md has no versioned section; add '## [$VERSION] - YYYY-MM-DD'"
case "$FIRST" in
  "## [$VERSION] - "*) ;;
  *) die "CHANGELOG.md newest section is '$FIRST', expected '## [$VERSION] - YYYY-MM-DD'" ;;
esac
printf '%s\n' "$FIRST" | grep -Eq '^## \[[^]]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || die "CHANGELOG.md heading '$FIRST' must end in a YYYY-MM-DD date"

BODY="$(awk -v h="$FIRST" '
  $0 == h { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]+\]: / { exit }
  on && !seen && /^[[:space:]]*$/ { next }
  on { seen = 1; print }
' "$ROOT/CHANGELOG.md")"
[ -n "$(printf '%s' "$BODY" | tr -d '[:space:]')" ] || die "CHANGELOG.md section for $VERSION is empty"

if [ -n "$TAG" ]; then
  case "$TAG" in
    v*-*) case "$VERSION" in *-*) ;; *) die "tag '$TAG' is a prerelease but VERSION '$VERSION' is not" ;; esac ;;
  esac
  [ "$TAG" = "v$VERSION" ] || die "tag '$TAG' does not match VERSION '$VERSION' (expected 'v$VERSION')"
fi

if [ "$NOTES" -eq 1 ]; then
  printf '%s\n' "$BODY"
else
  printf 'check-release: ok %s%s\n' "$VERSION" "${TAG:+ (tag $TAG)}" >&2
fi
