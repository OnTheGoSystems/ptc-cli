# PTC MCP + CLI — translate your app with your coding agent

PTC is your expert AI translator. It learns your app, researches unclear texts, translates in your own style and tests the results.


Your agent needs both: the **PTC MCP** and this **CLI** (the agent runs it to
scan your repo and report what it finds). There is no MCP-only path. Tested with
Claude Code; any agent that speaks MCP and can run a shell command should work.

## Connect your agent

### 1. Get your agent token

Sign up to PTC and open PTC's agent token page
(<https://app.ptc.wpml.org/dashboard/agent-tokens>). Your agent token is yours
(one per user): PTC mints it the first time you need it, and you can only rotate
it, never add a second one. It is how your agent identifies itself to PTC.

### 2. Add PTC to your agent

The MCP endpoint is `https://app.ptc.wpml.org/mcp`.

Copy the setup for your agent from the
[agent token page](https://app.ptc.wpml.org/dashboard/agent-tokens): it has a
ready block for Claude Code, Cursor, VS Code and any other MCP client, with your
token already filled in. Paste it as it is.

**Codex** — first export `PTC_API_TOKEN` in your shell with the value the agent
token page shows you (Codex reads the token from that variable), then:

```bash
codex mcp add ptc --url https://app.ptc.wpml.org/mcp --bearer-token-env-var PTC_API_TOKEN
```

### 3. Install the CLI

From the repository root:

```bash
mkdir -p .ptc/bin && curl -fsSL https://app.ptc.wpml.org/cli/ptc-cli.sh -o .ptc/bin/ptc-cli.sh && chmod +x .ptc/bin/ptc-cli.sh
```

Every `ptc` command in these docs is `.ptc/bin/ptc-cli.sh` run from the
repository root (alias it as `ptc` if you like). `.ptc/` is the CLI's own
git-ignored folder, so later syncs reuse the script with no reinstall.

Needs bash and curl; the agent commands also need **python3 (>= 3.6)**.

Then save your agent token for the CLI yourself (your agent asks you to; the
token never goes through it):

```bash
.ptc/bin/ptc-cli.sh auth login
```

It signs you in through the browser: it prints a link and a code (and opens
the link), you approve the code on PTC, signed in as yourself, and the CLI
receives your agent token; you type no token and nothing is shown. On a machine
with no browser, open the link on any device. `--paste` pastes the token from
the agent token page instead (nothing is shown as you paste), and a token piped
on stdin is read as before. It checks the token with PTC and saves it, readable
by you only (mode 600), to
`%APPDATA%\ptc\credentials` on Windows (Git Bash, MSYS, Cygwin) or
`~/.config/ptc/credentials` elsewhere (`$XDG_CONFIG_HOME/ptc/credentials` when
set). A token PTC refuses is not saved. `PTC_API_TOKEN` or `PTC_AGENT_TOKEN` in
the environment, or `--api-token`, still win over the file.

### 4. Give your agent one prompt

```text
Localize this app into German and Spanish with PTC.
```

That is the whole instruction. PTC guides your agent through the rest.

## What happens next

1. Your agent scans the repository (`ptc scan`). PTC learns the app, its features and its terminology.
2. PTC asks you only what the code can't answer. The questions arrive in your agent's chat; decisions such as which languages to translate into stop the run until you answer. PTC shows the price and waits for a yes before any paid work; a trial continues within its free cap.
3. PTC translates with your terminology and reviews every language in your app's context.
4. Before delivering, PTC asks whether you want the translations as a merge request (PTC set up in your CI) or via the API. Answer merge request and PTC hands your agent the CI file with that answer; the agent adds it to your repository (see [CI](docs/ci.md)). Answer API and your agent delivers with `ptc sync`.

## Go deeper

- [Agent commands](docs/agent-commands.md): how PTC drives your agent, and the CLI commands it runs along the way.
- [CLI reference](docs/cli.md): usage, options, configuration file, workflow, exit codes, troubleshooting.
- [CI](docs/ci.md): pinning the CLI, GitHub Actions, GitLab CI.

## License

MIT License
