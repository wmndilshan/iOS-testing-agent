# Contributing: where does my code go?

Read [ARCHITECTURE.md](../ARCHITECTURE.md) for the map and [ARCHITECTURE_RULES.md](../ARCHITECTURE_RULES.md) for the rules.

## Placement guide

| I am adding… | Put it in | Notes |
| --- | --- | --- |
| A value type or pure rule about scenarios, observations, skills, runs | `AgentCore/Domain/<area>/` | No I/O, no SwiftUI. One primary type per file. |
| Anything that decides whether an action may run | `AgentCore/Security/` | Return a verdict; never execute. Add a unit test next to `DispatchAuthorizerTests`. |
| Redaction / secret detection | `Security/Redaction/` | |
| A checksum | use `IntegrityHash` (`Shared/Hashing`) | Do not import CryptoKit elsewhere. |
| A use case or orchestration step | `AgentCore/Application/` | State changes stay in `ScenarioExecutionController`; extract a pure decider instead of growing it. |
| A new interface to something external | `AgentCore/Application/Ports/` (protocol) + `AgentInfrastructure/<area>/` (implementation) | Only if there is a real second implementation or test seam. Use provider-neutral types in the port. |
| Anything LLM-provider specific (wire models, error mapping) | `AgentInfrastructure/LLM/` | Application must never name a provider type. Map at the boundary (`GeminiRequestMapping`). |
| A rule that decides on a proposal, dispatch or UI gate | a pure decider returning a verdict (`ProposalAdmission`, `DispatchAuthorizer`) | The owner applies the verdict. Don't add a stateful coordinator unless it owns its own state. |
| A new iOS capability | typed action in `Domain/Interaction`, one decoder entry, one performer in `Application/Tools/iOS/Performers`, one descriptor in `ToolCatalog` | Never a case in `ToolRegistry`. Set `live` honestly (`SIMULATION_ONLY` until a live run proves it) and update `docs/IOS_CAPABILITY_MATRIX.md` in the same change. |
| A new tool | one `ToolDescriptor` in `ToolCatalog` (+ an adapter behind a port for external systems) | Read-only or mutating is decided there, never by the model. A mutating tool runs only through the dispatcher with an authorization proof. |
| A log line | `logger.info(.category, "area.thing.happened", fields: ...)` with an injected `AppLogger` | Typed category, dotted lowercase event, no secrets, no prompt/response text, no `print`. See `docs/LOGGING_ARCHITECTURE.md`. |
| A new external integration (Figma, Jira, ...) | port in `Application/Ports`, adapter in `AgentInfrastructure/<name>` | Untrusted data in, artifacts out; the adapter can never authorize, approve or dispatch. See `docs/TOOL_ARCHITECTURE.md`. |
| A stored file (screenshot, export, report) | `ArtifactStoring` | Return an `ArtifactReference`, never the bytes. |
| An error type | adopt `ErrorCategoryProviding` with an exhaustive mapping | |
| Failure handling / retries | `AgentCore/Application/Recovery/` | Advisory. Must not reference `ToolRegistry` or drivers. |
| Trace, history, metrics types | `Observability/` | Passive; no execution access. |
| File/network/process code | `AgentInfrastructure/` | Processes are launched only from the known sites in `ExecutionBoundaryFreezeTests`. |
| Observable UI state | `AgentPresentation/<Feature>/` | Receives composed objects; it cannot import infrastructure. |
| Something that needs a driver | take `DeviceDriver` as a parameter | Never name or construct `IDBDriver`; `InfrastructureFactory.makeIDBDriver` builds it. |
| A tool other agents can call | `AgentGateway/` (one `GatewayTool`) | Shows up in the MCP server and `tool list` automatically. Regenerate `skills/autonomous-testing-agent/references/tools.md` (`tool list --markdown`); a test fails when it is stale. A destructive tool needs the `confirm` rule. |
| A command line mode | `AgentEngine/Commands/` (+ a dispatch line in `Engine.run`) | Get persistent stores from `InfrastructureFactory`. `Sources/CLI` stays a thin `main.swift`. |
| A test-case run feature (planning, judging, recovery) | `AgentEngine/CaseRunner/<Concern>/` | One responsibility per file. |
| An agent, tool or Operate worker | `AgentEngine/Agents/` or `AgentEngine/Operate/` | Agents only request device commands; the app runs them. |
| A SwiftUI view | `Sources/GUI/Views/<Feature>/` | One primary view per file. |
| Choice of persistent location | `AgentInfrastructure/Composition/InfrastructureFactory.swift` | Only place allowed to name `.skills` / `.runs`. |
| Wiring a view-model to its adapters | `AgentComposition/AppCompositionRoot.swift` | Only module that depends on both infrastructure and presentation. |

## Checklist before you open a change

1. `swift build` builds all targets; `swift test` passes, including the architecture suites (`TrustedSpineAuditTests`, `LayerDependencyTests`).
2. Your tests are named `@Suite` structs in `Tests/AutonomousTestingAgentTests/<Module>/<Area>/` (the module that owns the code under test); cross-cutting architecture rules are in `Architecture/` and shared fakes in `Support/`.
3. Tests do not write to the real `.skills/` or `.runs/`. Use a temp directory.
4. No new path to the simulator, or `ToolRegistry` execution, no code that turns a model's `ToolCall` into an execution, and no new layer dependency edge. If you truly need one, update the audit table
   in ARCHITECTURE.md and the audit test in the same change, and say so in the description.
5. No secrets or API-key fragments in logs, traces, or test output.
6. No new protocol, module, or folder without a concrete need. No empty placeholder files.
7. A new module dependency is a change to `Package.swift` and `ModuleGraphTests`. Imports are minimal. `import SwiftUI` only in `AgentPresentation` and `GUI`.
8. Access is as tight as it can be: `private` first; `internal` only when a type is split across files.

## Splitting a big file

Split by responsibility, not by length. For a type with shared stored state (the controller),
move methods into `Type+Concern.swift` extensions and keep stored properties in the primary file. If a piece of logic
can be a pure function of its inputs (like `DispatchAuthorizer`), extract it as its own type that returns a decision
and let the owner apply it. Run `swift build` and the focused tests after each move.
