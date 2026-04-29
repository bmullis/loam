---
status: done
type: AFK
created: 2026-04-26
completed: 2026-04-27
parent_prd: docs/prds/0003-anchor-on-zenoh.md
---

## What to build

Add `Loam.Registry.monitor/3` and `Loam.Registry.demonitor/2` to the Registry's public surface, with `:debounce_ms` defaulting to 0 (immediate fire). The watcher's calling pid receives `{:loam_registry, :name_vacant, registry, name}` on every owned→vacant transition observed by the local mirror, regardless of cause (local unregister, remote unregister, peer-loss eviction, LWW eviction of the last claimant). Watchers are auto-removed when the watcher pid dies.

This is the deep module that future loam primitives (Anchor, failover groups, leader election) consume. Debounce is added in slice 0002 — this slice ships the immediate-fire path only.

See parent PRD §Solution decision 2 and §Implementation Decisions for module shape.

## Acceptance criteria

- [x] `Loam.Registry.monitor(registry, name, opts \\ [])` returns `{:ok, ref}`.
- [x] `Loam.Registry.demonitor(registry, ref)` returns `:ok` and is idempotent on unknown refs.
- [x] `:name_vacant` fires on every owned→vacant transition path: local unregister, remote unregister, peer-loss eviction, LWW eviction of the last claimant.
- [x] `:name_vacant` does not fire on vacant→owned, owned→owned (same owner), or while the watcher is registered before any transition occurs.
- [x] Watcher entry is removed when the watcher pid dies (Registry monitors it).
- [x] Unit tests cover every transition path that should and should not fire `:name_vacant`.
- [x] Decision journal entry written for "Registry monitor as deep module vs. polling lookup."
- [x] Public API documented in moduledoc; types specced.

## User stories addressed

- User story 12
- User story 13
- User story 14
- User story 20
