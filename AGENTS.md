# Agent instructions

## Using the Autonomous Testing Agent from another agent

This repository builds a tool that operates an iOS simulator and runs plain-language test cases. If you are an AI agent asked to try an app on the simulator, check what is on screen, or write or run a test case, use it:

- MCP: run `ata-mcp` (see `docs/INTEGRATIONS.md`) and use its tools; or
- CLI: `AutonomousTestingAgent tool list`, then `AutonomousTestingAgent tool call <tool> '<json>'`.

Read `skills/autonomous-testing-agent/SKILL.md` first: it explains the observe, act, check loop, how test cases are written and the safety rules (destructive commands need `confirm: true` after the user agrees; never put passwords in arguments). The full tool list is `skills/autonomous-testing-agent/references/tools.md`.

## Working on this repository

- Build and test: `swift build`, `swift test --no-parallel`.
- Where code goes, and the module rules: `docs/CONTRIBUTING.md`, `ARCHITECTURE.md`, `ARCHITECTURE_RULES.md`. Architecture tests enforce them.
- The tool catalogue is `Sources/AgentGateway`; the skill's `references/tools.md` is generated from it with `AutonomousTestingAgent tool list --markdown` and a test fails when it is stale.
