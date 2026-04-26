# Spec 0001: Phoenix.PubSub Adapter on Zenoh

This module characterizes observed Zenoh behavior under the configuration described in PRD-0001 and is not a contractual guarantee.

## What it models

Two Zenoh sessions (nodes), each hosting a set of pids that subscribe to topics. A dynamic connectivity relation toggles IP reachability. Publications enter an in-flight set on emit; remote delivery consumes the in-flight tuple iff connectivity holds at delivery time and the destination is not the publishing node (locality filter, PRD Solution item 4). Local delivery on the publishing node bypasses the in-flight set, modeling `Phoenix.PubSub.local_broadcast`.

The model deliberately omits:

- Wire-format encoding/decoding (separate unit-tested concern).
- Topic → keyexpr translation (separate unit-tested concern).
- Session restart and ZID rotation (covered by the peer-death journal entry and integration test).
- TCP buffering details. `connected = FALSE` models an outage; in-flight tuples persist across the outage and drain on `connected = TRUE` (matching the eventual-delivery regime characterized in `2026-04-26-partition-semantics-decision.md`).

## Properties verified

**Safety**

- `AtMostOnce`: for any (pid, publication) pair, the pid's receive count is at most 1. No subscriber sees a publication twice.
- `NoMisDelivery`: the delivered log on a node only contains entries for valid publications.
- `NoSelfDelivery`: a node never receives its own publications via the remote `Deliver` path. Enforced by `dstNode # srcNode` in the `Deliver` action.

**Liveness (weak)**

- `EventualDelivery`: if connectivity holds and a publication is in-flight for a remote node, it is eventually delivered (in-flight tuple is removed). Modeled with weak fairness on `Connect` and on each `Deliver` step.

## Running

Requires TLC (the TLA+ model checker). With `tla2tools.jar` on the classpath:

```sh
java -cp tla2tools.jar tlc2.TLC -config PhoenixPubSubAdapter.cfg PhoenixPubSubAdapter.tla
```

Or via the TLA+ Toolbox: import the module, set the model to use `PhoenixPubSubAdapter.cfg`, run.

The default config (`Nodes = {n1, n2}`, `Pids = {p1, p2}`, `Topics = {t1, t2}`, `MaxPubs = 3`) explores a small enough state space to finish in seconds. Bumping `MaxPubs` or `Pids` deepens the search.

## Relationship to the PRD

Gate 9 of PRD-0001's shipped-when list. The spec exists as a referent for Phase 2 (Registry on Zenoh), whose partition semantics will be expressed relative to the regimes characterized here. Future PRDs that promote a regime to a contract will add a property to this spec or split out a new one.

## Why characterization, not contract

A spec written before Phase 0 (substrate familiarity) would have modeled what we thought Zenoh does. The journal entries `2026-04-25-partition-and-heal.md` and `2026-04-25-zenoh-lease-tuning-tcp.md` showed at least one case where the original framing was wrong: the `:drop`-with-gaps regime is unreachable via session-level lease tuning over a TCP-buffered partition. This spec models the eventual-delivery regime that Zenoh actually exhibits, with the `:drop` regime treated as a separate case (peer-death, modeled informally by removing a node from the connectivity relation indefinitely; not modeled in this version of the spec, captured by the peer-death integration test instead).
