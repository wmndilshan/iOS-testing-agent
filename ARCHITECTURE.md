# Architecture

AutonomousTestingAgent runs test cases on an iOS simulator. A test case (from AIO, a file, or written by hand) is turned
into actions by an LLM, checked, executed through idb, and judged from screenshots. The LLM can only *propose*; a
deterministic, gated pipeline decides whether anything runs. This document describes the code as it is. Rules that keep
it that way are in [ARCHITECTURE_RULES.md](ARCHITECTURE_RULES.md); where to put new code is in
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md). Subsystem detail: [docs/TOOL_ARCHITECTURE.md](docs/TOOL_ARCHITECTURE.md),
[docs/LOGGING_ARCHITECTURE.md](docs/LOGGING_ARCHITECTURE.md), [docs/IOS_CAPABILITY_MATRIX.md](docs/IOS_CAPABILITY_MATRIX.md),
[docs/TEST_PLANNING_ARCHITECTURE.md](docs/TEST_PLANNING_ARCHITECTURE.md).

## Module graph

```
                 CodeIntelligence    TestCaseSources            (independent libraries)
                        \                  |
 AgentCore  <──  AgentInfrastructure  <──  AgentEngine  <──  CLI        (runs cases, agents, Operate)
     ^                  ^   ^                                 |
     |                  |   +── AgentGateway <── AgentMCP <── ata-mcp   (tools for other agents)
 AgentPresentation <── AgentComposition  <──  GUI                       (the macOS app)
```

`AgentGateway` is the one catalogue of tools other agents may call (device, cases, runs, planning). The MCP server and the CLI's `tool` mode are
two front-ends over it. It never links the engine or the UI: it runs cases by launching the CLI as a process. See [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md).

The arrows are compile-time dependencies (`Package.swift`), pinned by `ModuleGraphTests`. The core depends on nothing. The view-models see the
core only. Only `AgentComposition` sees both adapters and view-models. The GUI never touches an adapter, and the CLI never touches a view-model.

## Targets

| Target | Kind | Role |
| --- | --- | --- |
| `TestCaseSources` | library | The neutral `TestCase` model, the `TestCaseSource` protocol, and its sources: `FileTestCaseSource` and the AIO client (`AIO/`). AIO is only a source of cases. No dependency on the agent. |
| `AgentCore` | library | The core: `Shared`, `Domain`, `Security`, `Observability`, `Application` (use cases and ports). Depends on nothing; no I/O, no UI. |
| `AgentInfrastructure` | library | Adapters for the ports: idb, the model APIs, files and persistence, logging, simulator control. `InfrastructureFactory` decides where persistent state lives. Depends on `AgentCore`. |
| `AgentEngine` | library | What the tool does: `CaseRunner/`, `Agents/`, `Operate/` and the four commands in `Commands/` behind `Engine.run(arguments:)`. Depends on core, infrastructure, `CodeIntelligence`, `TestCaseSources`. |
| `AgentGateway` | library | The tools other agents call, transport-free: `device_*`, cases, runs, planning. Depends on core, infrastructure, `TestCaseSources`. |
| `AgentMCP` | library | MCP over stdio (JSON-RPC 2.0) over the gateway. Executable `ata-mcp` is a thin main over it. |
| `AgentPresentation` | library | Observable view-models for the GUI. Depends on `AgentCore` only, so it cannot construct or even name an adapter. |
| `AgentComposition` | library | `AppCompositionRoot`: the only place that sees both adapters and view-models; it wires one into the other. |
| `CodeIntelligence` | library | Read-only static analysis and test planning (SwiftSyntax). Independent of `AgentCore`; cannot execute, approve or dispatch. Kept for codebase-based test generation. |
| `AutonomousTestingAgent` (`Sources/CLI`) | CLI | A three-line `main.swift` that calls `Engine.run`: `--run-case=<KEY>` (hidden alias `--aio-run`), `--agent`, `--operate`, `--plan-tests`. |
| `AutonomousTestingAgentApp` (`Sources/GUI`) | macOS app | Seven sections: Run, Tests, History, Skills, Simulator, Operate, Agent; Settings holds the agents' repository path. Views and design system only; it starts the CLI as a process and reads its `@@EVENT` lines (`--events`). |
| `Fixtures/iOSFixtureApp` | Xcode project | The fixture app, a future test target. Not part of SPM. |

## Runner flow

The runner is `Sources/AgentEngine/CaseRunner/`, one responsibility per file: `CaseRunner` (flags, setup, run lock),
`CaseDefinition` (loads the case from a source), `StepPlanner` and `StepRunner` (plan and run one case step), `DocumentRunner`
(runs a `TestIR` through the spine), `CaseRunSession` (report, events, outcome), `DestructiveActionGate` (who may approve what),
`ScreenJudge`, `SkillReplay`, `OffscreenReveal`, `HumanLogin`, `PlannerNotes`, `CaseRunEvents`.

Per case step: observe the live accessibility tree (idb) -> derive the real UI vocabulary -> `TestIRGenerator` plans that
step against it -> `TestIRValidator` -> proposal -> approval -> `ScenarioExecutionController.dispatchCurrentStep` -> fresh
observation and deterministic verification -> screenshot judge (Gemini). A learned `StepSkill` replays a verified step when
the start screen matches. A step the agent cannot express makes the run INCOMPLETE, never PASSED.

Modes: `LIVE_AUTONOMOUS_AFTER_LOGIN` (scripted policy approval, disclosed in the report) and `NON_LIVE_TEST` (no live
approval is claimed in the report). A destructive step (delete, remove, log out, ...) is never approved by the scripted policy:
a person approves it, shown the labels on the same row, unless `--allow-destructive` is given.

## Agent team (`--agent`)

`Sources/AgentEngine/Agents/`: `Agent` is a tool-calling loop over the `ToolCallingLLM` port (`Application/Ports`; DeepSeek and Gemini
implementations in `AgentInfrastructure/LLM/Client`, streaming reasoning, text and parallel tool calls). `AgentTeam` is an orchestrator whose tools
delegate to RepoAnalyst (read-only `RepoSandbox` plus CodeIntelligence), CaseAuthor (writes `TestCases/<KEY>.json`), Runner and Validator. The
agents cannot approve, dispatch or touch the device: `run_case` asks the person to approve, then emits `agent-run-request`; the app starts the
run through the normal runner (shown in Run) and sends the result back as `run-result`. `AgentChatState` (AgentPresentation) reads the `agent-*`
events and writes `user`, `answer` and `run-result` JSON lines to stdin. The repository path is a Settings value, passed as `--repo`. `AgentMemory` (turns plus facts, saved in UserDefaults per repository) is sent as a `memory` line to a new agent process before the first message. `AgentTranscript` holds only the fast-changing revision counter, so only the conversation view redraws while an answer streams.

## The trusted spine

```
LLM -> TestIR -> TestIRValidator -> ActionProposal -> TrustedActionValidator -> approval (single use, 120 s)
    -> ScenarioExecutionController -> DispatchAuthorizer -> ScenarioStepDispatcher -> ToolRegistry -> DeviceDriver (IDBDriver)
    -> fresh observation -> deterministic verification
```

Recovery, security and observability are advisory or passive. `TrustedSpineAuditTests`,
`ExecutionBoundaryFreezeTests` and `LayerDependencyTests` enforce the spine by scanning the source.

## Device driver

`DeviceDriver` (Application/Ports) is the port; `IDBDriver` (AgentInfrastructure/IDB, over `IDBClient`) is the only live
implementation (`SimulatedDriver`, a test double, lives in the test target). idb reads the accessibility tree and sends input; the driver
refuses an observation when the expected app is not in the foreground (`ApplicationIdentityVerdict`). Only the
composition root (`AppCompositionRoot.makeIDBDriver`) builds it.

## Layers inside `AgentCore`

Dependencies point downward only; the allowed edges are a matrix in `LayerDependencyTests`.

```
Sources/AgentCore/            the core (depends on nothing)
  Shared/          Clock, AnyCodableValue, IntegrityHash, Logging
  Domain/          Pure value types: Actions, Artifacts, Errors, IR (TestIR), Interaction (IOSAction), Observations,
                   Runs, Scenarios, Simulator, Skills (StepSkill), Verification, DeviceControl, Agents (AgentFlow)
  Security/        Validation (TrustedActionValidator), Authorization (ApprovalPolicy, DispatchAuthorizer, HITLApprovalRequest),
                   Redaction. Produces verdicts; never executes.
  Observability/   RunTrace, RunHistoryRecord, metrics (passive)
  Application/     IR (generation, grounding, validation, execution), Orchestration (ScenarioExecutionController,
                   ScenarioStepDispatcher, ProposalAdmission), Tools (ToolCatalog, ToolRegistry, iOS performers),
                   Recovery, LLMPolicy, Ports, Simulator, TestExecution (CaseRunReport), DeviceControl
Sources/AgentInfrastructure/  adapters
  IDB, LLM (Gemini, DeepSeek, gateway), Persistence, Simulator (simctl), Logging, Configuration, CaseRun, Imaging,
  Composition/InfrastructureFactory (the one place that names `.skills` / `.runs` and builds the real adapters)
Sources/AgentPresentation/    view-models
  Agent (chat), CaseRuns, Operate, Tests, History, Skills, Simulator, Workspace
Sources/AgentComposition/     AppCompositionRoot (wires adapters into view-models)
Sources/AgentEngine/          CaseRunner, Agents, Operate, Commands
```

## The macOS app

`Sources/GUI/` is views only; its state lives in `AgentPresentation`.

```
App/        AutonomousTestingAgentApp (scenes, menu commands), AppDelegate, Harness/ (debug-only launch flags, screenshots, layout dump)
Design/     DesignSystem (spacing, radii, type, tone colours, one surface style), Format, Components/ (badges, surfaces, controls)
Views/      Shell (window, sidebar), Run, History, Skills, Simulator, Agent (chat, cards, markdown), Settings in Agent/
```

Every colour is a tone (`StatusTone.tint`) or a system colour, every rounded panel is `dsSurface`, and every list or empty state uses
`EmptyState` / `InlineBanner`, so a new view looks like the others without new styling code.

## Persistence

`.skills/` (learned step skills in `.skills/steps/`), `.runs/` (run history; case reports and screenshots in
`.runs/cases/`) and `.artifacts/` under the project root, decided only by `AppCompositionRoot`. The older `.runs/aio/` and
`.skills/aio/` are still read (History and Skills show them) but never written. Tests use temporary directories.

## Adding a test case source

Implement `TestCaseSource` (`name`, `testCase(key:) async throws -> TestCase`) in `Sources/TestCaseSources/<Name>/`, mapping the
source's steps to `TestCaseStep(number:action:data:expected:)`. `TestCaseSources` must not import `AgentCore`. Then choose it in
`CaseDefinition.loadCase` (CaseRunner), which tries a local folder first and the remote source after. The agent only sees a
`TestCase`; nothing from a source is executable.

## Device control lane

The agents can drive a simulator through a typed command set (`docs/DEVICE_CONTROL.md`). It is a lane of its own and does **not** pass through the trusted
spine: the spine runs test cases and only accepts element-targeted actions, while device commands (press Home, open a link, set a location) have no element.

- **Layers.** `Domain/DeviceControl` (commands, risk, targets, results), `Application/DeviceControl` (the catalog, validator, approval policy and the
  `DeviceControlling` port), `AgentInfrastructure/IDB/DeviceControl` (the argv builder and the idb-backed implementation).
- **Who may do what.** The agent process only sends a request event. The app validates it, applies `DeviceControlPolicy` (read-only free; reversible asked once per
  chat; destructive asked every time) and is the only caller of `DeviceControlling.run`. An agent cannot approve for itself.
- **One process site.** Commands reach `idb` and `simctl` only through `IDBClient` (arguments as an array, no shell); the process allow-list in
  `ExecutionBoundaryFreezeTests` is unchanged. There is no generic "run a command" command.
- **Pinned by** `DeviceControlLaneTests`: no process starts in the lane, no reference to the registry, dispatcher, authorizer or approval policy of the spine, the agent
  target never names the executor, and only `AgentChatState+Device.swift` runs commands.


## Operate

The Operate section runs a graph of agents (`Sources/AgentEngine/Operate`) in the agent process. They only request device commands; the app's `DeviceRequestHandler` (shared with the chat) validates, asks and runs them. Operate never reads a repository. The take-over click handler lives in `Views/Operate`, outside the audited mirror files, and calls only `OperateState`. See [docs/OPERATE.md](docs/OPERATE.md).
