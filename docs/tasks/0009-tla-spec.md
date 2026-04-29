---
status: todo
type: HITL
created: 2026-04-26
parent_prd: docs/prds/0003-anchor-on-zenoh.md
blocked_by:
  - docs/tasks/0002-monitor-debounce-window.md
---

## What to build

TLA+ module under `docs/specs/0003-anchor-on-zenoh/` characterizing the anchor's eventual-uniqueness property and the monitor primitive's debounce semantics. Follows the convention established by `docs/specs/0002-registry-on-zenoh/`: module file, at least one model config, README explaining what the spec models and what it deliberately does not.

Two invariants are load-bearing and must be expressed:

- **EventualUniqueness**: `□◇ (∃ at-most-one BEAM owns name)` after network quiescence — the anchor converges to one live owner.
- **DebounceCorrectness**: a peaceful handoff (owner A unregisters and owner B registers within the debounce window) does not produce a `:name_vacant` event in any execution.

Spec authors are free to discover and add additional invariants; these two are the floor.

This is HITL because spec authoring is a load-bearing semantic exercise — modeling choices about what to abstract (e.g., does the spec model start jitter? heartbeat intervals? snapshot bootstrap?) are themselves design decisions worth journaling.

See parent PRD §Solution closing paragraph and §Shipped When item 10.

## Acceptance criteria

- [ ] `docs/specs/0003-anchor-on-zenoh/` directory created with module file, at least one `.cfg` model config, README.
- [ ] EventualUniqueness invariant expressed and checked in at least one model config.
- [ ] DebounceCorrectness invariant expressed and checked in at least one model config.
- [ ] README states which substrate properties from PRD-0001/0002 specs are inherited vs. re-modeled.
- [ ] Decision journal entry written summarizing modeling choices (what was abstracted, why).
- [ ] Model checker run completes for chosen state-space bound; results recorded in README.

## User stories addressed

- User story 28
