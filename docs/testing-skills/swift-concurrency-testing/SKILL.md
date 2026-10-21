---
name: swift-concurrency-testing
description: Testing actors, async functions, cancellation and task lifetimes deterministically.
scope: technology
applies-to:
  technologies: [swift-concurrency]
  categories: [concurrency]
directives:
  waiting: injected clock and explicit gates; no Task.sleep in new tests
---
## Determinism
Control interleavings with the shared `AsyncGate`, `Rendezvous` and `ConcurrencyProbe` helpers and time with
`TestClock` / `TickClock`. Do not rely on sleeps or wall-clock timing.

## Cancellation
<!-- when: categories=concurrency -->
Cancel the task at a known suspension point, then assert that no effect happened afterwards and that state is
consistent. Spawned tasks must be awaited or cancelled before the test ends.

## Actor reentrancy
<!-- when: traits=concurrency -->
State read before an `await` may be stale after it. Test two overlapping calls and assert the final state.
