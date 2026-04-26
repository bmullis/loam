---
id: 0002
slug: registry-on-zenoh
status: draft
date: 2026-04-26
phase: 2
related:
  - docs/prds/0001-phoenix-pubsub-adapter.md
  - docs/specs/0001-phoenix-pubsub-adapter/
  - docs/specs/0002-registry-on-zenoh/
---

# Registry on Zenoh

## Problem Statement

Elixir's `Registry` is a local key-value store with process-monitoring semantics: `register(name, pid)` claims a name, `lookup(name)` returns the registered pid, the entry is removed automatically when the pid exits. It is local to one BEAM. Distributed alternatives — `:global`, `Horde`, `Swarm`, `Syn` — each pick a different point in the design space (full-mesh consensus, CRDT-backed eventually consistent, leader-elected, gossip), each with its own assumptions about node identity, partition behavior, and conflict resolution. None of them compose with the partition-tolerant substrate PRD-0001 just shipped on top of.

PRD-0001 established that a `Phoenix.PubSub` distributed by Zenoh has a precise, characterized partition story: IP-reachability outages produce eventual in-order delivery (latency spike, no gaps); catastrophic peer-loss engages a `:drop` regime where during-outage publishes are lost and delivery resumes after fresh peering. Node identity is the Zenoh ZID. Wire format is a versioned envelope plus ETF.

A distributed Registry built on the same substrate inherits those primitives. It does *not* inherit the answer to: what does it mean to claim a name in a distributed setting where partitions are normal? What happens when two BEAMs both register the same name during a partition? When is a stale entry on a vanished peer evicted? What is `lookup/2`'s semantic when the network is down?

The question this PRD answers: **what do the semantics of a minimal distributed `Loam.Registry` look like when built on the PRD-0001 PubSub adapter, and what is the smallest working artifact that forces the load-bearing semantic decisions to be made in public?**

This is Phase 2 of loam. PRD-0001 is its substrate. The semantic referents established there — node = ZID, eventual-delivery + `:drop` regimes, opaque keyexpr encoding, ETF wire format with a version byte — are inherited. This PRD only relitigates a question if Phase 2's semantic genuinely differs.

## Solution

A library module, `Loam.Registry`, exposes a register / unregister / lookup / keys / count surface modeled on Elixir's `Registry` but with explicitly distributed semantics. Each BEAM running `Loam.Registry` keeps a local ETS mirror of the entire cluster's registrations. Mutations (register, unregister, eviction) propagate as small announce messages over Zenoh; `lookup/2` reads the local mirror with no network round-trip.

The slice is intentionally narrow. Unique-name registration only. Opaque keys (any Erlang term). Pids must live on the BEAM that registers them (no remote-pid registration). `lookup/2` returns the local mirror's view, which is eventually consistent. Cross-node process death is detected via the underlying PubSub `:drop` regime and a heartbeat. Conflict resolution is Last-Writer-Wins by Lamport timestamp, ZID lexicographic tiebreak.

Duplicate keys, dispatch/3, meta, wildcard register/lookup, remote-pid registration, strong consistency, and CRDT-shaped conflict-free claims are all out of scope and called out below.

The semantic model the Registry presents, in one sentence, is: **eventually-consistent unique-name registration with Last-Writer-Wins conflict resolution; `lookup/2` is a local read that may return stale state during partition; cross-node entries are evicted on the underlying PubSub's `:drop` regime engagement.** Users of `Loam.Registry` are not promised more; they are, crucially, not promised less either. Strong consistency, partition-aware claims, and CRDT-shaped semantics are future PRDs.

Eight load-bearing design decisions are fixed by this PRD. Each gets a corresponding entry in the design journal recording why:

1. **Unique-name only.** No `:duplicate` mode in this PRD. Registering the same name twice from the same BEAM returns `{:error, {:already_registered, pid}}`. The `:duplicate` semantic interacts with `dispatch/3` and is a separate semantic story.
2. **Opaque keys, no wildcards.** Names are arbitrary Erlang terms, encoded with `:erlang.term_to_binary/1` and base64url'd into a single keyexpr chunk. Inspecting the key content would foreclose evolution rights, same reasoning as PRD-0001 Solution item 1.
3. **Local pids only.** `Loam.Registry.register(name, pid)` requires `node(pid) == node()` and the pid to be alive. Registering a remote pid is rejected with `{:error, :remote_pid}`. Cross-node *lookup* returns the remote pid; cross-node *registration* requires that node to do the registering.
4. **Eventually-consistent local-mirror lookup.** Each BEAM keeps a `:set` ETS table mirroring the cluster's registrations. `lookup/2` reads the table. No network round-trip. Reads during partition return whatever the local mirror saw last; this is the "stale lookup" failure mode and is explicitly characterized.
5. **Last-Writer-Wins conflict resolution by Lamport timestamp, ZID lexicographic tiebreak.** Each register/unregister announce carries a Lamport timestamp (per-node monotonic counter, advanced on receive). On collision, the larger timestamp wins; ties broken by lexicographic comparison of the announcing ZID. The losing side observes its own pid was evicted and sends a `{:loam_registry, :evicted, name, winner_zid}` message to the affected pid (which has been monitored).
6. **Cross-node death detection rides PubSub's `:drop` regime.** Each `Loam.Registry` instance also subscribes to a heartbeat keyexpr and emits a heartbeat every N seconds. A peer is considered alive iff its ZID is in `peers_zid` *and* its last heartbeat is within K seconds. On peer-loss (PubSub `:drop` regime engages, `peers_zid` clears for that ZID), all entries owned by that ZID are evicted from the local mirror. Recovery is by re-announce when the peer returns; no replay.
7. **Registry owns its own Zenoh session for Phase 2.** Forward-compatible with sharing via a `session:` config option, but the default is one session per `Loam.Registry` instance. Same reasoning as PRD-0001 Solution item 6: keep the simple case simple, leave a clean place for Phase 3+ sharing.
8. **The wire format is the PRD-0001 envelope, version 1, payload tagged.** The `LOAM` magic + version byte + ETF envelope from PRD-0001 is reused. The payload is a tagged tuple: `{:register, name, pid, lamport, zid}`, `{:unregister, name, lamport, zid}`, `{:heartbeat, zid, lamport}`, or `{:snapshot_request, zid}` / `{:snapshot, zid, [{name, pid, lamport}, ...]}` for late-joiners. New peers issue a snapshot request on first heartbeat to bootstrap; existing peers reply with their owned entries.

This PRD also extends the `docs/specs/NNNN-slug/` convention: `docs/specs/0002-registry-on-zenoh/` will contain a TLA+ module characterizing the LWW conflict-resolution and eventual-consistency properties.

## User Stories

Actors:

- **Application developer:** someone with an Elixir or Phoenix application that uses `Registry` (or a global-name pattern) and wants distributed registration over a partition-tolerant substrate.
- **Operator:** the same or a different person deploying two or more BEAMs running `Loam.Registry`.
- **loam contributor:** someone working on this library.
- **Phase 3 contributor:** someone beginning Supervisor-on-Zenoh and needing a stable referent for already-made semantic decisions.

Stories:

1. As an application developer, I want to start `Loam.Registry` as a child of my application's supervision tree with a small block of config, so that I can use distributed registration without restructuring my application.
2. As an application developer, I want `Loam.Registry.register(MyReg, name, pid)` to claim `name` for `pid` cluster-wide, so that any node looking up `name` finds the same pid.
3. As an application developer, I want `Loam.Registry.lookup(MyReg, name)` to return `[{pid, value}]` or `[]` without a network round-trip, so that hot paths don't block on the network.
4. As an application developer, I want `lookup/2` to be eventually consistent — returning stale state during partition — so that my application keeps working when the network is degraded, with the explicit understanding that I may briefly route to a stale pid.
5. As an application developer, I want the Registry to automatically remove a registration when the registered pid exits, so that I don't have to wire up `Process.monitor` myself.
6. As an application developer, I want the Registry to automatically remove a remote node's registrations when that node's PubSub session is declared lost (`:drop` regime engaged), so that lookups don't keep returning a vanished pid indefinitely.
7. As an application developer, I want a clear error if I try to register a remote pid — `{:error, :remote_pid}` — so that I learn immediately that "the BEAM that owns the pid does the registering" is the rule, instead of debugging it later.
8. As an application developer, I want a clear error if I try to register a name twice from the same BEAM — `{:error, {:already_registered, pid}}` — so that the local-double-claim case is unambiguous.
9. As an application developer, I want a documented behavior for the cross-BEAM-double-claim case: both sides see their own register succeed; on heal, the LWW loser's pid receives `{:loam_registry, :evicted, name, winner_zid}`; subsequent `lookup/2` on either side returns the winner. So that I can write code that handles eviction (e.g., gracefully shut the orphaned process down).
10. As an application developer, I want `Loam.Registry.unregister(MyReg, name)` to remove a name I own, so that I can release names without crashing the registered pid.
11. As an application developer, I want `Loam.Registry.keys(MyReg, pid)` to return the names a pid holds, and `Loam.Registry.count(MyReg)` to return the cluster-wide entry count from the local mirror, so that I can introspect Registry state without iterating ETS by hand.
12. As an application developer, I want Registry names to be arbitrary Erlang terms (atoms, tuples, strings, structs), so that I do not have to hash or stringify my naming scheme.
13. As an application developer, I want multiple `Loam.Registry` instances in one BEAM to be possible, so that multi-tenant or multi-subsystem apps can keep their name spaces separate.
14. As an application developer, I want a clear error if I try to use semantics this PRD doesn't support — duplicate keys, wildcard register, dispatch — so that I know the limitation and the planned future PRD.
15. As an operator, I want to specify the Zenoh peer endpoints in my application config, same shape as the PubSub adapter, so that I have one mental model for substrate networking.
16. As an operator, I want the heartbeat interval and missed-beat eviction threshold to be configurable, so that I can tune cross-node death-detection latency for my deployment.
17. As an operator, I want `Loam.Registry` traffic to live under a distinguishable namespace (`loam/reg/<registry_name>/...`), so that I can grep Zenoh traces for it independently of PubSub traffic.
18. As an operator, I want the Registry's session to restart automatically if it crashes, without taking down the registered entries on this node beyond a brief gap, so that a transient NIF failure does not cascade.
19. As an operator, I want a stable identifier for "this Registry instance" that does not pretend to be a BEAM node name, same as PRD-0001 — the Zenoh ZID — so that my logs and dashboards stay aligned across PubSub and Registry.
20. As a loam contributor, I want unit tests for the Lamport-clock module, the LWW comparator, the announce-payload encode/decode, and the local-mirror update logic, so that the load-bearing pure functions are property-tested before any cross-process work begins.
21. As a loam contributor, I want a two-BEAM happy-path integration test — register on one node, lookup on the other — that runs in default `mix test`, so that cross-node visibility is asserted on every commit.
22. As a loam contributor, I want a partition-claim integration test (`@tag :partition`): partition the network, register the same name on both sides, heal, assert exactly one side wins per the LWW comparator, the loser receives the eviction message, and both sides converge on the same view.
23. As a loam contributor, I want a peer-death integration test (`@tag :peer_death`): kill one BEAM's OS process, assert the surviving side evicts the dead BEAM's entries within the configured heartbeat-miss window, and a fresh BEAM joining can re-register without conflict.
24. As a loam contributor, I want a property test that generates sequences of `{register, unregister, partition, heal}` events across two BEAMs and asserts: cluster-wide convergence after heal, no duplicate-pid for the same name post-convergence, eviction notifications received by every losing pid.
25. As a loam contributor, I want a Mac↔Pi real-hardware run of the happy-path and partition-claim tests with observations written to the journal, so that one-time real-network validation exists.
26. As a loam contributor, I want every load-bearing semantic decision documented as a `decision` journal entry before or alongside the code that implements it, so that the reasoning survives a two-week context gap.
27. As a loam contributor, I want a `docs/specs/0002-registry-on-zenoh/` TLA+ spec characterizing LWW convergence and eventual consistency, so that Phase 3 has a referent that already commits to the conflict-resolution semantic.
28. As a Phase 3 contributor (Supervisor-on-Zenoh), I want "a registered name resolves to a unique pid cluster-wide, modulo eventual consistency and LWW conflict resolution" to already be a load-bearing fact when I begin work, so that supervision strategies don't have to relitigate the registration semantic.
29. As a Phase 3 contributor, I want `Loam.Registry` to expose enough surface (register, unregister, lookup, keys, count) to support `via`-tuple-style supervision patterns, so that Supervisor-on-Zenoh can lean on it without immediate scope expansion.
30. As future-me, I want the PRD's shipped-when items stated precisely so "is this PRD done?" has a boolean answer.
31. As future-me, I want the non-goals listed explicitly so scope creep is easy to redirect into a new PRD.

## Implementation Decisions

### Modules

**`Loam.Registry`** — public surface. Functions: `child_spec/1`, `register/3`, `unregister/2`, `lookup/2`, `keys/2`, `count/1`. Plus `register/4` accepting an optional `value` term (paralleling Elixir Registry's `{pid, value}` tuple shape). Internally delegates to deep modules below.

**`Loam.Registry.Mirror`** — the local ETS table abstraction. Pure-ish module with one responsibility: maintain the eventually-consistent view. Functions: `apply_register/5`, `apply_unregister/3`, `apply_eviction/2`, `lookup/2`, `keys_for_pid/2`, `count/1`, `entries_owned_by/2`. Each mutator takes the incoming Lamport timestamp and applies LWW. Pure modulo the ETS table reference.

**`Loam.Registry.Lamport`** — a tiny pure module managing a per-node Lamport counter. `tick/1` advances and returns; `observe/2` advances past an observed timestamp and returns. Property-testable in isolation.

**`Loam.Registry.Announce`** — pure encode/decode of the tagged payloads (`:register`, `:unregister`, `:heartbeat`, `:snapshot_request`, `:snapshot`). Wraps `Loam.Phoenix.Envelope` (the wire format from PRD-0001 is reused). One responsibility: serialize Registry events; one narrow interface.

**`Loam.Registry.Session`** — `GenServer` owning the `Zenohex.Session`, the broad subscription on `loam/reg/<registry_name>/**`, the heartbeat timer, and the local mirror's update loop. Modeled on `Loam.Phoenix.Session` from PRD-0001. Process monitors are tracked here and translated into outgoing `:unregister` announces when a registered pid exits.

**`Loam.Registry.Application`** — supervision-tree wiring. `Loam.Registry`'s `child_spec/1` returns a Supervisor that owns the Session and the ETS table.

### Interfaces

- **User-facing configuration** is a keyword list:

  ```elixir
  {Loam.Registry,
    name: MyApp.Registry,
    zenoh: [mode: :peer, listen: ["tcp/0.0.0.0:7448"], connect: ["tcp/192.168.1.10:7448"]],
    namespace: "loam/reg",      # optional
    node_name: nil,             # optional; defaults to ZID
    heartbeat_interval: 5_000,  # optional; ms
    heartbeat_misses: 3         # optional; eviction threshold
  }
  ```

- **`register(registry, name, pid_or_value)` and `register(registry, name, pid, value)`.** Returns `:ok` on local success (announce is fire-and-forget; no waiting for cluster acknowledgment). Returns `{:error, {:already_registered, existing_pid}}` if the local mirror already has an entry for `name`. Returns `{:error, :remote_pid}` if `node(pid) != node()`. Returns `{:error, :no_such_registry}` if the registry isn't started. The 3-arity form with a non-pid second argument registers `self()` and stores the value.

- **`unregister(registry, name)`.** Returns `:ok`. If the local node owns the entry, an `:unregister` announce is emitted. If the local mirror shows the entry is owned by a different ZID, returns `{:error, :not_owner}` — a node may only unregister entries it owns. (Eviction is the mechanism for owner-change.)

- **`lookup(registry, name)`.** Returns `[{pid, value}]` (one-element list to match Elixir Registry's `:unique` shape) or `[]`. Reads ETS only.

- **`keys(registry, pid)`.** Returns a list of names registered to `pid` per the local mirror. Cross-node pids are queryable; the answer reflects the mirror's current view.

- **`count(registry)`.** Returns an integer entry count per the local mirror.

- **Eviction notification.** A pid that loses an LWW conflict receives `{:loam_registry, :evicted, name, winner_zid}` in its mailbox. Pids may opt out by passing `notify: false` to `register/3`/`register/4`.

- **Wire format.** Reuses `Loam.Phoenix.Envelope` (LOAM magic + version 1 + ETF), with payload one of:

  - `{:register, name_term, pid, lamport, zid}` — name claim from `zid` at logical time `lamport`
  - `{:unregister, name_term, lamport, zid}` — release
  - `{:heartbeat, zid, lamport}` — liveness ping
  - `{:snapshot_request, zid}` — late-joiner asking for owned-entries replay
  - `{:snapshot, zid, [{name, pid, value, lamport}, ...]}` — reply with this peer's owned entries

- **Keyexpr layout.** `loam/reg/<registry_name>/<base64url(term_to_binary(name))>` for register/unregister. `loam/reg/<registry_name>/_meta/heartbeat`, `_meta/snapshot_request`, `_meta/snapshot/<base64url(term_to_binary(zid))>` for control traffic. The `_meta` segment is reserved; the opaque-name encoding cannot collide because base64url omits underscore-only segments.

- **`node_name`.** Returns the ZID string by default. Override allowed, same as PRD-0001.

### Architectural constraints

- **No fork of zenohex, no FFI.** Same as PRD-0001.
- **Builds on PubSub adapter primitives, not on the adapter itself.** The wire-format module (`Loam.Phoenix.Envelope`) is shared; the keyexpr style (opaque base64url) is shared; the session-ownership pattern is shared. But `Loam.Registry` does not require `Loam.Phoenix.Adapter` to be running. They are siblings, not parent/child. The forward-compatible `session:` config option is reserved for a future PRD that introduces sharing.
- **No CRDT primitives.** LWW is chosen specifically because it does not require the codebase to grow a CRDT library or a CRDT-shaped storage layer. A future bounded-history or conflict-free-claim PRD will introduce that machinery; this PRD does not.
- **Per-instance sessions.** Same reasoning as PRD-0001 Solution item 6.
- **Best-effort announce.** Register/unregister announces are fire-and-forget. A registration that the publisher returned `:ok` for may be lost on the wire if the substrate is in the `:drop` regime at announce time. The eventual-delivery regime catches up via TCP retransmits. Late-joiners catch up via snapshot exchange.

### Journal entries required before or alongside code

One `decision` entry per item in the "Solution" numbered list (eight entries). One `observation` entry on the snapshot-exchange protocol once it is implemented and exercised against a real two-BEAM run (because the bootstrap-race semantics are easy to get wrong on paper). One `decision` entry on whether `Loam.Registry`'s eviction notification message format should match any pattern used elsewhere in loam (currently nothing).

### Shipped-When gate (authoritative list)

1. `Loam.Registry`, `Loam.Registry.Session`, `Loam.Registry.Mirror`, `Loam.Registry.Lamport`, `Loam.Registry.Announce` exist and are exercised by the tests below.
2. Unit tests:
   - `Lamport` module — property-tested for monotonicity, observe-advances-past, tick-strictly-increasing.
   - `Mirror` module — property-tested over sequences of `apply_register`/`apply_unregister`/`apply_eviction` calls; invariants: at most one entry per name; LWW comparator agreement (the entry that survives is always the one with the larger `(lamport, zid)`); idempotent application of the same announce.
   - `Announce` module — encode/decode round-trip property; explicit cases for malformed and unknown-tag payloads.
   - `Loam.Registry` public API smoke tests — `register/3` rejects remote pid, `register/3` rejects double-claim from same BEAM, `unregister/2` rejects non-owned entry, etc.
3. Two-BEAM happy-path integration test. Modeled on PRD-0001's two-process rig. Two OS processes start `Loam.Registry`, register on node A, assert lookup on node B returns the right pid within a timeout. Asserts: `count/1` matches; `keys/2` for the registered pid matches; `unregister/2` propagates and `lookup/2` on B returns `[]` within a timeout.
4. Partition-claim integration test, `@tag :partition`. Two processes, partition with `pfctl`/`iptables`, register the same name on both sides during the partition, heal, assert: exactly one of the two pids survives in both sides' mirrors; the LWW comparator's winner is the survivor; the losing pid received `{:loam_registry, :evicted, name, winner_zid}`; both sides converge on the same `lookup/2` answer.
5. Peer-death integration test, `@tag :peer_death`. Modeled on PRD-0001 gate 4b. Register a name on the soon-to-die BEAM, kill that BEAM's OS process, assert the surviving BEAM evicts the entry within `heartbeat_interval * heartbeat_misses + slack` and `lookup/2` returns `[]`. Then start a fresh BEAM on the same endpoint, register the same name, assert the new registration takes effect with no conflict (the dead BEAM's entries are gone).
6. Property test. StreamData generates sequences of `{register, name, pid_idx}`, `{unregister, name}`, `{partition}`, `{heal}` events dispatched across the two-BEAM rig. Invariants:
   - **Convergence:** after the final `heal` and a settle window, both BEAMs' `lookup/2` returns the same answer for every name in the test.
   - **Uniqueness:** for every name, at most one `(pid, value)` appears across both mirrors after convergence.
   - **Eviction notification:** every pid that lost an LWW conflict received exactly one `{:loam_registry, :evicted, name, winner_zid}`.
7. Mac↔Pi journal writeup. Run the happy-path and partition-claim tests on real Mac↔Pi hardware. One journal entry records observations, including any Lamport-clock or heartbeat surprises.
8. Eight semantic-decision journal entries (one per numbered item in "Solution") plus the bootstrap-race observation entry plus the eviction-message-format entry.
9. TLA+ spec at `docs/specs/0002-registry-on-zenoh/` with module, config, and readme. Models two nodes, the LWW comparator, register/unregister/heartbeat/eviction actions, and a dynamic connectivity relation. Properties:
   - **Safety 1 (uniqueness):** for every name, at most one entry in the union of both nodes' mirrors after a quiescence period.
   - **Safety 2 (LWW correctness):** the surviving entry for any name is the one with the largest `(lamport, zid)` ever announced for that name.
   - **Safety 3 (no spurious eviction):** an entry is evicted only as the result of a higher-precedence announce for the same name, an `:unregister` from the owning node, an exit of the registered pid, or a peer-loss event for the owning ZID.
   - **Liveness (weak):** if connectivity is stable from time T and no further mutations occur, both nodes' mirrors converge.

## Testing Decisions

### What makes a good test here

Tests assert externally observable behavior: what `lookup/2` returns from each side at each moment, what messages get delivered to which pid, what happens to the cluster state under partition and peer-death. Tests do not assert internal table contents, internal process identity, or specific Zenoh APIs used.

The pure modules (`Lamport`, `Announce`, and the ETS-backed `Mirror`'s update logic) are property-testable in isolation. The cross-node behavior is example-and-property tested through the two-process rig PRD-0001 established. The split is the same as PRD-0001: pure modules get unit + property; cross-process behavior gets integration.

The partition tests are structural duplicates of PRD-0001's, with new assertions specific to Registry semantics. The two-process rig is reused.

### Modules with dedicated tests

- `Loam.Registry.Lamport` — property-tested.
- `Loam.Registry.Mirror` — property-tested over event sequences.
- `Loam.Registry.Announce` — encode/decode property + explicit malformed cases.
- `Loam.Registry` — public API smoke tests + the two-BEAM integration test for real cross-node behavior.
- `Loam.Registry.Session` — not directly unit-tested. Behavior exercised by integration tests.

### Cross-node integration tests

Reuse PRD-0001's `Loam.Phoenix.IntegrationHelper` and two-process rig. Add a new helper, `Loam.Registry.IntegrationHelper`, that spawns two OS processes running `Loam.Registry` instances on different ports. The pattern is established; the new code is small.

### Property test harness

Builds on the PRD-0001 StreamData harness. New generators for `{register, name, pid_idx}` and friends. The shrinking story is the same: minimal failing event sequences.

### Prior art

PRD-0001 — every test pattern (two-process rig, `:partition`-tagged scripted tests, StreamData event-sequence properties, `:peer_death`-tagged peer-loss tests) is reused.

## Out of Scope

- **Duplicate keys.** Elixir Registry's `:duplicate` mode is a separate semantic that interacts with `dispatch/3`; its own PRD.
- **Wildcard register / lookup.** Same opaque-encoding reasoning as PRD-0001; deferred PRD.
- **`dispatch/3`.** Iterating registered pids and applying a user function. Useful, but interacts with duplicate-keys and is its own PRD.
- **`meta/3`.** Registry-level metadata. Not load-bearing for Phase 3 (Supervisor); deferred.
- **Remote-pid registration.** Registering a pid that lives on a different node. The eventual-pid-equality semantic across nodes is a serialization question this PRD declines.
- **Strong consistency / quorum-based registration.** Calls block until N peers ack. Different cost model, different failure modes; reshapes Registry rather than extends it.
- **CRDT-shaped conflict-free claims.** AWORmap, ORSet, etc. Phase 5+. LWW is the conscious smaller commitment.
- **Snapshot replay over a partitioned link.** A node that cannot reach a peer cannot snapshot from it. The bootstrap path requires `peers_zid` to include the target ZID. Recovery from partition is via in-flight retransmit (eventual-delivery regime) or `:drop`-then-snapshot (when `peers_zid` re-populates after peer-loss-and-rejoin).
- **Custom partitions / shards within a Registry instance.** Elixir Registry has `:partitions`. Useful for local contention; meaningless across the network. Out of scope.
- **Authorization / access control.** No allowlist of which ZIDs may register names. Same security posture as PRD-0001: future PRD when the substrate semantic is stable.
- **Eviction notification delivery guarantees.** The eviction message is best-effort. If the losing pid has died, the message is silently dropped (same as any send to a dead pid). If the losing pid has been re-registered with a different name, eviction for the original name is what's notified, not for the new name.

## Further Notes

**Why this is the right Phase 2.** Supervisor-on-Zenoh (Phase 3) needs a name-to-pid resolver. So does any non-trivial application built on loam. Registry is the smallest artifact that forces the conflict-resolution-under-partition question, which is the next-hardest semantic question after partition characterization. Doing it now means Phase 3 inherits an answer instead of relitigating.

**Why LWW and not CRDT.** LWW is wrong in a precisely-characterized way: under partition, both sides claim, and on heal, one observably loses. CRDT-shaped claims would be conflict-free at the cost of either: a different name semantics (set-of-pids per name), or a larger machinery (Riak-style siblings with caller-side merge). Both are real future PRDs. LWW is the smallest commitment that produces a usable Registry today, and its failure mode is observable rather than silent.

**Why eventually-consistent local-mirror lookup.** Querying Zenoh on every `lookup/2` would be honest about the network, and would block hot paths on a network round-trip. Registry callers expect ETS-speed lookups. The local mirror buys that, at the cost of staleness during partition, which is the failure mode every distributed registry has to accept somewhere; placing it at lookup is the most predictable choice.

**Why heartbeat + `:drop` regime for cross-node death.** Just `:drop` regime alone (PubSub `peers_zid` clearing) is too slow; default kernel TCP keepalive is minutes. Just heartbeat alone is unreliable: a heartbeat through a TCP-buffered partition will drain on heal, and could falsely re-confirm a peer that has actually died. The combination — `peers_zid` *and* recent heartbeat — gives both fast detection (heartbeat misses) and substrate-grounded truth (`peers_zid`).

**Why snapshot exchange on join.** Without it, a late-joining BEAM has no way to learn about pre-existing registrations; it would only see new register announces from that point forward. Snapshot exchange closes the join-time gap. The protocol is small (request, reply with owned entries) but its bootstrap-race semantics are subtle enough to deserve their own observation journal entry once exercised.

**Two-week-context-gap checklist:**
- The eight-item decision list in Solution.
- The nine-item gate in Shipped-When.
- The five most-likely-to-surprise future-me choices: LWW conflict resolution; opaque term encoding for names; local-pids-only; eventually-consistent local-mirror lookup; cross-node death detection rides PubSub `:drop`-regime + heartbeat.
- The non-goals list.

**Relationship to downstream tasks.** This PRD is broken into implementation tasks under `docs/tasks/NNNN-*.md` via `/prd-to-tasks`. Tasks implement gate items; the PRD's gates are acceptance criteria for the task set as a whole.

**What comes next after this PRD ships.** Phase 3: Supervisor on Zenoh. The question is what `start_child` and `terminate_child` mean when the supervisor's children are pids on remote BEAMs. Expected load-bearing decisions: restart strategy across partitions, the relationship between supervisor identity and Registry entries, whether failover triggers re-registration or relies on the new pid claiming the same name. Built on Registry's name-to-pid semantics characterized here.
