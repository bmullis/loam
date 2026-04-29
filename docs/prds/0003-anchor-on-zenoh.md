---
id: 0003
slug: anchor-on-zenoh
status: draft
date: 2026-04-26
phase: 3
related:
  - docs/prds/0001-phoenix-pubsub-adapter.md
  - docs/prds/0002-registry-on-zenoh.md
  - docs/specs/0001-phoenix-pubsub-adapter/
  - docs/specs/0002-registry-on-zenoh/
---

# Anchor on Zenoh

## Problem Statement

Elixir's `Supervisor` restarts a child process when it crashes, on a single BEAM. The "I want exactly one of these processes alive in my cluster, and if its node dies I want another node to start a fresh one" pattern is not in the standard library. The community's answers — `:global` + a named GenServer, `Horde.DynamicSupervisor` in singleton mode, `Swarm`, hand-rolled leader election over `:pg` — each stake out a different position on consensus, partition behavior, and what "exactly one" means when the network is degraded.

PRD-0002 shipped `Loam.Registry`: a cluster-wide name resolves to a pid, eventually consistent, with Last-Writer-Wins conflict resolution on partition heal, peer-loss eviction via the underlying PubSub `:drop` regime, and a `{:loam_registry, :evicted, name, winner_zid}` notification to the losing pid on LWW collision. That is a *registration* primitive: it tells you whether a name is claimed and by whom. It does not, by itself, ensure the named process exists. If the BEAM that registered the name dies, the name simply vacates from the local mirrors of every other BEAM; nothing starts a replacement.

Phase 3 turns that registration primitive into a *liveness* primitive. The question this PRD answers: **what do the semantics of a minimal distributed singleton look like when built on the PRD-0002 Registry, and what is the smallest working artifact that forces the load-bearing semantic decisions to be made in public?**

This is Phase 3 of loam. PRD-0001 (PubSub adapter) and PRD-0002 (Registry) are its substrate. The semantic referents established there — node = ZID, eventual delivery + `:drop` regime, ETF wire format with versioned envelope, LWW conflict resolution, opaque keyexpr encoding, local-mirror lookup — are inherited. This PRD only relitigates a question if Phase 3's semantic genuinely differs.

## Solution

A library module, `Loam.Anchor`, exposes a `child_spec/1`-shaped API that an application's supervision tree can mount. Each `Loam.Anchor` instance holds a *name* (any Erlang term, scoped to a `Loam.Registry` instance) and a *child spec* (the standard Elixir child-spec shape: `{module, args}` or a map). The contract: across all BEAMs in the cluster running this same `Loam.Anchor` configuration, there should be exactly one live instance of that child process, modulo eventual consistency.

The slice is intentionally narrow. One child spec per anchor instance. `:permanent` restart semantics only — if the child crashes locally, restart it; if the owning BEAM dies, some other BEAM starts a fresh one. No `:one_for_all`, `:rest_for_one`, `:transient`, `:temporary`. No state handoff: every restart is cold via the child spec. No general distributed-supervisor surface; multiple anchors compose by mounting multiple `Loam.Anchor` instances.

The semantic model the anchor presents, in one sentence, is: **a named child process is eventually alive on exactly one BEAM in the cluster; during partition each side independently runs a copy; on heal the LWW loser's copy is terminated.** Users of `Loam.Anchor` are not promised more; they are, crucially, not promised less either. Strong consensus, fenced singletons, state handoff, and CRDT-shaped split-brain merging are future PRDs.

Seven load-bearing design decisions are fixed by this PRD. Each gets a corresponding entry in the design journal recording why:

1. **Free-for-all start with jitter, LWW resolution.** Every BEAM running this `Loam.Anchor` instance attempts to start the child locally and register its pid in `Loam.Registry`. To damp the boot-storm case (N-node cluster startup means N starts and N-1 evictions), each BEAM waits a uniform random `[0, start_jitter_ms]` before its first registration attempt. Default jitter is 500ms; configurable per instance. Concurrent claims that survive the jitter are resolved by Registry's Lamport+ZID LWW comparator. The losing side receives `{:loam_registry, :evicted, name, winner_zid}` on its child pid (which `Loam.Anchor` has monitored) and terminates the orphaned child cleanly. The jitter does not change the semantic — partition-induced double-claims still happen and still resolve via LWW — it only smooths the steady-state boot case. No election protocol, no membership view, no consensus round. The substrate's eventual-consistency story is the anchor's eventual-consistency story.

2. **Owner-loss detection rides a new Registry monitor API, with a debounce window.** `Loam.Registry.monitor(registry, name)` is added in this PRD's scope (extending PRD-0002's surface). It registers the calling pid as a watcher for `name` and delivers `{:loam_registry, :name_vacant, registry, name}` whenever the local mirror transitions from "name has a live owner" to "name has no owner" (whether by local unregister, remote unregister, peer-loss eviction, or LWW eviction of the last claimant) **and remains vacant for at least `vacancy_debounce_ms`**. The debounce window absorbs the owned-by-A → briefly-vacant → owned-by-B handoff case, where A's unregister and B's register arrive as separate Zenoh messages with non-zero gap. Without debounce every peaceful handoff would trigger every anchor on every BEAM to race to take over for the duration of the gap. Default debounce is 1 second (~one heartbeat interval); configurable. `Loam.Anchor` uses the debounced notification to detect that a replacement should be started and races to register, same as initial start. Polling `lookup/2` is rejected — the monitor primitive is a deeper module, useful to future phases (failover groups, leader-elected work distribution, etc.) that need the same notification.

3. **`:permanent` only. No restart strategy taxonomy.** A `Loam.Anchor` instance owns one child spec. If the local child crashes, restart it (subject to a backoff). If the BEAM holding the anchor dies, a peer's `:name_vacant` notification triggers a fresh start there. There is no `:transient` (don't restart on normal exit) or `:temporary` (don't restart at all) — those would invite "is the anchor supposed to be alive right now?" ambiguity that this PRD declines to answer. Users who want non-`:permanent` semantics use a regular `Supervisor` and don't need a distributed singleton.

4. **Local restart uses a standard `Supervisor` under the hood.** Each `Loam.Anchor` instance, while it holds the name, runs the child under a `Supervisor` with `:one_for_one` and `:permanent`. Local crash semantics (max-restarts, max-seconds) are inherited from `Supervisor` and exposed in `Loam.Anchor`'s config. This keeps the local crash story boring and reuses OTP machinery that already exists.

5. **No state handoff. `terminate/2` runs on eviction.** When LWW evicts a side, that side's child is terminated via `Supervisor.terminate_child/2`, which runs the child's `terminate/2` callback if the child traps exits, subject to the supervisor's shutdown timeout (configurable per child spec, default 5s). The winner's child starts cold from its child spec. There is no in-band state transfer between losing and winning BEAMs — `terminate/2` is the application's hook for whatever flush-to-disk, send-to-database, or post-handoff-message behavior it wants. Applications that need synchronous state continuity persist it externally and rebuild from that store on the new owner. Documentation must be loud about this: `Loam.Anchor` is for stateless workloads, or workloads where externalized state plus a `terminate/2` flush is acceptable. A future PRD may add a fenced handoff primitive; this PRD declines.

6. **Termination on eviction is observable.** The losing side terminates the child but also emits a telemetry event (`[:loam, :anchor, :evicted]`) and logs at `:info`. Application code that wants to react to eviction (e.g., to re-enqueue work the orphaned process was about to do) attaches to the telemetry event. This is the lightest possible "callback" surface and keeps `Loam.Anchor`'s public API small.

7. **Anchor owns its `Loam.Registry` instance reference, not a Registry of its own.** `Loam.Anchor` is configured with a `:registry` option naming the `Loam.Registry` instance to claim names in. Multiple anchors can share one Registry. This keeps the anchor orthogonal to the Registry's session-ownership story and lets operators decide whether `loam/reg/...` and `loam/anchor/...` traffic share a session. There is no `loam/anchor/...` keyexpr namespace at all — the anchor is a *consumer* of Registry, not a peer publisher.

This PRD also extends the `docs/specs/NNNN-slug/` convention: `docs/specs/0003-anchor-on-zenoh/` will contain a TLA+ module characterizing the "eventually exactly one live owner" property and the partition / heal behavior.

## User Stories

Actors:

- **Application developer:** someone with an Elixir or Phoenix application that needs a process to exist exactly once across a cluster (a scheduler, a leader, a singleton GenServer) and is willing to accept eventual consistency in exchange for partition tolerance.
- **Operator:** the same or a different person deploying two or more BEAMs running `Loam.Anchor`.
- **loam contributor:** someone working on this library.
- **Phase 4 contributor:** someone beginning the next loam primitive (failover groups, distributed dynamic supervision, work distribution) and needing a stable referent for already-made semantic decisions.

Stories:

1. As an application developer, I want to mount `Loam.Anchor` in my application's supervision tree with a small block of config — registry, name, child spec — so that I can declare "this child runs once cluster-wide" without writing election or consensus code.
2. As an application developer, I want the child process to be running on at least one BEAM in the cluster within `start_jitter_ms + vacancy_debounce_ms + 2 × heartbeat_interval` after the first BEAM in the cluster comes online (and within `vacancy_debounce_ms + 2 × heartbeat_interval` after an owner-loss event in steady state), so that integration tests have a concrete timeout to assert against and operators have a worst-case vacancy bound.
3. As an application developer, I want exactly one BEAM to host the child during steady-state (no partition, no churn), so that work the anchor does is not duplicated.
4. As an application developer, I want both sides of a partition to independently host a copy of the child, so that each side of a partitioned cluster keeps doing work rather than waiting for the network to heal.
5. As an application developer, I want exactly one copy to survive partition heal — chosen by Registry's LWW comparator — so that convergence is automatic and I don't have to write merge logic.
5a. As an application developer, I want a BEAM that joins a connected component which already has a live owner to *not* start its own copy — it observes the existing owner via Registry's snapshot bootstrap and waits for `:name_vacant` like any other peer — so that adding capacity to a running cluster does not provoke an avoidable eviction.
6. As an application developer, I want the losing side's child to be terminated cleanly via its `Supervisor`'s `terminate_child/2` callback, so that `terminate/2` runs and the process can release resources.
7. As an application developer, I want a telemetry event emitted when a local child is terminated due to eviction, so that I can react in application code (re-enqueue work, log, alert) without a callback API on `Loam.Anchor`.
8. As an application developer, I want the local child to be restarted on crash subject to standard `Supervisor` max-restarts/max-seconds semantics, so that crash loops are bounded the same as any other supervised process.
9. As an application developer, I want to look up the anchor's pid via `Loam.Registry.lookup/2` using the same name I configured, so that I have one mental model for "find the process by name" across local and anchor processes.
10. As an application developer, I want to call `Loam.Anchor` with a child spec in any of the standard Elixir shapes (`{Module, args}`, `{Module, :function, args}`-style maps, full `%{id: ..., start: ..., ...}` maps), so that I do not have to learn a new child-spec dialect.
11. As an application developer, I want a clear error if I try to use semantics this PRD doesn't support — `:transient`, `:temporary`, `:one_for_all`, multi-child specs, state handoff — so that I know the limitation and the planned future PRD.
12. As an application developer, I want `Loam.Registry.monitor(registry, name)` available so that I can build my own liveness primitives (not just the anchor's), so that the substrate is composable rather than a single closed feature.
13. As an application developer, I want `Loam.Registry.demonitor(registry, ref)` so that I can stop watching a name without leaking watcher references on long-lived processes.
14. As an application developer, I want the `:name_vacant` notification to fire on every transition from "owned" to "not owned" — local unregister, remote unregister, peer-loss eviction, LWW eviction of the last claimant — so that I have one notification semantic to reason about regardless of why the name vacated.
15. As an application developer, I want the `:name_vacant` notification *not* to fire when ownership transfers from one live owner to another (LWW collision in which the new owner is recorded before any vacancy was observed locally), so that I don't get spurious restarts during normal contention.
16. As an operator, I want `Loam.Anchor` to live entirely on top of `Loam.Registry`'s Zenoh traffic — no new keyexpr namespace, no new session — so that the Zenoh deployment story does not grow with each phase.
17. As an operator, I want the local `Supervisor`'s max-restarts/max-seconds to be configurable per `Loam.Anchor` instance, so that I can tune crash-loop bounds for the anchor's workload independently of any other supervisor in the tree.
18. As an operator, I want the eviction telemetry event to include the name, the ZID of the winner, the local ZID, and a reason tag, so that my dashboards can attribute evictions to partition heal vs. operator-initiated unregister.
19. As an operator, I want the anchor's local supervisor to restart automatically if it crashes (the anchor process itself, not the child), without losing the registry monitor or the registered name unnecessarily, so that a transient bug in `Loam.Anchor` does not orphan the anchor across the cluster.
20. As a loam contributor, I want unit tests for the new `Loam.Registry.monitor/2` and `demonitor/2` API exercising every transition that should and should not fire `:name_vacant`, so that the deep module added in this PRD is correct in isolation before the anchor consumes it.
20a. As a loam contributor, I want a specific test that asserts a peaceful handoff (owner A unregisters, owner B registers within `vacancy_debounce_ms`) does *not* fire `:name_vacant` to watchers, and a hostile handoff (owner A unregisters, no replacement within the window) *does* fire exactly once, so that the debounce semantic is locked.
20b. As a loam contributor, I want a late-join integration test: BEAM C joins an already-running cluster where BEAM A holds the anchor; assert C does not start a child, observes A as owner via snapshot bootstrap, and only races when A vacates.
21. As a loam contributor, I want a two-BEAM happy-path integration test — start a `Loam.Anchor` on two nodes, assert exactly one child is running (by name lookup), kill the owner BEAM, assert the surviving BEAM starts a replacement within the configured detection window — that runs in default `mix test`, so that anchor liveness is asserted on every commit.
22. As a loam contributor, I want a partition-claim integration test (`@tag :partition`): two BEAMs each running the anchor, partition the network, assert each side runs an independent child, heal, assert exactly one child survives per the LWW comparator, the loser's child is terminated, and `lookup/2` on both sides returns the winner.
23. As a loam contributor, I want a local-crash test: kill the anchor's child process via `Process.exit/2`, assert the local `Supervisor` restarts it with the same registered name (re-registered after restart), and no peer observes a `:name_vacant`-triggered race.
24. As a loam contributor, I want a max-restarts test: configure a tight max-restarts/max-seconds, induce a crash loop, assert the local supervisor gives up, assert the name vacates, assert another peer takes over.
25. As a loam contributor, I want a property test that generates sequences of `{anchor_start, anchor_stop, child_crash, partition, heal, peer_kill}` events across two BEAMs and asserts: cluster eventually has exactly one live owner of the name, no two pids hold the name simultaneously after convergence, every eviction is accompanied by a telemetry event on the losing BEAM.
26. As a loam contributor, I want a Mac↔Pi real-hardware run of the happy-path and partition-claim tests with observations written to the journal, so that one-time real-network validation exists.
27. As a loam contributor, I want every load-bearing semantic decision documented as a `decision` journal entry before or alongside the code that implements it, so that the reasoning survives a two-week context gap.
28. As a loam contributor, I want a `docs/specs/0003-anchor-on-zenoh/` TLA+ spec characterizing "eventually exactly one live owner" and the partition/heal behavior, so that Phase 4 has a referent that already commits to the anchor semantic.
29. As a Phase 4 contributor, I want "a anchor name resolves to a unique live pid cluster-wide, modulo eventual consistency, with terminate-on-eviction" to already be a load-bearing fact when I begin work, so that failover-group / distributed-supervisor strategies don't have to relitigate the anchor semantic.
30. As a Phase 4 contributor, I want `Loam.Registry.monitor/2` available so that the next primitive can layer on it the same way `Loam.Anchor` did.
31. As future-me, I want the PRD's shipped-when items stated precisely so "is this PRD done?" has a boolean answer.
32. As future-me, I want the non-goals listed explicitly so scope creep is easy to redirect into a new PRD.

## Implementation Decisions

### Modules

**`Loam.Anchor`** — public surface. Functions: `child_spec/1`, `start_link/1`. Configuration: `:registry` (required, the `Loam.Registry` instance), `:name` (required, the Erlang term to claim), `:child_spec` (required, standard child-spec shape), `:max_restarts` and `:max_seconds` (optional, forwarded to the local supervisor), `:start_jitter_ms` (optional, default 500), `:vacancy_debounce_ms` (optional, default 1000, forwarded to `Loam.Registry.monitor/2`). `start_link/1` returns `{:ok, pid}` for the `Loam.Anchor` GenServer, *not* the child pid. The child pid is discoverable via `Loam.Registry.lookup(registry, name)`.

**`Loam.Anchor.Server`** — the GenServer holding anchor state. Per-instance state: registry name, claimed name, child spec, local supervisor pid (when holding), monitor ref from `Loam.Registry.monitor/2`, registry monitor ref of the local child pid (so we notice local termination not driven by us). Handles: initial registration race, `:name_vacant` notification → restart race, `{:loam_registry, :evicted, ...}` notification → terminate local child + telemetry, child-down message → unregister + restart race. Does *not* itself supervise the child; defers to a per-instance `Supervisor`.

**`Loam.Anchor.LocalSup`** — the per-instance `Supervisor` that runs the child while this BEAM holds the name. `:one_for_one`, configurable max-restarts/max-seconds. Started lazily by `Loam.Anchor.Server` when the registration succeeds; terminated when the anchor loses the name (eviction or peer takeover).

**`Loam.Registry` (extended)** — adds `monitor/2` and `demonitor/2`. Internal state grows a watcher table mapping `{registry, name}` → `[{pid, ref}]`. The mirror's mutators (`apply_register`, `apply_unregister`, `apply_eviction`) call into a small helper that diffs "had a live owner before" vs. "has a live owner after" and dispatches `:name_vacant` to watchers when the diff goes `true → false`. The `false → true` direction does not fire any notification in this PRD (a `:name_owned` notification is a future addition if needed).

### Interfaces

`Loam.Anchor.child_spec(opts)` returns a child spec that an application supervisor can mount.

`Loam.Anchor.start_link(opts)` starts the anchor GenServer.

`Loam.Registry.monitor(registry, name, opts \\ [])` returns `{:ok, ref}` where `ref` is a unique reference. Options: `:debounce_ms` (default 0 — fire immediately on owned→vacant edge). The watcher's calling pid receives `{:loam_registry, :name_vacant, registry, name}` (no ref in the message — watchers correlate by name) on each owned-to-vacant transition that remains vacant for at least `:debounce_ms`. If a new owner appears within the debounce window, the notification is suppressed. Watcher is automatically removed when the watcher pid dies (registry monitors it).

`Loam.Registry.demonitor(registry, ref)` returns `:ok`. Idempotent — demonitoring an unknown ref is not an error.

### Telemetry events

`[:loam, :anchor, :registered]` — measurements `%{system_time: integer}`, metadata `%{registry: name, name: term, zid: binary}`. Emitted when this BEAM successfully registers and starts the local child.

`[:loam, :anchor, :evicted]` — measurements `%{system_time: integer}`, metadata `%{registry: name, name: term, local_zid: binary, winner_zid: binary, reason: :lww_lost | :owner_lost_locally}`. Emitted when this BEAM terminates the child due to eviction or local supervisor giving up.

`[:loam, :anchor, :child_started]` — measurements `%{system_time: integer}`, metadata `%{registry: name, name: term, child_pid: pid}`. Emitted on each (re)start of the local child. The `child_pid` is local-only by convention — pids do not appear in telemetry metadata for events that describe cross-node state (`:registered`, `:evicted` carry ZIDs, not pids).

### Wire format

No new wire format. All cross-node traffic for anchor liveness is `Loam.Registry`'s existing `:register` / `:unregister` / `:heartbeat` / `:snapshot` envelopes. The anchor is a consumer of Registry, not a peer publisher.

### Configuration shape

```
{Loam.Anchor,
  registry: MyApp.Registry,
  name: {:scheduler, :primary},
  child_spec: {MyApp.Scheduler, []},
  max_restarts: 3,
  max_seconds: 5}
```

`registry` is the `Loam.Registry` instance (started elsewhere in the supervision tree).

`name` is any Erlang term, scoped to that registry.

`child_spec` is any standard Elixir child spec.

`max_restarts` / `max_seconds` are forwarded to the local supervisor.

## Testing Decisions

A good test for this PRD asserts external behavior: cluster-wide name ownership, child liveness, eviction outcomes, telemetry events. It does not assert ETS table contents, GenServer call queue depths, or the precise sequence of internal messages.

Modules that get direct test coverage:

- **`Loam.Registry` monitor extensions** — unit tested, every owned↔vacant transition path, with explicit coverage of the debounce window (peaceful handoff suppresses notification; hostile handoff fires exactly once) and the late-join case (a fresh watcher on an already-owned name observes no spurious `:name_vacant`). Property tested for "watcher receives exactly one `:name_vacant` per owned→vacant edge that exceeds the debounce window."
- **`Loam.Anchor.Server`** — integration tested via two-BEAM tests; not unit-tested in isolation because its interesting behavior is the cross-node race.
- **`Loam.Anchor.LocalSup`** — covered by the local-crash and max-restarts integration tests.

Integration test tags follow PRD-0001 convention: default tests in `mix test`, partition tests under `@tag :partition`, peer-death tests under `@tag :peer_death`, real-hardware under `@tag :hardware`.

Prior art lives in `test/loam/registry_test.exs` and `test/loam/registry/property_test.exs`. The two-BEAM harness from PRD-0001/0002 is reused; no new test infrastructure beyond a anchor fixture child module.

## Out of Scope

- **Multiple child specs per anchor.** Use multiple `Loam.Anchor` instances.
- **Restart strategy taxonomy.** No `:one_for_all`, `:rest_for_one`, `:transient`, `:temporary`. `:permanent` only.
- **State handoff on eviction.** Application's problem. A future PRD may add an `:on_eviction` callback or a handoff primitive.
- **Fenced singletons.** No epoch tokens, no STONITH, no guarantee that the loser stops *before* the winner starts. Both can run briefly during partition heal; that is the explicit failure mode.
- **Strong consistency / consensus-backed leadership.** A future PRD may add a Raft-shaped variant. This one rides Registry's LWW.
- **Process pools / distributed dynamic supervision.** N-of-M placement is a different primitive. Future PRD.
- **Failover groups.** Primary/standby with explicit standby selection is a different primitive. Future PRD.
- **Cross-node child placement.** Starting a child on a *specific* remote BEAM is not what this PRD does. anchor chooses by race, not by placement.
- **`:name_owned` notification on the inverse transition.** Future addition if a primitive needs it.
- **General `Loam.Supervisor` surface.** This PRD ships `Loam.Anchor`, narrow and singleton-shaped.
- **Ordering guarantee between loser's `terminate/2` and winner's start.** There is no fence. The winner's child can be live and serving messages while the loser is still inside its `terminate/2` callback flushing state. Applications that need "loser fully drained before winner takes over" semantics need a fenced-handoff primitive, which is a future PRD.

## Further Notes

The `Loam.Registry.monitor/2` addition is the main reason this is a Phase 3 PRD and not a smaller one. It is a deep module added to a shipped surface (PRD-0002). The alternative — polling `lookup/2` from `Loam.Anchor` — was rejected on the grounds that future primitives (failover groups, leader election, distributed dynamic supervision) will all want the same notification, and adding it once in the right place is cheaper than polling repeatedly in many places. The TLA+ spec for this PRD will model the monitor primitive as well as the anchor, since the monitor's correctness is load-bearing for the anchor's correctness.

The "free-for-all + LWW" choice in decision 1 means the anchor's startup is briefly noisy. The `:start_jitter_ms` damps but does not eliminate the contention — by design, since exercising the eviction path on cluster startup is the highest-value continuous test of the substrate's partition story.

The module name `Loam.Anchor` was selected after weighing the holding/claim metaphor against uniqueness-flavored candidates (`Singleton`, `Solo`, `Isolate`). The reasoning is recorded in `docs/journal/2026-04-26-singleton-paradigm-naming-question.md`. The metaphor: a name is anchored to a live pid; if the BEAM dies, the anchor drops; another BEAM races to re-anchor. It survives the partition test ("each side has its own anchor") and accommodates future siblings (failover groups, fenced anchors, leader-elected pools) without locking the family into a metaphor schema.

## Shipped When

1. `Loam.Registry.monitor/2` and `demonitor/2` are public, documented, and unit-tested with full transition coverage.
2. `Loam.Anchor` is public, documented, and accepts the configuration shape above.
3. The two-BEAM happy-path integration test passes in default `mix test`.
4. The `@tag :partition` partition-claim test passes.
5. The `@tag :peer_death` owner-loss test passes.
6. The local-crash and max-restarts tests pass.
7. The property test (story 25) passes.
8. The Mac↔Pi real-hardware run is journaled (story 26).
9. Every load-bearing decision (Solution items 1–7) has a `decision` journal entry.
10. `docs/specs/0003-anchor-on-zenoh/` contains a TLA+ module characterizing "eventually exactly one live owner" and the monitor primitive's transition semantics, with at least one model config and a readme.
