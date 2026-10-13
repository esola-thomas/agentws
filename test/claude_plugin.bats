#!/usr/bin/env bats

load helper

@test "Claude plugin metadata and marketplace point to the init skill" {
  local version
  version="$(cat "$AGENTWS_REPO_ROOT/VERSION")"

  run jq -e --arg version "$version" \
    '.name == "agentws" and .version == $version' \
    "$AGENTWS_REPO_ROOT/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]

  run jq -e --arg version "$version" \
    '.name == "agentws" and
     (.plugins | any(.name == "agentws" and .source == "." and .version == $version))' \
    "$AGENTWS_REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]

  [ -f "$AGENTWS_REPO_ROOT/skills/init/SKILL.md" ]
  grep -q '^name: init$' "$AGENTWS_REPO_ROOT/skills/init/SKILL.md"
}
