---
status: todo
type: AFK
created: 2026-04-26
parent_prd: docs/prds/0003-anchor-on-zenoh.md
blocked_by:
  - docs/tasks/0005-two-beam-happy-path-and-late-join.md
---

## What to build

Wire the eviction path: when this BEAM holds the anchor's name and receives `{:loam_registry, :evicted, name, winner_zid}` (per PRD-0002 LWW collision semantic), the `Server` calls `Supervisor.terminate_child/2` on its `LocalSup`, emits `[:loam, :anchor, :evicted]` telemetry with `reason: :lww_lost`, logs at `:info`, and returns to standby (still monitoring the name, ready to race on next vacancy).

Integration test: partition the network between two BEAMs running the anchor, assert each side independently runs a child during partition, heal, assert exactly one child survives per LWW, the loser's child is terminated cleanly (its `terminate/2` callback runs), `lookup/2` on both sides converges to the winner, eviction telemetry observed on the loser.

See parent PRD §Solution decisions 1, 5, 6 and §User Stories 4, 5, 6, 7, 11, 18, 22.

## Acceptance criteria

- [ ] On `{:loam_registry, :evicted, ...}`, the local child is terminated via `Supervisor.terminate_child/2` (which runs `terminate/2` if the child traps exits, subject to shutdown timeout).
- [ ] `[:loam, :anchor, :evicted]` telemetry fires with `reason: :lww_lost`, `local_zid`, `winner_zid` metadata.
- [ ] After eviction, the anchor remains running and re-monitors the name; subsequent vacancy triggers a fresh registration race.
- [ ] `@tag :partition` integration test: partition, both run, heal, exactly one survives, loser's child terminated, both sides converge on lookup.
- [ ] Test asserts `terminate/2` ran on the loser (e.g., fixture child writes a marker on terminate, test reads it).
- [ ] `Loam.Anchor` rejects unsupported config (`:transient`, `:temporary`, multi-child) with `{:error, ...}` per PRD §User Story 11.
- [ ] Decision journal entry written for "no fence between loser termination and winner liveness."

## User stories addressed

- User story 4
- User story 5
- User story 6
- User story 7
- User story 11
- User story 18
- User story 22
