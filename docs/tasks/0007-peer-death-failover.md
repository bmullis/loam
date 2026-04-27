---
status: todo
type: AFK
created: 2026-04-26
parent_prd: docs/prds/0003-singleton-on-zenoh.md
blocked_by:
  - docs/tasks/0005-two-beam-happy-path-and-late-join.md
---

## What to build

Wire the owner-loss failover path: when the BEAM holding the singleton dies, surviving BEAMs receive `:name_vacant` from the Registry monitor (after the debounce window expires), race to register, and one wins. The dead BEAM's entries are evicted from local mirrors via PRD-0002's `:drop`-regime + heartbeat path; once the name vacates, the surviving singletons race using the same path as initial start.

Integration test (`@tag :peer_death`): two BEAMs running the singleton, kill the OS process of the owning BEAM, assert the surviving BEAM starts a fresh child within `vacancy_debounce_ms + heartbeat_miss_window + start_jitter_ms`, and a fresh BEAM rejoining can re-register without conflict.

Also covers the max-restarts-exhaustion failover case from slice 0004: when `LocalSup` gives up locally and the singleton unregisters, peers observe `:name_vacant` and one takes over.

See parent PRD §User Stories 23, 24.

## Acceptance criteria

- [ ] `@tag :peer_death` integration test: kill owner BEAM's OS process; surviving BEAM starts a child within the documented bound; `lookup/2` on the survivor returns the new child pid.
- [ ] Fresh BEAM joining after a peer-death failover can re-register without conflict if the survivor later vacates.
- [ ] Max-restarts-exhaustion failover: induce crash loop on owner; owner's `LocalSup` gives up; owner unregisters; peer observes `:name_vacant` and takes over.
- [ ] Eviction telemetry on the *original* owner is not expected (it's dead); telemetry on the new owner fires `[:loam, :singleton, :registered]` and `[:loam, :singleton, :child_started]`.
- [ ] Decision journal entry written for "owner-loss failover via Registry monitor + debounce."

## User stories addressed

- User story 23
- User story 24
