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

# What Anthropic's plugin directory blocks or holds on. Installers receive only
# the plugin folder, so each of these has to live inside it.
@test "Claude plugin folder meets the plugin directory's requirements" {
  local p="$AGENTWS_REPO_ROOT/claude-plugin" icon words

  run jq -e '.license == "MIT" and (.repository | startswith("https://")) and
             (.icon | startswith("./")) and (.supportUrl | startswith("https://"))' \
    "$p/.claude-plugin/plugin.json"
  [ "$status" -eq 0 ]

  icon="$(jq -r .icon "$p/.claude-plugin/plugin.json")"
  [ -s "$p/$icon" ]
  cmp -s "$AGENTWS_REPO_ROOT/LICENSE" "$p/LICENSE"

  # The directory wants 40 words outside code blocks.
  words="$(awk '/^```/ { fence = !fence; next } !fence' "$p/README.md" | wc -w | tr -d ' ')"
  [ "$words" -ge 40 ]

  # No symlinks, and no path that leaves the folder.
  [ -z "$(find "$p" -type l)" ]
  run grep -rn -F '../' "$p/skills"
  [ "$status" -ne 0 ]
}
