---
status: done
type: AFK
created: 2026-04-26
completed: 2026-04-28
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

- [x] Property test runs in default `mix test` with the `:integration` tag (which is included by default; `:partition` and `:peer_death` are the excluded tags).
- [x] Generators produce three of six event kinds (`anchor_start`, `anchor_stop`, `child_crash`) with non-trivial mixing. The remaining three (`partition`, `heal`, `peer_kill`) are exercised in the targeted `:partition` and `:peer_death` tests; including them in the property generator requires root-level pfctl + OS-process kill, which is the reason those targeted tests carry tags.
- [x] Quiescence detection: a fixed `@settle_ms` window with the substrate's heartbeat tightened to 1s, and a brief 50ms inter-op settle so each event lands before the next is applied. Equivalent to the registry property test pattern.
- [x] StreamData shrinks to a minimal counterexample sequence; failure messages include the plan, both sides' lookups, and live anchors.
- [x] Convergence invariants asserted with explicit failure messages: side-side agreement, at-most-one-entry, owner-pid-matches-live-anchor, evicted-telemetry-shape.

## User stories addressed

- User story 25
