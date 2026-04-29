---
status: done
type: AFK
created: 2026-04-26
completed: 2026-04-28
parent_prd: docs/prds/0003-anchor-on-zenoh.md
blocked_by:
  - docs/tasks/0005-two-beam-happy-path-and-late-join.md
---

## What to build

Wire the owner-loss failover path: when the BEAM holding the anchor dies, surviving BEAMs receive `:name_vacant` from the Registry monitor (after the debounce window expires), race to register, and one wins. The dead BEAM's entries are evicted from local mirrors via PRD-0002's `:drop`-regime + heartbeat path; once the name vacates, the surviving anchors race using the same path as initial start.

Integration test (`@tag :peer_death`): two BEAMs running the anchor, kill the OS process of the owning BEAM, assert the surviving BEAM starts a fresh child within `vacancy_debounce_ms + heartbeat_miss_window + start_jitter_ms`, and a fresh BEAM rejoining can re-register without conflict.

Also covers the max-restarts-exhaustion failover case from slice 0004: when `LocalSup` gives up locally and the anchor unregisters, peers observe `:name_vacant` and one takes over.

See parent PRD §User Stories 23, 24.

## Acceptance criteria

- [x] `@tag :peer_death` integration test: kill owner BEAM's OS process; surviving BEAM starts a child within the documented bound; `lookup/2` on the survivor returns the new child pid. (`test/loam/anchor_peer_death_test.exs`)
- [x] Survivor's anchor remains alive and re-monitors after taking over; subsequent vacancy would be observed normally. (Implicit in the anchor state machine; max-restarts cross-Session test exercises another vacancy-then-takeover cycle.)
- [x] Max-restarts-exhaustion failover: induce crash loop on owner; owner's `LocalSup` gives up; owner unregisters; peer observes `:name_vacant` and takes over. (Cross-Session test in `anchor_integration_test.exs`.)
- [x] Eviction telemetry on the *original* owner is not expected (it's dead in `:peer_death`, in `:standby` for max-restarts case); telemetry on the new owner fires `[:loam, :anchor, :registered]` and `[:loam, :anchor, :child_started]` (verified by the survivor receiving `{:anchor_worker_started, child_pid}`).
- [x] Decision journal entry written for "owner-loss failover via Registry monitor + debounce."

## User stories addressed

- User story 23
- User story 24
