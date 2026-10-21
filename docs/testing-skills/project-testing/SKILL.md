---
name: project-testing
description: Test conventions for every test in this repository. Applies to all changes.
scope: project
directives:
  framework: swift-testing
  simulator-in-swift-test: forbidden
  shared-fakes: Tests/AutonomousTestingAgentTests/Support
---
## Structure
Tests are named suites (`@Suite("...") struct <Area>Tests`) with `@Test func test<Behavior>()`, placed in the
folder that mirrors the production area (`Workflow/`, `Security/`, ...). Extend an existing suite before creating one.

## Fakes and fixtures
Use the shared fakes in `Tests/AutonomousTestingAgentTests/Support/` (`ProductFixtures`, `RunHarness`, `TickClock`,
`AuthorizationFixture`, `SequentialMockLLMClient`, `MockNetworkTransport`, ...). Never copy a fake into a suite.
Locate the repository with `RepositoryRoot.url` and the source tree with `SourceTree`.

## Isolation
`swift test` must not start a simulator or `xcodebuild`, and must not touch the real `.skills/` or `.runs/`
directories; use temporary directories. Live simulator checks are manual CLI runs, never generated tests.

## Assertions
Assert the specific outcome (state, error case, invocation count), not just "no crash". Do not delete or weaken an
existing test to make a change pass.
