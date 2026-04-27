---
status: todo
type: AFK
created: 2026-04-26
parent_prd: docs/prds/0003-singleton-on-zenoh.md
blocked_by:
  - docs/tasks/0004-singleton-single-beam-tracer.md
---

## What to build

Cross-BEAM happy path: start `Loam.Singleton` on two BEAMs with the same `:registry` and `:name`. Exactly one BEAM ends up holding the child; the other observes the existing owner via Registry's snapshot bootstrap and stays in standby. A late-joining third BEAM behaves the same way: snapshot bootstrap shows the existing owner, no spurious start, no spurious eviction.

This slice exercises the steady-state semantic with no faults. Partition and peer-death cases come in slices 0006 and 0007.

The `start_jitter_ms` damps the boot-storm contention; some test runs will still hit a contended start that resolves via LWW, which is correct behavior — assert the *result* (exactly one owner), not the *path*.

See parent PRD §User Stories 2, 3, 5a, 21, 20b.

## Acceptance criteria

- [ ] Two-BEAM integration test: both BEAMs start the singleton with the same name; within `start_jitter_ms + vacancy_debounce_ms + 2 × heartbeat_interval`, exactly one BEAM is observed as owner from both sides via `Loam.Registry.lookup/2`.
- [ ] The non-owning BEAM has no live child (its `LocalSup` is not running a child).
- [ ] Late-join test: BEAMs A and B converge on A as owner; BEAM C joins; assert C observes A as owner via snapshot bootstrap, does not start its own child, and does not provoke an eviction.
- [ ] Tests run in default `mix test` (no special tag).
- [ ] Reuses the two-BEAM harness from PRD-0001/0002; no new test infrastructure beyond a singleton fixture child module.

## User stories addressed

- User story 2
- User story 3
- User story 5a
- User story 21
- User story 20b
