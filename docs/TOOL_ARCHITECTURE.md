# Tool Architecture

Status is marked **CURRENT** (implemented and tested), **PLANNED** (designed, not built) or **NOT IMPLEMENTED**.

## Trust boundaries

| Trusted (code and static data we own) | Untrusted (never authority) |
| --- | --- |
| `ToolCatalog` descriptors and schemas | LLM output (proposals, tool calls) |
| `TrustedActionValidator`, `ProposalAdmission`, `DispatchAuthorizer`, `ApprovalPolicy` | Screenshots and accessibility text |
| `ScenarioExecutionController`, `ScenarioStepDispatcher`, `ToolRegistry` | Design-tool (Figma) and tracker (Jira) content |
| `ScenarioVerificationService` | Artifacts, run history, logs |

Rule: nothing untrusted can approve, authorize, dispatch or verify. A tool definition grants no execution
authority by itself, and an external tool's response is data, never a command.

## Pipeline (CURRENT)

```
ToolCatalog ─► ToolResolver ─► authorization ─► ToolRegistry ─► IOSToolAdapter ─► IOSActionDecoder ─► IOSAction (typed)
 (descriptor)   (lookup +       (mutating: proof;   (orchestrates)   (no gesture logic)  (args -> typed)
                 schema check)    read-only: none)                                                            │
                                                                                                             ▼
                          ToolResult ◄── IOSActionResult ◄── IOSInteractionExecutor ─► IOSPerformable ─► DeviceDriver
                        (stamped, artifact refs)  (standardized)   (logging, timing, classification)   (one struct per capability)
```

| Stage | Type | Responsibility |
| --- | --- | --- |
| Definition | `ToolDescriptor` | name, version, category, platform, risk, summary, input schema; `requiresApproval` derived from risk |
| Catalog | `ToolCatalog` | the only place tools are declared; also generates the LLM-facing `LLMToolDefinition`s so what the model sees is what is enforced |
| Resolution | `ToolResolver` + `ToolInputValidator` | unknown tool -> `toolNotFound`; unknown/missing/mistyped/out-of-set fields -> `invalidArguments` |
| Authorization | `DispatchAuthorizer.Authorized` (proof) | required by `ToolRegistry.execute`; covers exactly this tool and these arguments; only `DispatchAuthorizer` can create one |
| Execution | `ToolRegistry` (`executeReadOnly`, `execute(_:authorization:)`) | orchestration only: resolve, enforce classification/authorization, delegate, stamp the result. No gesture code, no per-tool switch (architecture-tested) |
| Typed action | `IOSAction` (Domain/Interaction) | closed enum of typed actions (`TapAction`, `SwipeAction`, `TypeTextAction`, ...). No dictionaries, frames or coordinates. `ElementTarget` is a *model-suggested* reference (snapshot + element id); trust comes from the current snapshot |
| Decoding | `IOSActionDecoder` | one small decoder per tool: validated arguments -> typed action (same validation messages as before) |
| Capability execution | `IOSInteractionExecutor` + `IOSPerformable` performers | one performer per action in `Application/Tools/iOS/Performers`; the only place driver gesture methods are called; logs `ios.action.*`, classifies failures, times the action |
| Waiting | `ConditionWaiter` | the single bounded polling primitive (max 30 polls, injected clock, no bare sleeps) |
| Standard result | `IOSActionResult` | executionID, toolName, actionType, start/finish/duration, success, `ActionFailure` (neutral `ActionFailureKind`), evidence (artifact references), `postObservationID`, non-sensitive diagnostics |
| Result | `ToolResult` | status, summary, observation, payload, `toolName`, `executionID`, `durationSeconds`, `failure` (neutral `ErrorCategory`, retryable flag), `artifacts` (references only) |

### Two entry points, no third

- `executeReadOnly(toolCall:)`: read-only tools only (per the static catalog). A mutating tool throws
  `authorizationRequired` whatever its arguments claim. It currently has no production caller.
- `execute(_:authorization:)`: any catalog tool, but only with a proof that matches. The only caller is
  `ScenarioStepDispatcher`. There is no generic, synchronous or provider-typed execute (architecture-tested).

### Schema policy

- **At admission** (`ProposalAdmission`, before a human is asked): fields the tool does not declare are *dropped*, so
  they never appear in the approval request or authorization; missing or malformed declared fields reject the
  proposal.
- **At execution** (`ToolRegistry`): unknown fields are *rejected*. Defense in depth.

### Tools today (CURRENT, 15)

| Tool | Category | Risk | Platform |
| --- | --- | --- | --- |
| `get_project_info` | project | read-only | host |
| `get_app_state`, `get_accessibility_tree`, `get_element_details`, `inspect_elements` | observation | read-only | ios |
| `wait_for_element` | synchronization | read-only | ios |
| `capture_screenshot` | capture | read-only | ios |
| `tap_element`, `double_tap_element`, `long_press_element`, `swipe`, `drag_and_drop`, `type_text`, `clear_text`, `scroll` | interaction | mutating | ios |

Each descriptor carries an honest `LiveAvailability` (`LIVE_VERIFIED`, `IMPLEMENTED_NOT_LIVE_VERIFIED`, `SIMULATION_ONLY`,
`NOT_APPLICABLE`), a `canonicalName`, an output contract and derived rules (`requiresApproval`, `requiresFreshObservationAfter`
for mutating tools). Only `tap_element` and `get_accessibility_tree` are `LIVE_VERIFIED` (a test enforces the allow-list);
`SIMULATION_ONLY` tools are refused by the live driver with `unsupportedCapability`. See `IOS_CAPABILITY_MATRIX.md`.

Tool names keep their current form (`tap_element`) for models and scenarios. The namespaced form (`ios.tap`, `host.project_info`)
is carried as `canonicalName` metadata. **Compatibility strategy (staged):** (1) metadata only, and resolution deliberately does *not*
accept the canonical names (tested), so no alias can differ between the approval, the authorization proof and the call;
(2) later, accept canonical names at the proposal boundary and normalize to one name before admission, authorization and execution;
(3) finally flip the model-facing names. Namespaces for future integrations (`figma.*`, `jira.*`) are **PLANNED**.

## Typed inputs (CURRENT)

A tool call is validated against its descriptor, then decoded into exactly one `IOSAction` (23 typed cases). Nothing
below the decoder sees a raw argument dictionary. Fourteen actions have tools; nine are *modeled only*
(`KeyPress`, `DismissKeyboard`, `DismissOverlay`, `Back`, `SelectTab`, `SelectPickerValue`, `Launch`, `Terminate`,
`Activate`): they have no descriptor and their performer throws `unsupportedCapability`.

Deliberate differences from the wish list: `SwipeAction` has no duration (the driver API exposes none, so none is
invented); `TypeTextAction` has no `clearBeforeTyping` (clearing is its own authorized `ios.clear_text`, so one approval
never covers two mutations); typed text is redacted from descriptions, logs and results.

## Errors

Action failures use one taxonomy, `ActionFailureKind` (targetNotFound, targetNotHittable, targetDisabled, staleSnapshot,
invalidArguments, unsupportedCapability, timeout, keyboardUnavailable, overlayNotFound, gestureFailed, driverFailure,
simulatorFailure, xctestFailure, verificationFailed, authorizationFailed, observationFailed, noProgress, cancelled),
mapped from `DriverError`/`ToolRegistryError`/cancellation by `ActionFailureKind.of`, and each kind maps to an `ErrorCategory`.
Some kinds (`keyboardUnavailable`, `overlayNotFound`, `gestureFailed`, `noProgress`, `verificationFailed`) are reserved for
capabilities not yet implemented; `verificationFailed` is produced by `ScenarioVerificationService`, not the executor.

`ErrorCategory` (Domain) is the neutral taxonomy: validation, authorization, approval, observation, targetNotFound,
targetNotHittable, toolUnavailable, execution, xctest, simulator, network, llm, parsing, verification, timeout,
persistence, security, configuration. Error types adopt `ErrorCategoryProviding` with exhaustive mappings
(`DriverError`, `ToolRegistryError`, `LLMProposalPipelineError`,
`SkillMemoryError`, `ArtifactStoreError`, and in Infrastructure `LLMError`, `LLMNetworkError`, `UITestError`,
`ConfigError`). Messages are redacted before leaving the process. `ErrorCategory.of(_:)` falls back to `execution`.
`ErrorCategory` is used by `ToolResult.failure`; wiring it into logs and traces everywhere is **PLANNED**
(`FailureClass` and `LLMFailureKind` remain the classifiers used by recovery and LLM logging today).

## Artifacts (CURRENT; screenshots use them)

`Artifact` (id, kind, source, store-relative reference, SHA-256 checksum, size, time, association to
run/scenario/step/test case, metadata) with `ArtifactStoring` (Application port) and `FileArtifactStore`
(Infrastructure). Ids are UUIDs and references are file names, so nothing can traverse out of the store; reads
verify the checksum; source and metadata are redacted before storage. Tools return `ArtifactReference`s instead of
embedding screenshots or reports. The store location is chosen by `AppCompositionRoot` (`.artifacts/`).
`ios.screenshot` stores the image through `ArtifactStoring` (production app and live CLI runs pass a real store; tests and previews pass none and get the driver path back) and returns an `ArtifactReference` with run/scenario/step association. xcresult and other evidence do not use the store yet (**PLANNED**).

## External integrations (PLANNED, NOT IMPLEMENTED)

Nothing here exists in code; the architecture is prepared for it.

```
SwiftUI / Application ──► port (Application/Ports) ──► adapter (Infrastructure) ──► external system
```

| Future capability | Application port (planned) | Adapter (planned) |
| --- | --- | --- |
| Figma search/file/frame/node/export | `DesignSourceClient` | `FigmaAPIClient` |
| Issue tracker | `IssueTrackerClient` | `JiraClient` |
| Test management | `TestManagementClient` | `JiraAIOClient` |
| Codebase analysis | `CodeAnalyzing` | static analysis adapter |

Constraints they must respect (and that the existing architecture tests already enforce for Infrastructure):
Application/Domain import no URLSession or vendor SDK; adapters cannot reference the controller, dispatcher,
authorizer, approval types or proposal admission; SwiftUI views cannot call providers; fetched content is untrusted
data; downloaded files are stored as artifacts associated with `scenarioID`/`testCaseID`/`runID`/`stepID`; credentials
belong to Infrastructure configuration and are redacted from logs.

Test generation from a codebase, when built: static analysis -> UI capability model -> LLM *proposes* test cases ->
deterministic validation -> human review -> `TestCase` model. Publishing to Jira/AIO is a separate capability
requiring explicit authorization; the LLM never publishes. Domain models `TestCase`, `TestStep`, `ExpectedResult`,
`TestData`, `TestCaseSource`, `TestCaseStatus`, `TestCaseEvidence` are **NOT IMPLEMENTED** (they belong in Domain,
independent of Jira).

## Adding a tool (checklist)

1. Add one `ToolDescriptor` to `ToolCatalog` (risk, category, platform, live availability, strict input fields, output contract).
2. For an iOS capability: add a typed action in `Domain/Interaction`, one decoder entry, one performer in `Tools/iOS/Performers`,
   and one line in `IOSAction.performer`. For an external system: a port plus an Infrastructure adapter. Never a case in `ToolRegistry`.
3. If mutating: it must run only through the dispatcher with a proof; a scenario step must use it.
4. Add positive, negative, stale/invalid-input and authorization tests.
5. Do not touch `DispatchAuthorizer`, `ApprovalPolicy` or `ProposalAdmission` to make it work.

## Trusted scenario arguments and the fixture runner

A `ScenarioStep` may carry `trustedArguments` (direction, duration, fixture text) and, for drag and drop, a trusted `destination` locator. Admission
(`ProposalAdmission`) builds the approval's arguments from these: a proposal that supplies any of them is rejected, the drag destination must resolve
to exactly one element of the fresh snapshot and differ from the source, and typed text appears only as `<REDACTED_TEXT>` in fingerprints, traces and
output. `FixtureScenarioCatalog` holds the scenarios that run against the dedicated fixture app; the CLI `--fixture-scenario=<ID>` runner uses the same
spine as the closed-loop runner (`handleProposal` → human approval → `dispatchCurrentStep`) with a scripted proposal instead of an LLM.
`RunTraceEvent` carries `executionID`, `toolName` and `actionType` for the dispatch events (opaque IDs and catalog names only).
