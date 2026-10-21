---
name: security-authorization-testing
description: Testing approval, authorization and dispatch gates (fail-closed security spine).
scope: module
applies-to:
  paths: [Sources/AgentCore/Security/**]
  symbols: [DispatchAuthorizer, ApprovalPolicy, ScenarioStepDispatcher]
  traits: [authorization, security]
directives:
  failure-mode: fail-closed
---
## Required cases
Each gate needs: a valid authorization accepted for exactly its scope; expired (advance the injected clock past the
TTL from `ApprovalPolicy`, never a hard-coded value); denied and pending; stale observation or changed target;
replay of a consumed authorization.

## Assertions
Assert the rejection reason and that the protected effect (driver or tool registry) was never invoked. A test
must not construct an authorization proof directly; go through the public approval path (`AuthorizationFixture`).

## Secrets
<!-- when: traits=security -->
Secrets never appear in logs, traces or errors; assert redaction with `SecretRedactor` output, not by printing.
