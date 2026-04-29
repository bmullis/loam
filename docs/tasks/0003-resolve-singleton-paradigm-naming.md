---
status: done
type: HITL
created: 2026-04-26
completed: 2026-04-28
parent_prd: docs/prds/0003-anchor-on-zenoh.md
---

**Decision: `Loam.Anchor`.** Reasoning recorded in `docs/journal/2026-04-26-singleton-paradigm-naming-question.md` (promoted to `kind: decision`). PRD slug, spec directory, downstream task files, telemetry namespace, and module names all updated.

## What to build

Resolve the open naming question captured in `docs/journal/2026-04-26-singleton-paradigm-naming-question.md`. The PRD ships with `Loam.Singleton` as a placeholder; this slice lands the final module name (and slug, if changed) before code merges in slice 0004.

The question is bigger than one module: future loam primitives in this family (failover groups, leader-elected work distribution, fenced singletons) want a vocabulary that composes with this one. The naming choice should be defensible against the next two phases of work, not just this one.

This is HITL because it is an interview/decision moment, not autonomous work. Brian's seed candidates were "Isotope" and "Isolate"; adjacent options enumerated in the journal entry.

## Acceptance criteria

- [x] Final module name selected and recorded.
- [x] Naming-question journal entry promoted to `kind: decision` with the reasoning behind the chosen name.
- [x] Parent PRD updated: `Loam.Singleton` placeholder replaced throughout, slug renamed if applicable.
- [x] Downstream task files (slices 0004+) updated with the chosen name.
- [x] If the slug changes, related TLA+ spec directory name is also updated.

## User stories addressed

- (frames module name for slices 0004+; no direct user-story coverage)
