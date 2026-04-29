# Spec 0003: Anchor on Zenoh

This module characterizes `Loam.Anchor`'s distributed liveness semantic and the debounce semantic of `Loam.Registry.monitor/2` (PRD-0003 gate item 10). It is *characterization*, not a contractual guarantee, in the same posture as spec 0002.

If `Loam.Anchor` is renamed (the PRD flags it as a placeholder), only the README's prose references and the module name need to change. The TLA+ module is named `AnchorOnZenoh` and references the abstract concept; rename is a one-find-and-replace operation across this directory.

## What it models

Two BEAMs (also serving as ZIDs), each running a `Loam.Anchor.Server` for every name in `Names`. The Registry semantic from spec 0002 is re-modeled inline (not instantiated) so this module is self-contained. New state on top of 0002:

- `watchers[n]` — names this BEAM watches via `Loam.Registry.monitor/2`. Initialized to all names since each BEAM runs a anchor server per name.
- `vacancyTimer[n][name]` — debounce timer state, either `"off"` or `[remaining: 0..MaxDebounce]`. Armed on owned-to-vacant edges, decremented each `TimerTick`, fires `:name_vacant` on reaching 0 *if* the slot is still vacant.
- `vacancyEvents` — history set of fired `:name_vacant` events, witnessed for `DebounceCorrectness`.
- `localSup[n][name]` — `"running"` iff this BEAM has the local supervisor and child up.
- `restartBudget[n][name]` — remaining max-restarts budget.

Actions:

- `LocalRegister(n, name)` — race-to-register; sets `localSup` to `running`. Free-for-all start: nothing serializes the race; LWW resolves it on `Deliver`.
- `LocalUnregister(n, name)` — operator-driven release.
- `ChildCrashRestart(n, name)` — local supervisor restarts the child, decrements budget. No registry traffic.
- `MaxRestartsExhausted(n, name)` — budget hits 0; supervisor gives up, name vacates, peer takeover via the same `:name_vacant` path.
- `LWWEviction(n, name)` — Anchor.Server reaction to a `Deliver` that overwrote our entry with a different owner. Drops `localSup` to `off`.
- `Deliver(ann, dst)` — same as 0002, plus `vacancyTimer` is updated via `NextTimer` on the affected name.
- `PeerLoss(lost, observer)` — same as 0002, plus arms `vacancyTimer[observer][name]` for every name dropped.
- `TimerTick(n, name)` — decrements an armed timer; fires `:name_vacant` only if the slot is still vacant at expiry.
- `Connect` / `Disconnect` — partition toggle.

The `NextTimer` helper enforces the four-cell transition table (see TLA module comment): owned→vacant arms, vacant→owned disarms (peaceful handoff suppression), owned→owned with same entry no-op, owned→owned with new owner disarms (in-place LWW replacement, the case from PRD story 15).

## What it deliberately omits

- **Start jitter (`start_jitter_ms`).** A noise damper for the boot storm; does not change the semantic. Free-for-all start is the unconstrained interleaving of `LocalRegister` actions, which is the worst case the jitter is meant to thin.
- **Heartbeat intervals as wall-clock time.** `PeerLoss` is non-deterministic, same as 0002.
- **Snapshot bootstrap.** Same modeling story as 0002: weak fairness on `Deliver` plus eventually-stable connectivity drains `inflight`, achieving the same convergence the snapshot mechanism produces in code. The late-join story (story 5a in the PRD) is implicitly modeled: a BEAM whose `localSup` is `off` and whose mirror records a remote owner will not enable `LocalRegister` (its precondition is `name \notin DOMAIN mirror[n]`).
- **Telemetry.** `[:loam, :anchor, :evicted]` and friends are not modeled as separate variables. `LWWEviction`'s firing is the abstract witness.
- **Registry's `:evicted` notification (distinct from `:name_vacant`).** The losing BEAM's `LWWEviction` action stands in for the `terminate/2` path.
- **`terminate/2` race with winner start.** PRD's documented gap (Out of Scope: "Ordering guarantee between loser's `terminate/2` and winner's start"). The spec preserves the gap intact.
- **Multiple registries.** Single shared registry; multiple names compose by setting `Names`.
- **Debounce as wall-clock ms.** `MaxDebounce` is in abstract ticks; one `TimerTick` step is one tick. The relationship between `MaxDebounce` and the heartbeat interval is a code-level concern.
- **Tombstones.** Same gap as 0002, inherited.

## Properties verified

### Substrate properties inherited from 0002

The following are re-modeled here under their 0002 names:

- `LWWWellGrounded` — every entry has `lamport >= 1` and a valid owner.
- `EventualDelivery` — under eventually-stable connectivity, in-flight announces drain.

The Convergence-of-mirrors property from 0002 is not separately re-asserted here; it is subsumed by `AtMostOneRunningWhenConverged` plus the LWW machinery, which together cover the anchor-relevant convergence.

### New properties

**Safety**

- `TypeOK` — variables conform.
- `LocalSupCoherent` — `localSup[n][name] = "running"` implies `mirror[n][name].owner = n`. The local supervisor cannot be running while we're not the recorded owner.
- `AtMostOneRunningWhenConverged` — the steady-state form of `EventualUniqueness`: when `connected /\ inflight = {}`, at most one BEAM has `localSup` running per name. Catches uniqueness-violation reachable states without needing a temporal property.
- `TimerVacancyConsistent` — an armed timer (`vacancyTimer[n][name] # "off"`) implies the slot is currently vacant in the local mirror. Catches reorderings that would leave a timer ticking on an owned slot, which would in turn cause a spurious `:name_vacant`.
- `DebounceCorrectness` — every recorded `:name_vacant` event in `vacancyEvents` corresponds to a `TimerTick` fire that was guarded by `name \notin DOMAIN mirror[n]` at fire time. Together with `TimerVacancyConsistent` and `NextTimer`'s peaceful-handoff arm, a register arriving inside the debounce window cannot produce an event.

**Liveness (weak)**

- `EventualDelivery` — same shape as 0002.
- `EventualUniqueness` — `<>[]connected => <>[](\A name: at-most-one-running)`. The load-bearing temporal property.
- `EventualLiveness` — under eventually-stable connectivity and at least one BEAM with budget remaining, eventually at least one BEAM is running. Combined with `AtMostOneRunningWhenConverged` this gives "exactly one."

### How the two PRD-mandated invariants map

- **EventualUniqueness** in the PRD ↔ `EventualUniqueness` (temporal) plus `AtMostOneRunningWhenConverged` (state form). The state form is strictly stronger when the antecedent (connected and drained) holds; the temporal form covers the path to that state.
- **DebounceCorrectness** in the PRD ↔ `DebounceCorrectness` plus `TimerVacancyConsistent`. The latter is the structural reason no peaceful handoff can produce an event; the former asserts the witness set.

## Modeling choices that diverged from 0002

- **Self-contained, not instantiated.** 0002's vocabulary is re-stated inline rather than `EXTENDS`-ed or `INSTANCE`-ed. Reason: 0003 mutates the same variables (`mirror`, `inflight`, etc.) as 0002 but with an extended action set, and TLA+'s composition story for that case is awkward. Restating is shorter and the substrate definitions are byte-identical to 0002 (LWW, `IncomingNewer`, `SetEntry`, `DropEntry`, `ApplyAnnounce`, `PeerLoss` core).
- **History variables.** `vacancyEvents` is a history-only set; nothing reads it except `DebounceCorrectness`. 0002 explicitly avoided history variables on the same grounds and reasoned about LWW correctness by construction. We diverge here because debounce correctness is a temporal-shaped property that does not reduce cleanly to a single-state predicate without a witness.
- **State-form uniqueness.** `AtMostOneRunningWhenConverged` is checked as a plain invariant (state predicate) rather than only the temporal form. This catches violations during BFS without requiring liveness checking, which is significantly cheaper.
- **`Loam.Registry.monitor`'s `:debounce_ms = 0` case.** The default is 0 in code (immediate fire); the PRD sets the anchor's default to 1000ms. The spec uses `MaxDebounce >= 1`. The 0-debounce case degenerates to "fire immediately on owned→vacant in `Deliver`/`PeerLoss`" and is a strict subset of the modeled behavior (timer arms with `remaining = 0` and the next `TimerTick` fires it). Not separately exercised.

## Running

Requires TLC. Same setup as 0002:

```sh
java -cp ../../../_tla/tla2tools.jar tlc2.TLC -config AnchorOnZenoh.cfg AnchorOnZenoh.tla
```

**Verified configurations:** TBD. The first-cut config is intentionally tight (`Nodes = {1,2}`, `Names = {a}`, `MaxLamport = 3`, `MaxDebounce = 2`, `MaxRestarts = 1`). State-space size and wall time will be filled in once the spec runs through TLC. Bumping `Names`, `MaxDebounce`, or `MaxRestarts` deepens the search the way 0002's `Names` and `MaxLamport` knobs do. Adding a third node requires the same per-destination-tracking change to `Deliver` that 0002 calls out.

## Relationship to the PRD

PRD-0003 §Shipped When item 10. The spec exists as a referent for Phase 4 (failover groups, distributed dynamic supervision), whose work-distribution semantics will inherit "name resolves to a unique live owner, modulo eventual consistency." The two PRD-mandated invariants (EventualUniqueness, DebounceCorrectness) are encoded above; additional invariants (`LocalSupCoherent`, `TimerVacancyConsistent`, `AtMostOneRunningWhenConverged`, `EventualLiveness`) were discovered during modeling and locked in.

## Why characterization, not contract

Same posture as specs 0001 and 0002: this spec was written alongside the implementation slices, not before, so it characterizes what the code does. The honest gaps (no fenced handoff, no tombstones, no snapshot bootstrap modeled separately, no wall-clock time for heartbeat or debounce) are documented above and tracked in the PRD's Out of Scope list. Closing any of those gaps is a future PRD's job.
