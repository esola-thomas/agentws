@AGENTS.md

Repo rules: bash 3.2 for `bin/` and `lib/`, plain git porcelain only, providers
never touch the lock dir. Run `bats test/` and `shellcheck bin/agentws lib/*.sh
providers/*.sh mcp/agentws-mcp` before opening a PR. See CONTRIBUTING.md.
