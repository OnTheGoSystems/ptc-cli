# PTC MCP + CLI — translate your app with your coding agent

PTC is your expert AI translator. It learns your app, researches unclear texts, translates in your own style and tests the results.


Your agent needs both: the **PTC MCP** and this **CLI** (the agent runs it to
scan your repo and report what it finds). There is no MCP-only path. Tested with
Claude Code; any agent that speaks MCP and can run a shell command should work.

## Connect your agent

### 1. Create an agent token

Sign up to PTC and create an agent token on PTC's agent token page
(<https://app.ptc.wpml.org/dashboard/agent-tokens>). It is how your agent
identifies itself to PTC. Export it in the shell your agent runs in:

```bash
export PTC_API_TOKEN=...
```

### 2. Add PTC to your agent

The MCP endpoint is `https://app.ptc.wpml.org/mcp`.

**Claude Code**
```bash
claude mcp add --transport http ptc https://app.ptc.wpml.org/mcp \
  --header "Authorization: Bearer $PTC_API_TOKEN"
```

**Cursor** — `.cursor/mcp.json`
```json
{ "mcpServers": { "ptc": { "url": "https://app.ptc.wpml.org/mcp",
  "headers": { "Authorization": "Bearer $PTC_API_TOKEN" } } } }
```

**Codex** — `~/.codex/config.toml`
```toml
[mcp_servers.ptc]
url = "https://app.ptc.wpml.org/mcp"
headers = { Authorization = "Bearer $PTC_API_TOKEN" }
```

### 3. Install the CLI

```bash
curl -fsSL https://raw.githubusercontent.com/OnTheGoSystems/ptc-cli/v1/ptc-cli.sh -o ptc-cli.sh
chmod +x ptc-cli.sh
```

Needs bash and curl; the agent commands also need **python3 (>= 3.6)**.
### 4. Give your agent one prompt

```text
Localize this app into German and Spanish with PTC.
```

That is the whole instruction. PTC guides your agent through the rest.

## What happens next

1. Your agent scans the repository (`ptc scan`). PTC learns the app, its features and its terminology.
2. PTC asks you only what the code can't answer. The questions arrive in your agent's chat; decisions such as which languages to translate into or approving the estimate stop the run until you answer.
3. PTC translates with your terminology and reviews every language in your app's context.
4. Before delivering, PTC asks whether you want the translations as a merge request (PTC set up in your CI) or via the API.
5. For the merge request, tell your agent: `Set PTC up in our CI so the translations stay up to date.` The agent sets up the CI job; PTC tells it how (see [CI](docs/ci.md)).

## Go deeper

- [Agent commands](docs/agent-commands.md): how PTC drives your agent, and the CLI commands it runs along the way.
- [CLI reference](docs/cli.md): usage, options, configuration file, workflow, exit codes, troubleshooting.
- [CI](docs/ci.md): pinning the CLI, GitHub Actions, GitLab CI.

## License

MIT License
