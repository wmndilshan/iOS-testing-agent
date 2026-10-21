# Architecture Rules

Rules marked **[enforced]** are checked by tests in `Tests/AutonomousTestingAgentTests/Architecture/`
(`TrustedSpineAuditTests`, `ExecutionBoundaryFreezeTests`, `LayerDependencyTests`, `DriverOwnershipTests`, ...). The rest
are conventions for review.

## 0. Modules

The layers below are also separate SwiftPM modules, so the compiler enforces most of them (`ModuleGraphTests` pins the dependency lists):
`AgentCore` (Shared, Domain, Security, Observability, Application) depends on nothing; `AgentInfrastructure` and `AgentPresentation` depend on
`AgentCore` only; `AgentComposition` is the only module that depends on both; `AgentEngine` (case runner, agents, Operate) depends on core and
infrastructure; `CLI` depends on `AgentEngine` and `AgentGateway`; `AgentGateway` (the tools other agents call) depends on core, infrastructure and `TestCaseSources`, never on the engine or the UI; `AgentMCP` on the gateway only; `GUI` on presentation and composition. A declaration is `public` only when another module uses it.

## 1. Dependency direction

| Layer | May depend on |
| --- | --- |
| Shared | - |
| Domain | Shared |
| Security | Domain, Shared |
| Observability | Domain, Security, Shared |
| Application | Domain, Security, Observability, Shared |
| Infrastructure | Application (ports), Domain, Security, Observability, Shared |
| Presentation | Application, Domain, Observability, Security, Shared |
| App | Application, Domain, Infrastructure, Presentation, Security, Shared |

- The matrix is a ratchet **[enforced]**: adding an edge is a deliberate change to `LayerDependencyTests` and a note here.
- Domain and Security never mention `ToolRegistry`, drivers, `Process(`, `FileManager`, SwiftUI or XCTest. **[enforced]**
- Application never imports SwiftUI, uses `URLSession` or launches `Process()`. **[enforced]**
- SwiftUI is imported only in `AgentPresentation` and `GUI`. **[enforced]**
- Presentation never constructs concrete infrastructure. **[enforced]**
- `AutonomousTestingAgentApp` contains views only; it does not call drivers or `ToolRegistry`.
- `CodeIntelligence` is a separate target. It never imports `AgentCore`, and `AgentCore` never imports it. It cannot
  execute, approve, dispatch or use the network; its only process is read-only git. **[enforced]**

## 2. The trusted spine may not be bypassed

- `ScenarioStepDispatcher` is the only code that calls `toolRegistry.execute(_:authorization:)`, and it requires a
  `DispatchAuthorizer.Authorized` proof that only `DispatchAuthorizer` can create. **[enforced]**
- Approval is granted only by `approveCurrentStep(source:)`. The human source reads stdin in `requestSupervisorApproval`;
  the scripted `explicitAutomationPolicy` source exists at that one call site, is disclosed, and is never HITL evidence. **[enforced]**
- Recovery, security and observability code cannot approve or dispatch. **[enforced]**
- A model's output is data: a proposal goes through grounding, `TestIRValidator`, `TrustedActionValidator`, approval and
  authorization before anything runs. Mutating tools are never retried automatically. **[enforced]**
- A destructive step is never approved by the scripted policy; `DestructiveActionGate` sends it to a person unless the operator passed `--allow-destructive`. A denied or expired approval dispatches nothing and is recorded as a failure; an approval is single use and lives 120 s.
- Nothing launches `xcodebuild`; the only processes are the known sites listed in `ExecutionBoundaryFreezeTests`. **[enforced]**

The spine is exercised without any UI state in `ApprovalSpineTests` (proposal, approval, expiry, stale snapshot, validator, denial,
verification) and `DestructiveActionGateTests`.

## 3. Driver ownership

Application depends on `DeviceDriver`. `IDBDriver` is built only by `AppCompositionRoot`; the controller never constructs a
driver or registry. **[enforced]** (`DriverOwnershipTests`)

## 3a. Test case sources

`TestCaseSources` depends on nothing in this package and is never imported by `AgentCore`. AIO is one source among several; the
agent works on `TestCase` values only. Agent-side names do not mention a source (`CaseRunReport`, `StepSkill`).

## 4. Provider neutrality

Application names no LLM provider type. Gemini and DeepSeek wire models and error mapping live in `AgentInfrastructure/LLM`. **[enforced]**

## 5. Security code

`Security/` returns verdicts and never executes. Redaction has one policy (`SecretRedactor`, `LogRedactor`). Secrets never
reach logs, traces or test output. **[enforced]**

## 6. Composition and persistence

Persistent locations (`.skills`, `.runs`, `.artifacts`, and the `cases` / `steps` folders under them) are decided only in `AppCompositionRoot`. Tests never write to the
real stores.

## 7. Protocols, files and access

No new protocol, module or folder without a concrete need. Access is as tight as it can be.

## 8. Logging

Typed category, dotted lowercase event name, injected `AppLogger`, no secrets, no prompt or response text, no `print` in
AgentCore. See [docs/LOGGING_ARCHITECTURE.md](docs/LOGGING_ARCHITECTURE.md). **[enforced]** (`LoggingArchitectureTests`)

## 9. Tools and artifacts

A tool is one `ToolDescriptor` in `ToolCatalog`; read-only or mutating is decided there, never by the model. Files go
through `ArtifactStoring` and return an `ArtifactReference`. See [docs/TOOL_ARCHITECTURE.md](docs/TOOL_ARCHITECTURE.md).
