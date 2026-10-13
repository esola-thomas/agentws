#!/usr/bin/env bats

load helper

@test "Claude plugin package excludes CLI executables and includes the init skill" {
  local version
  version="$(cat "$AGENTWS_REPO_ROOT/VERSION")"

  run jq -e --arg version "$version" \
    '.name == "agentws" and .version == $version' \
    "$AGENTWS_REPO_ROOT/claude-plugin/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]

  run jq -e --arg version "$version" \
    '.name == "agentws" and
     (.plugins | any(.name == "agentws" and .source == "./claude-plugin" and .version == $version))' \
    "$AGENTWS_REPO_ROOT/.claude-plugin/marketplace.json"
  [ "$status" -eq 0 ]

  [ ! -e "$AGENTWS_REPO_ROOT/claude-plugin/bin" ]
  [ -f "$AGENTWS_REPO_ROOT/claude-plugin/skills/init/SKILL.md" ]
  grep -q '^name: init$' "$AGENTWS_REPO_ROOT/claude-plugin/skills/init/SKILL.md"
}
