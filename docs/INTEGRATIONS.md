# Using the tool from other agents

The Autonomous Testing Agent can be driven by another AI agent (Claude Code, Codex, Antigravity, Cursor, or any client that speaks MCP or can run a command). It gives that agent eyes and hands on the iOS simulator and a runner for test cases; the calling agent does the thinking. Pick one of three ways. They offer the same tools, from one catalogue (`Sources/AgentGateway`).

| Way | Use it when |
|---|---|
| **MCP server** `ata-mcp` | The client supports MCP (most do). Typed tools, progress for long runs, nothing to teach the model. |
| **CLI** `AutonomousTestingAgent tool …` | No MCP, or you want a script. JSON on stdout. |
| **Skill** `skills/autonomous-testing-agent` | Teaches a model the loop and the safety rules. Use it with either of the above. |

## Set up

```bash
Scripts/install.sh              # builds release, links ata and ata-mcp into ~/.local/bin
# or just: swift build   (binaries in .build/debug)
```

The simulator must be booted and idb installed (see the README). `ata-mcp` works on the project given by `--project-root=<dir>` (else `$ATA_PROJECT_ROOT`, else the current directory): its `TestCases/` and `.runs/`. Logins in `run_case` use `TEST_USER_USERNAME` and `TEST_USER_PASSWORD` from the environment the server starts in or the project's `.env`; they are never tool arguments.

## MCP

The server speaks MCP over stdio, or over HTTP with `--http=<port>` (see below), (protocol versions 2025-06-18, 2025-03-26, 2024-11-05) and offers tools, three prompts (`write_case`, `triage_failure`, `plan_for_diff`, shown as slash commands in clients that support prompts) and read-only resources: every case as `ata://case/<KEY>` and each recent run as `ata://run/<id>` (plus `ata://run/<id>/junit`), which clients such as Claude Code let you attach with `@`.

**Over HTTP**: `ata-mcp --http=8765 --project-root=/path/to/project` serves `http://127.0.0.1:8765/mcp` on this machine only. Every request needs `Authorization: Bearer <token>` (`--token=…` or `ATA_MCP_TOKEN`; without either, a new token is printed to standard error), and a browser's cross-site request is refused. Each POST gets one JSON reply; there is no event stream, so progress notifications are not sent.

**Claude Code**

```bash
claude mcp add autonomous-testing-agent -- /path/to/ata-mcp --project-root=/path/to/project
# shared with a team: add  --scope project  to write .mcp.json
```

or in `.mcp.json`:

```json
{ "mcpServers": { "autonomous-testing-agent": {
    "command": "/path/to/ata-mcp",
    "args": ["--project-root=/path/to/project"],
    "env": { "TEST_USER_USERNAME": "tester", "TEST_USER_PASSWORD": "…" } } } }
```

**Codex** (`~/.codex/config.toml`)

```toml
[mcp_servers.autonomous-testing-agent]
command = "/path/to/ata-mcp"
args = ["--project-root=/path/to/project"]
```

**Antigravity, Cursor and other clients**: add a stdio MCP server with the same `command` and `args` in the client's MCP settings. Most take the `mcpServers` JSON above; check the client's own screen for where it goes.

## CI

`get_report` with `format=junit` returns JUnit XML (one testsuite per run, one testcase per case step), which GitHub Actions, Jenkins and GitLab show as test results:

```bash
AutonomousTestingAgent tool call get_report '{"format":"junit"}' | jq -r '.content[0].text' > results.xml   # latest run of each case
AutonomousTestingAgent tool call get_report '{"format":"junit","run_id":"SAFARI-1-20261020-0759"}'           # one run
```

Running a case needs a macOS runner with a booted simulator, idb and a model key, so `.github/workflows/ci.yml` only builds and runs the unit tests; add a self-hosted macOS runner to run cases.

## CLI

```bash
AutonomousTestingAgent tool list                              # the tools
AutonomousTestingAgent tool describe device_input             # one tool's JSON schema
AutonomousTestingAgent tool call device_observe '{"command":"read_screen"}'
AutonomousTestingAgent tool call run_case '{"key":"SAFARI-1","bundle_id":"com.apple.mobilesafari"}'
```

Output is JSON (`isError`, `content[]`); progress of a run goes to standard error. Exit status: 0 the tool ran, 1 it returned an error, 2 bad usage.

## Skill

`skills/autonomous-testing-agent/SKILL.md` teaches the observe, act, check loop, how cases are written and the safety rules; `references/tools.md` lists every tool and is generated from the catalogue.

- **Claude Code**: copy or symlink the folder to `~/.claude/skills/` (all projects) or `.claude/skills/` (this project).
- **Codex and other agents that read `AGENTS.md`**: the repository's `AGENTS.md` already points at the skill; give the agent the folder.
- Any other agent: put the contents of `SKILL.md` where the client keeps instructions.

## Safety model

| Kind | Examples | Rule |
|---|---|---|
| Read-only | `read_screen`, `find`, `screenshot`, `list_cases`, `get_report` | Run. |
| Reversible | `tap`, `type_text`, `launch_app`, `set_appearance`, `write_case` | Run. The calling agent's own permission prompt is the guard. |
| Destructive | `uninstall_app`, `clear_photos`, `erase`, deleting a crash report | Refused until the call has `confirm: true`. |

`run_case` refuses destructive steps unless `allow_destructive: true`. Output is passed through the secret redactor. The server has no tool that runs shell commands or reads files outside the project's `TestCases/` and `.runs/`. `look` sends a screenshot to Gemini and needs a Gemini key; everything else needs no model key.

## Speed and troubleshooting

- A command takes about 0.3 s once the server is running; the first one about 1 s (finding the booted simulator through `simctl`).
- Send known runs of actions as one `device_sequence`, and use `wait_for_screen` instead of polling: both save round trips.
- `ATA_TRACE=/tmp/ata-trace.log` (in the environment of `ata-mcp` or the CLI) appends how long each idb or `simctl` call took, to find what is slow.
