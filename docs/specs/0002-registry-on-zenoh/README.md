# Spec 0002: Registry on Zenoh

This module characterizes the LWW + eventual-consistency semantic of `Loam.Registry` (PRD-0002 gate item 9). It is *characterization*, not a contractual guarantee.

## What it models

Two nodes (each treated as both a BEAM and a Zenoh ZID), each with:

- A per-node Lamport counter.
- An eventually-consistent local mirror: a function from name to `<<lamport, ownerZid>>` or `None`.

Plus shared state:

- `inflight`: set of announce records emitted but not yet delivered everywhere.
- `connected`: a single boolean modeling the bidirectional link's IP reachability.
- `announced`: per-name historical log of every announce ever emitted, for property-checking.

Actions:

- `LocalRegister(n, name)` — claim `name` on node `n`. Precondition: `mirror[n][name] = None` (rejects local double-claim, same as the public API). Ticks lamport, writes to local mirror, emits a register announce.
- `LocalUnregister(n, name)` — release `name` on node `n`. Precondition: current entry is owned by `n`. Ticks lamport, clears local mirror, emits an unregister announce.
- `Deliver(ann, dst)` — apply an in-flight announce to a remote node's mirror under LWW. Requires connectivity and `dst # ann.src`. Lamport `observe`-on-deliver: `dst`'s lamport advances past `ann.lamport`.
- `PeerLoss(lost, observer)` — observer evicts every entry owned by `lost`. Models the heartbeat-miss + `peers_zid` path. Also drops in-flight announces from `lost` (the `:drop` regime).
- `Connect` / `Disconnect` — toggle the partition.

## What it deliberately omits

- **Wire format.** `Loam.Registry.Announce`'s encode/decode is unit-tested separately; the spec works with abstract announce records.
- **Keyexpr layout.** Same: `Loam.Registry.KeyExpr` is unit-tested.
- **Snapshot exchange.** Modeled informally: with `EventualDelivery` and weak fairness on `Deliver`, in-flight registers eventually deliver, achieving the same convergence the snapshot mechanism produces in code. Snapshot is an optimization for the join-time gap, not a separate semantic.
- **Tombstones.** After a successful `Unregister`, the slot is empty. A subsequent register from a peer with a *lower* observed lamport could win in principle. The `Deliver` action's `observe`-on-receive prevents this in normal operation: any node that has heard the unregister has its lamport advanced past it. The pathological case (a node that *never* heard the unregister) is left as a known semantic gap, documented in the open journal entry on tombstones.
- **Multi-receiver fan-out.** With `Cardinality(Nodes) = 2`, an announce has exactly one remote destination, so `Deliver` removes it from `inflight` after a single application. For larger `Nodes`, the spec would need a per-destination tracking set on each announce.

## Properties verified

**Safety**

- `TypeOK` — variables conform to their declared types.
- `Uniqueness` — every mirror has at most one entry per name (true by construction; mirror is a function).
- `LWWWellGrounded` — every entry currently held by any mirror has `lamport >= 1` and `owner \in Nodes`. Stronger LWW correctness — the surviving entry equals the announce that produced it — holds by construction: the only writers to `mirror[n][name]` are `LocalRegister` (which writes the freshly-emitted announce) and `Deliver/ApplyRegister` (which writes `ann.lamport / ann.owner` verbatim once the LWW gate passes). No code path fabricates entry values, so an explicit historical-log invariant adds nothing TLC can falsify.
- `NoSpuriousEviction` — true by construction; the only actions that remove an entry from a mirror are `LocalUnregister`, `Deliver` of an unregister, `Deliver` of a strictly-newer register (replacement), and `PeerLoss`. The spec's `Next` action set has no other writer, so a state-form invariant would always pass; the comment in the spec is the property.

**Liveness (weak)**

- `EventualDelivery` — `[](\A ann: ann \in inflight /\ <>[]connected ~> ann \notin inflight)`. The antecedent `<>[]connected` ("eventually-always connected") makes this conditional on connectivity stabilizing. Without it, an adversary that flaps `Connect`/`Disconnect` can keep messages in-flight forever, which is the documented (PRD) `:drop` behavior, not a bug.

**Why convergence is not a single-state invariant.** `PeerLoss(lost, observer)` removes `lost`'s entries from `observer`'s mirror, but `lost`'s own mirror may still hold them. Until `lost` re-engages and observes other peers' state, the two mirrors disagree. The PRD acknowledges this: post-peer-loss eviction is one-sided by design (the lost peer is, from observer's perspective, gone; convergence resumes when it returns and snapshot exchange runs). Asserting "always converged" would falsely mark this case as a bug.

## Running

Requires TLC (the TLA+ model checker). The repo gitignores `_tla/`; download `tla2tools.jar` from the [TLA+ releases](https://github.com/tlaplus/tlaplus/releases/latest) into `_tla/`, then from this directory:

```sh
java -cp ../../../_tla/tla2tools.jar tlc2.TLC -config RegistryOnZenoh.cfg RegistryOnZenoh.tla
```

Or via the TLA+ Toolbox: import the module, set the model to use `RegistryOnZenoh.cfg`, run.

**Verified configurations:**

| Nodes  | Names | MaxLamport | Distinct states | Wall time |
|--------|-------|------------|-----------------|-----------|
| `{1,2}`| `{a}` | 3          | 570             | <1s       |
| `{1,2}`| `{a,b}`| 3         | 23,242          | ~44s      |

Bumping `Names`, `MaxLamport`, or adding nodes deepens the search. Adding a third node requires adjusting `Deliver` to track per-destination delivery (currently the announce is removed from `inflight` after one Deliver, which is correct for two nodes only).

## Relationship to the PRD

Gate 9 of PRD-0002. The spec exists as a referent for Phase 3 (Supervisor on Zenoh), whose registration semantic is built on the LWW + eventual-consistency story characterized here. Future PRDs that introduce CRDT-shaped claims, partition-aware quorum, or strong consistency would split out their own modules; this one stays focused on the LWW baseline.

## Why characterization, not contract

Same posture as PRD-0001's spec. The spec was written *after* the implementation and integration tests, so it characterizes what the code does, not what we hoped it would do. The tombstone gap (mentioned above) is a real divergence from a stronger semantic the spec could have encoded; documenting it here is honest, demanding it of the code is a future PRD.
