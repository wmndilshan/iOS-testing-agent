# Test Planning Architecture (CodeIntelligence)

`CodeIntelligence` turns a code change into the smallest context a model needs to plan tests, plus a reviewable,
executable test plan. Static analysis answers *what changed, who depends on it, which tests exist*; the model is only
asked *what the expected behavior is*. The target is read-only: it never runs tests, calls a model or the network,
touches a simulator, or reaches the trusted execution spine.

```
ChangeSource (git HEAD vs working tree | baseline snapshot | explicit files)
  -> ChangeAnalyzer        ChangeSet: files, symbols, aspects, added/removed branch conditions, API changes
  -> RepositoryScanner     ASTIndex (SwiftSyntax, parallel, content-hash cache)
  -> SymbolGraph           reference edges (strong / weak), protocol implementations
  -> ImpactAnalyzer        per-symbol slice: direct / indirect / transitive callers, tests reached
  -> TestIndexer           tests, framework, assertions, mocks, fixtures, symbol <-> test map, conventions
  -> TraitDetector         behavior traits with evidence (throwing, async, persistence, authorization, ...)
  -> TestGapAnalyzer       required behaviors per trait + new branches; covered / unverified / missing
  -> RiskClassifier        LOW..CRITICAL with factors and floor rules
  -> SkillResolver         applicable SKILL.md sections by precedence; conflicts recorded
  -> ContextPackBuilder    tiered, budgeted context for the model
  -> TestSpecificationDrafter -> TestSpecification (human-readable, <TBD> where reasoning is needed)
  -> [model refines via TestGenerationRequest / TestGenerationResponse, gated by TestSpecificationValidator]
  -> InstructionCompiler   ExecutableTestInstruction (source-free: setup, actions and assertions as data)
```

Run it: `swift run AutonomousTestingAgent --plan-tests [--base=HEAD | --baseline-dir=<dir> | --files=a,b] [--tier=0-4]
[--budget=<tokens>] [--depth=<n>] [--include-unverified] [--out=<dir>] [--format=json]`. With `--out`, it writes
`plan.json`, `context.md` (what the model sees), `specs.md` (what a reviewer reads), `instructions.json` and
`llm-request.json`. The index cache lives in `.build/code-intelligence/`.

## Determinism and trust

- Same repository state and configuration give byte-identical plans (timings excepted); tested.
- Symbol IDs are `Module.Type.member(label:)`, independent of position; overloads get parameter types.
- Resolution is syntactic (no type checker). An edge is **strong** only when the receiver narrows it (implicit self,
  a type qualifier, a parameter/local/stored property with a written type) or the name is unique; otherwise **weak**.
  Default impact uses strong edges only; `ImpactConfiguration.expanded()` adds weak edges and one layer.
- Coverage is claimed only with evidence (the test's own name, `#expect(throws:)`); a test that merely references a
  symbol is `unverified`, never `covered`. New branch conditions are always `missing` unless a test changed with them.
- Model output is untrusted: a refinement may fill inputs and expectations, but cannot change id, target, behavior,
  lower risk, drop a live/approval gate, self-approve, or embed source code. Operation names must be identifiers.
- Only `GitCommandRunner` launches a process: `/usr/bin/git` with allow-listed read-only subcommands, argv only,
  `GIT_OPTIONAL_LOCKS=0`, no external diff/textconv, bounded by a timeout.
- Source slices (tier 3+) are bounded and redacted for credential-looking literals. Hidden directories (build
  output, VCS, run/skill/log stores), generated files and `.xcresult` bundles are never read.

## Context tiers

| Tier | Adds | Chosen when |
| --- | --- | --- |
| 0 metadata | summary, symbol IDs, risk, categories | docs-only / tests-only change |
| 1 signatures | signatures, AST facts, traits, required behaviors, skill sections | signature/attribute-only change |
| 2 neighborhood | callers with paths, related tests, conventions | logic change in LOW/MEDIUM code |
| 3 source slices | changed lines of changed declarations, one test to follow | logic change in HIGH/CRITICAL code, new symbols |
| 4 full files | whole changed production files | only on explicit escalation |

Over budget, content is dropped in a fixed order (transitive callers, test pattern, generic/technology skills, extra
slices, extra tests, caller signatures, all slices, module skills), each recorded in `omissions`; if the tier still
does not fit, the builder falls back one tier. The model can reply `{"escalate": "..."}` to get the next tier.

## SKILL.md

Testing skills live in `docs/testing-skills/<name>/SKILL.md` (any non-hidden `SKILL.md` in the repository is found).
Frontmatter: `name`, `description`, `scope` (`project` > `module` > `technology` > `generic`), `applies-to`
(`paths` globs, `modules`, `symbols`, `technologies`, `categories`, `traits`) and `directives` (machine-checkable
key/values). A `<!-- when: categories=...; traits=... -->` line under a `## ` heading limits that section. Conflicting
directives resolve by precedence and are recorded; a conflict at the same precedence blocks every instruction
(`blockedOnSkillConflict`) until a human resolves it. A project skill with no `applies-to` applies everywhere.

## Known limits

- No type checker: calls through untyped locals, chained members or generic receivers resolve by name (weak or dropped).
- Coverage is by reference and name evidence, not by execution; there is no line coverage input yet.
- Trait detection is keyword- and fact-based; every trait carries its evidence so a reviewer can reject it.
- Snapshot/UI categories are skipped (no infrastructure in this repository); live simulator behaviors are planned
  as `liveRequired` specs for manual CLI runs, never generated as `swift test` tests.
- The model call itself is not part of this target. Execution and evidence are in `AgentCore`: a planned live case is turned into a
  `TestCase` (by the agents or by hand) and run through the idb case runner.
