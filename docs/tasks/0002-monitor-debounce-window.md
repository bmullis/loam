---
status: todo
type: AFK
created: 2026-04-26
parent_prd: docs/prds/0003-singleton-on-zenoh.md
blocked_by:
  - docs/tasks/0001-registry-monitor-primitive.md
---

## What to build

Extend `Loam.Registry.monitor/3` with a `:debounce_ms` option (default 0 stays as the no-debounce behavior shipped in slice 0001). When `:debounce_ms > 0`, an owned→vacant transition starts a timer; the `:name_vacant` notification fires only if the name remains vacant for the full window. If a new owner is observed within the window, the pending notification is suppressed. Cancellation must be safe under rapid owner churn.

This absorbs the "owner A unregisters, owner B registers 50ms later" peaceful-handoff case and prevents every singleton in the cluster from racing to take over during a normal handoff.

See parent PRD §Solution decision 2 for the semantic.

## Acceptance criteria

- [x] `:debounce_ms` option accepted by `monitor/3`; default 0 preserves slice 0001 behavior.
- [x] Peaceful handoff (unregister followed by register within `debounce_ms`) suppresses notification.
- [x] Hostile handoff (unregister with no replacement within window) fires notification exactly once.
- [x] Rapid churn (multiple owner transitions inside the window) does not produce duplicate or lost notifications; debounce timer is correctly canceled and rescheduled.
- [x] Watcher pid dying mid-debounce does not leak the timer.
- [x] Unit tests cover peaceful handoff, hostile handoff, churn, and watcher-death-mid-debounce.
- [x] Property test: "watcher receives exactly one `:name_vacant` per owned→vacant edge that exceeds the debounce window."
- [x] Decision journal entry written for "vacancy debounce window as default-on for Singleton consumers."

## User stories addressed

- User story 15
- User story 20a
