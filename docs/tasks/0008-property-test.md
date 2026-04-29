---
status: todo
type: AFK
created: 2026-04-26
parent_prd: docs/prds/0003-anchor-on-zenoh.md
blocked_by:
  - docs/tasks/0006-partition-lww-eviction.md
  - docs/tasks/0007-peer-death-failover.md
---

## What to build

StreamData property test that generates sequences of `{anchor_start, anchor_stop, child_crash, partition, heal, peer_kill}` events across two BEAMs. After each generated sequence, the test waits for quiescence and asserts the convergence invariants:

- Cluster eventually has exactly one live owner of the name (or zero, if the sequence ends with all owners dead and no one running).
- No two distinct pids hold the name simultaneously after convergence.
- Every eviction is accompanied by a `[:loam, :anchor, :evicted]` telemetry event on the losing BEAM.

This is the highest-value cross-cutting test; it stresses the interaction between Registry monitor, debounce, jitter, LWW, and peer-loss eviction in combinations the targeted tests don't cover.

See parent PRD §User Story 25 and existing prior art in `test/loam/registry/property_test.exs`.

## Acceptance criteria

- [ ] Property test runs in default `mix test` with a reasonable shrinking budget.
- [ ] Generators produce all six event kinds with non-trivial mixing.
- [ ] Quiescence detection follows the pattern from `test/loam/registry/property_test.exs` (no fixed sleeps).
- [ ] Failures shrink to a minimal counterexample sequence.
- [ ] Convergence invariants asserted as named properties so failure messages are readable.

## User stories addressed

- User story 25
