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

CR="$(printf '\r')"
for f in VERSION CHANGELOG.md; do
  if grep -q "$CR" "$ROOT/$f"; then die "$f contains carriage returns (CRLF line endings); convert it to LF"; fi
done

[ "$(wc -l < "$ROOT/VERSION" | tr -d ' ')" = "1" ] || die "VERSION must be exactly one newline-terminated line"
VERSION="$(cat "$ROOT/VERSION")"
printf '%s\n' "$VERSION" | grep -Eq "$SEMVER" || die "VERSION '$VERSION' is not semver X.Y.Z[-prerelease]"

# Prints the newest versioned heading, then its body. Headings inside ``` fences
# do not count; trailing blank and link-reference lines are dropped.
SECTION="$(awk '
  /^```/ { if (on) buf[n++] = $0; fence = !fence; next }
  !fence && /^## \[/ {
    if (on) exit
    if ($0 ~ /^## \[Unreleased\]/) next
    print; on = 1; next
  }
  on { buf[n++] = $0 }
  END {
    while (n > 0 && (buf[n-1] ~ /^[[:space:]]*$/ || buf[n-1] ~ /^\[[^]]+\]: /)) n--
    for (s = 0; s < n && buf[s] ~ /^[[:space:]]*$/; s++) ;
    for (i = s; i < n; i++) print buf[i]
  }
' "$ROOT/CHANGELOG.md")"
FIRST="$(printf '%s\n' "$SECTION" | head -1)"
BODY="$(printf '%s\n' "$SECTION" | sed 1d)"

[ -n "$FIRST" ] || die "CHANGELOG.md has no versioned section; add '## [$VERSION] - YYYY-MM-DD'"
case "$FIRST" in
  "## [$VERSION] - "*) ;;
  *) die "CHANGELOG.md newest section is '$FIRST', expected '## [$VERSION] - YYYY-MM-DD'" ;;
esac
printf '%s\n' "$FIRST" | grep -Eq '^## \[[^]]+\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' \
  || die "CHANGELOG.md heading '$FIRST' must end in a YYYY-MM-DD date"
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
