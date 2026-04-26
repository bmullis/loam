---
id: 0001
slug: phoenix-pubsub-adapter
status: shipped
date: 2026-04-24
phase: 1
related:
  - docs/specs/0001-phoenix-pubsub-adapter/
---

# Phoenix.PubSub Adapter on Zenoh

## Problem Statement

`Phoenix.PubSub` distributes messages across a cluster using a pluggable adapter. The default adapter assumes BEAM distribution: named nodes, full-mesh TCP, shared cookie, no NAT, no mobility, no partitions-as-normal. That substrate is showing its age. Constrained networks (NAT, home routers, partial connectivity), mobile nodes that come and go, and links that intermittently drop don't fit the model. Operators work around it with elaborate networking, reverse tunnels, or bespoke message buses.

Zenoh is a substrate with a different set of starting assumptions: location-transparent pub/sub/query over arbitrary transports (TCP/UDP/QUIC/serial/shared-memory), routing that handles partitions and mobility as first-class, and peer/client/router deployment topologies that compose. If `Phoenix.PubSub` ran on Zenoh, its distribution model would inherit those properties — but only if the adapter is designed with the substrate's semantics rather than against them.

The question this PRD answers: **what do the semantics of a minimal `Phoenix.PubSub` adapter look like when the underlying transport is Zenoh rather than Erlang distribution, and what is the smallest working artifact that forces those semantic decisions to be made in public?**

This is Phase 1 of loam's multi-year roadmap. It is the first artifact in the project with an external interface (the `Phoenix.PubSub.Adapter` behaviour) and testable cross-node behavior. Phase 0 (substrate familiarity with `zenohex` on a Mac and a Pi) is a prerequisite that lives in the design journal; it is not a PRD because "I have intuitions I didn't have before" is journal-shaped, not spec-shaped.

## Solution

A library module, `Loam.Phoenix.Adapter`, implements `Phoenix.PubSub.Adapter` so an existing Phoenix application can swap the adapter and get cross-node broadcast over Zenoh instead of BEAM distribution. Two BEAMs configured with the adapter, reachable on a LAN, see each other's broadcasts. The adapter owns and supervises one `Zenohex.Session` per `Phoenix.PubSub` instance; no user-side lifecycle management is required. Sessions run in peer mode only in this PRD.

The slice is intentionally narrow: cross-node broadcast, plus an explicitly characterized and tested partition story. `direct_broadcast/5` raises `:not_supported`. Reliable delivery, bounded-history on reconnect, client/router topologies, multi-session sharing, cross-runtime subscribers, and wildcard topic subscription are all out of scope for this PRD and are called out explicitly below.

The semantic model the adapter presents, in one sentence, is: **best-effort at-most-once delivery across Zenoh, with behavior under partition characterized as "messages published during a partition window are lost; delivery resumes cleanly on heal."** This matches the Phoenix.PubSub-on-Erlang-distribution baseline. Users of loam are not promised more; they are, crucially, not promised less either. Any future departure from this baseline (bounded history, reliable mode) will be a new PRD with its own semantic entry in the journal.

Seven load-bearing design decisions are fixed by this PRD. Each gets a corresponding entry in the design journal recording why:

1. **Topic → Zenoh key-expression mapping is opaque encoding.** A Phoenix topic is an opaque binary. The adapter encodes it (URL-safe base64) into a single key-expression chunk under a per-instance namespace: `loam/phx/<pubsub_name>/<encoded>`. No scheme that inspects topic content is used. A helper `Loam.Phoenix.decode_key/1` exists for debug readability.
2. **Partition semantics are eventual in-order delivery for IP-reachability outages; `:drop` is reserved for catastrophic peer-loss.** Characterize, do not promise. Empirical reality on default TCP transport: the kernel's send buffer absorbs publishes and TCP retransmits deliver them after IP reachability returns. Subscribers see a latency spike, not a gap. Zenoh's session-level `lease`/`keep_alive` does not race TCP retransmission and cannot force `:drop` on a buffered partition — verified empirically (see `docs/journal/2026-04-25-zenoh-lease-tuning-tcp.md`). The `:drop` regime engages only when the underlying transport reports a hard failure: peer BEAM crashed, port closed, hardware off, kernel TCP keepalive timed out (default many minutes), or the link took a TCP RST. Under those conditions, `peers_zid` clears, the publisher's `congestion_control: :drop` activates, during-outage publishes are dropped, and delivery resumes after fresh peering. No replay, no publication cache, no querying subscriber. This is no worse than BEAM distribution's TCP-shaped failure modes and avoids opening the CRDT-shaped history question, which is parked in Phase 5+. Operators who want shorter `:drop` activation can tune Zenoh transport via the `:raw` escape hatch on `:zenoh` config (or switch to UDP transport, also via `:raw`); loam does not pick a default policy here.
3. **`node_name/1` returns the Zenoh ZID**, not `Node.self()`. A Zenoh adapter's "node" is a Zenoh session endpoint, not a BEAM node. The default does not lie. A `:node_name` config override is available for operators who want a friendly label.
4. **Echo avoidance uses Zenoh's subscription locality filter** (`locality: Remote`), not an originator field embedded in the payload. Use the substrate's mechanism; don't reimplement it at the Elixir layer.
5. **The wire format is an eight-byte envelope plus ETF**: `<<"LOAM", 1::8, :erlang.term_to_binary(payload)::binary>>`. Decoded with `[:safe]`. Malformed or unknown-version messages drop with a log line rather than crashing. The envelope buys non-flag-day evolution of the wire format later.
6. **The adapter owns session lifecycle.** One `Zenohex.Session` per `Phoenix.PubSub` instance, supervised under `Loam.Phoenix.SessionSupervisor` with `:permanent` restart. Peer mode only. Crash and restart of the session is transparent to the `Phoenix.PubSub` instance. Multi-session sharing is a forward-compatible future change.
7. **Subscription strategy is one broad subscription per adapter instance.** On boot, the adapter subscribes once to `loam/phx/<pubsub_name>/**`. Every cross-node broadcast flows through a single callback; local dispatch to `Phoenix.PubSub`'s existing Registry filters to interested subscribers. Per-topic Zenoh subscriptions would save wire traffic at the cost of a subscribe-race semantic this PRD explicitly declines to answer.

This PRD also introduces a new directory convention: `docs/specs/NNNN-slug/` as the home for formal specifications (TLA+ modules, TLC model configs, and a short readme framing what the spec characterizes). `docs/specs/0001-phoenix-pubsub-adapter/` is the first such directory and contains a TLA+ spec of the semantic model above. The spec is framed as characterization of observed behavior, not as a guaranteed contract.

## User Stories

Actors are defined as follows:

- **Application developer:** someone who has a Phoenix or Elixir application using `Phoenix.PubSub` and wants to try running it over Zenoh instead of BEAM distribution.
- **Operator:** the same or a different person deploying two or more BEAMs running a loam-adapter-backed `Phoenix.PubSub`.
- **loam contributor:** someone working on this library, including future-me picking it up after a two-week gap.
- **Phase 2 contributor:** someone beginning work on Registry-on-Zenoh and needing a stable referent for already-made semantic decisions.

Stories:

1. As an application developer, I want to configure `Phoenix.PubSub` to use `Loam.Phoenix.Adapter` with a small block of config, so that I can switch from BEAM distribution to Zenoh without restructuring my application.
2. As an application developer, I want the adapter to start and supervise its own `Zenohex.Session`, so that I do not have to wire zenohex lifecycle into my application's supervision tree.
3. As an application developer, I want `Phoenix.PubSub.broadcast/3` on node A to deliver to subscribers on node B when both are reachable over a LAN, so that my app's pub/sub behavior is preserved across nodes.
4. As an application developer, I want locally-subscribed processes to receive a broadcast exactly once (not twice, not zero times), so that handlers don't have to deduplicate.
5. As an application developer, I want a precise statement of partition behavior under loam's default TCP transport — IP-reachability outages produce eventual in-order delivery (no gaps, latency spike equal to outage duration), and `:drop`-with-gaps appears only on catastrophic peer-loss (BEAM crash, hardware off, TCP RST, kernel keepalive timeout) — so that I can reason about my application's behavior under realistic network conditions.
6. As an application developer, I want the documented partition behavior to be no worse than BEAM distribution's, so that moving to Zenoh is not a regression in reliability semantics.
7. As an application developer, I want `Phoenix.PubSub` topics I already use to work unchanged — including topics containing colons, slashes, or arbitrary binary data — so that I do not have to audit my topic strings.
8. As an application developer, I want to be able to run multiple `Phoenix.PubSub` instances in the same BEAM without their traffic cross-contaminating, so that multi-tenant or multi-subsystem apps behave predictably.
9. As an application developer, I want a clear error if I call `direct_broadcast/5`, so that I am not silently getting no-ops and I know there is a planned future semantic.
10. As an operator, I want to specify the Zenoh peer endpoints (listen and connect) in my application config, so that I control the network topology without editing library code.
11. As an operator, I want a stable node identifier that does not pretend to be a BEAM node name, so that my metrics, logs, and dashboards reflect what is actually happening at the substrate level.
12. As an operator, I want to optionally override the node name with a friendly string, so that logs and tracing show meaningful labels even though the default identifier is a ZID.
13. As an operator, I want the `Zenohex.Session` to restart automatically if it crashes, without taking down the whole `Phoenix.PubSub` instance, so that a transient NIF failure does not cascade.
14. As an operator, I want the adapter's Zenoh traffic to live under a namespace (`loam/phx/<pubsub_name>/...`) so that I can distinguish it from other Zenoh traffic on shared infrastructure.
15. As an operator, I want malformed or foreign publications on the adapter's keyexpr prefix to be dropped and logged rather than crashing a subscriber process, so that a misbehaving neighbor on shared infrastructure does not take my nodes down.
16. As a loam contributor, I want a unit test for envelope encode/decode that covers the happy path, the malformed case, and the unknown-version case, so that the wire-format evolution story is protected by tests from day one.
17. As a loam contributor, I want a two-BEAM happy-path integration test that runs in the default `mix test` and verifies real cross-process Zenoh delivery on a single machine, so that I can iterate on the adapter without hardware.
18. As a loam contributor, I want a scripted partition test, runnable locally with `pfctl`/`iptables`, that asserts the characterized partition behavior, so that regressions in partition semantics are caught rather than discovered in production.
19. As a loam contributor, I want property-based tests (StreamData) over the no-partition case that exercise combinations of subscribe/publish/unsubscribe and assert delivery, no-duplication, and per-publisher FIFO-per-topic, so that the happy-path invariants are not asserted by example alone.
20. As a loam contributor, I want a Mac↔Pi real-hardware run of the happy-path and partition tests, with observations written to the journal, so that a one-time real-network validation exists and surprises are recorded.
21. As a loam contributor, I want every load-bearing semantic decision documented as a `decision` journal entry before or alongside the code that implements it, so that the reasoning survives a two-week context gap.
22. As a loam contributor, I want Phase 0 prerequisite journal entries (zenohex across two local sessions; Mac↔Pi scouting; intentional network break and heal) written *before* any adapter code is merged, so that the implementation is grounded in observed substrate behavior, not guessed behavior.
23. As a loam contributor, I want the adapter to use Zenoh's subscription locality filter to avoid echo, so that I do not carry originator metadata in the wire payload and so that the echo-avoidance mechanism is visible as Zenoh configuration rather than as Elixir control flow.
24. As a Phase 2 contributor, I want "node" to already mean "Zenoh session endpoint identified by ZID" when I begin work on Registry-on-Zenoh, so that I do not have to relitigate the node-identity semantic.
25. As a Phase 2 contributor, I want a TLA+ spec at `docs/specs/0001-phoenix-pubsub-adapter/` to exist as a referent, so that Registry's partition semantics can be expressed relative to already-characterized PubSub semantics.
26. As a Phase 2 contributor, I want `docs/specs/NNNN-slug/` established as a directory convention, so that the place for formal specs is not a new decision when Registry needs one.
27. As future-me, I want the PRD to state its nine shipped-when items precisely, so that "is this PRD done?" has a boolean answer rather than requiring judgment calls across sessions.
28. As future-me, I want the PRD to list non-goals explicitly, so that scope creep during implementation is easy to identify and redirect into a new PRD.

## Implementation Decisions

### Modules

**`Loam.Phoenix.Adapter`** — implements the `Phoenix.PubSub.Adapter` behaviour. The module's external surface is the behaviour callbacks (`node_name/1`, `broadcast/4`, `direct_broadcast/5`) plus `child_spec/1`. `direct_broadcast/5` raises `:not_supported` and has a docstring pointing at the corresponding journal entry. Internally the adapter delegates wire-format encoding, subscription setup, and local dispatch to smaller deep modules below.

**`Loam.Phoenix.Envelope`** — pure functions for wire format. `encode/1` takes an arbitrary term and returns the eight-byte-prefixed binary. `decode/1` takes a binary, returns `{:ok, term}` or `{:error, reason}`. Reasons distinguish malformed (`:bad_magic`), version mismatch (`{:bad_version, n}`), and unsafe payload (`:unsafe_term`). This module is deliberately deep: one responsibility (round-trip the wire format), narrow interface (two functions), no runtime dependencies. It is pure and property-testable.

**`Loam.Phoenix.KeyExpr`** — pure functions for topic-to-keyexpr translation. `encode/2` takes a pubsub-instance name and a topic binary and returns the keyexpr string. `decode/1` takes a keyexpr and returns the pubsub-instance name and the decoded topic. The namespace prefix (`loam/phx`) is either a module attribute or an injectable parameter to avoid hardcoding. Also deliberately deep: one responsibility, narrow interface, pure.

**`Loam.Phoenix.SessionSupervisor`** — a `Supervisor` owning the `Zenohex.Session` child for a specific `Phoenix.PubSub` instance. Restart strategy `:permanent` for the session; `:one_for_one`. Started under `Phoenix.PubSub`'s own supervision tree via the adapter's `child_spec/1`.

**`Loam.Phoenix.Dispatcher`** — receives raw Zenoh sample callbacks, delegates to `Envelope.decode/1`, delegates to `KeyExpr.decode/1`, and hands the result to `Phoenix.PubSub.local_broadcast/*`. Isolates the receive-path logic so that the `Adapter` module's behaviour callbacks stay thin.

### Interfaces

- **User-facing configuration** is a keyword list under the application's `Phoenix.PubSub` config, keyed off the adapter:

  ```elixir
  config :my_app, MyApp.PubSub,
    adapter: Loam.Phoenix.Adapter,
    zenoh: [mode: :peer, listen: ["tcp/0.0.0.0:7447"], connect: ["tcp/192.168.1.10:7447"]],
    namespace: "loam/phx",
    node_name: nil
  ```

  Only `adapter:` and `zenoh:` are required. `namespace:` defaults to `"loam/phx"`. `node_name:` defaults to `nil`, which is resolved to the Zenoh ZID at session start. The `zenoh:` keyword is passed through to `Zenohex` without interpretation, so that `zenohex` evolutions are not blocked by the adapter's config surface.

- **Wire format** is exactly `<<"LOAM", Version::unsigned-integer-8, Payload::binary>>` where `Payload = :erlang.term_to_binary(term)`. Version 1 is the only defined version. `decode/1` rejects other magic bytes and other versions without attempting to decode the payload.

- **Key expression namespace** is `<namespace>/<pubsub_name>/<encoded_topic>` where `<encoded_topic>` is URL-safe base64 without padding. Multiple `Phoenix.PubSub` instances in the same BEAM do not cross-talk by construction.

- **`node_name/1`** returns a string. Default is the ZID as string. Override replaces it verbatim; no validation beyond non-nil.

- **`direct_broadcast/5`** raises `ArgumentError` with message `"Loam.Phoenix.Adapter does not support direct_broadcast in this PRD; see docs/journal/..."` — the exact journal path is filled in when the journal entry is written.

### Architectural constraints

- **No FFI, no zenohex fork.** The adapter builds on `zenohex` as a dep at whatever the pinned version is. If a capability is needed from Zenoh that `zenohex` does not yet expose, the right answer is to contribute upstream, not vendor a fork.
- **No umbrella, no demo app.** The PRD produces library code and tests, nothing else.
- **Peer mode only.** Client mode and router mode are explicitly out of scope. Their absence is a deliberate simplification to keep the semantic model small; they are a future PRD when the use case arises.
- **Sessions are per-instance.** A `Phoenix.PubSub` instance maps 1:1 to a `Zenohex.Session`. This means two instances in one BEAM use two sessions and surface as two ZIDs. That is semantically correct and keeps this PRD uncoupled from any future multi-session-sharing work.
- **Best-effort delivery only.** Any configuration knob that would switch Zenoh into reliable or bounded-history mode is out of scope and explicitly not wired up.

### Journal entries required before or alongside code

One `decision` entry per item in the "Solution" numbered list (seven entries), plus one explaining the `:not_supported` punt for `direct_broadcast`, plus the three Phase 0 `observation` or `decision` entries listed in the Shipped-When gate. Journal entries do not block the PRD being `status: draft`, but they gate the PRD moving to `status: in_progress` (for the semantic entries) and `status: shipped` (for all nine gate items).

### Shipped-When gate (authoritative list)

1. `Loam.Phoenix.Adapter` implementing `Phoenix.PubSub.Adapter` and `Loam.Phoenix.SessionSupervisor` exist and are exercised by the tests below.
2. Unit tests covering envelope encode/decode round-trip, envelope malformed-drop, envelope unknown-version-drop, keyexpr encode/decode round-trip for edge cases (empty topic, binary-content topic, unicode topic), config parsing (required fields, defaults, overrides), and a behaviour-compliance smoke test.
3. Two-BEAM happy-path integration test. Two OS processes running `elixir` with separate `Zenohex.Session`s on different ports, spawned by the test harness. Runs in default `mix test` on CI-class hardware. Asserts cross-process broadcast delivery and locality-filter correctness (no self-delivery on the publishing node).
4. Scripted partition test, ExUnit-tagged `@tag :partition`, excluded from default `mix test`. Uses `pfctl` on Darwin or `iptables` on Linux to block the Zenoh port for a window. The test exercises Solution item 2's *eventual delivery* semantic — the dominant case for IP-reachability outages on default TCP transport. Asserts: messages published before the partition reach the far side; messages published during the partition do not crash the publisher (broadcast returns `:ok`, no process death, no memory blowup); after the block is lifted, all during-partition messages reach the far side within a generous heal-timeout (e.g., 10s post-unblock), in publish order, exactly once each. The test does **not** assert message gaps on partition, because empirically (see `docs/journal/2026-04-25-zenoh-lease-tuning-tcp.md`) the `:drop` regime is unreachable via lease tuning over a TCP-buffered partition. A separate test for the `:drop` regime — killing the far-side BEAM mid-flight and asserting publishes after kill but before heal are dropped — is tracked as a follow-up gate item (4b) below. Documented run instructions live in the test module's moduledoc or an adjacent markdown file.

4b. Peer-death drop test, ExUnit-tagged `@tag :peer_death`, excluded from default `mix test`. Spawns the two-process rig, kills the subscriber's OS process via `Port.close` or `System.cmd("kill", ...)`, then publishes from the surviving side. Asserts: `peers_zid` clears within a reasonable timeout; publishes after peer-death return `:ok` (do not crash, do not block indefinitely); when a fresh subscriber starts on the same endpoint, only post-restart publishes are delivered (during-down publishes are dropped). This is the test that exercises the `:drop` regime, separated from the partition test because the mechanisms are different (TCP RST / EOF, not buffered retransmits).
5. StreamData property test for the no-partition case. Generators produce sequences of `{subscribe, pid, topic}`, `{unsubscribe, pid, topic}`, and `{publish, topic, payload}` events dispatched across the two-BEAM rig. Invariants: every publish is delivered to every currently-subscribed pid for the publish's topic within timeout T; no pid receives a publish twice; for any single publisher, deliveries to any single subscriber-topic pair arrive in publish order.
6. Mac↔Pi journal writeup. The happy-path and partition tests (or manual equivalents) are run once on real Mac↔Pi hardware over LAN. A single journal entry records reconnect timings, any Zenoh log anomalies, and any behavior that diverges from the single-machine test assertions.
7. Seven semantic-decision journal entries (one per numbered item in the "Solution" section), plus one for the `direct_broadcast` punt.
8. Three Phase 0 prerequisite journal entries, written before any adapter code is merged:
   a. Two BEAMs on one machine running `zenohex` pub/sub across two sessions on two ports.
   b. Mac↔Pi peer scouting over LAN — what `zenohex` surfaces for peer discovery, what logs look like, any tuning surprises.
   c. Intentional network break (unplug, `pfctl`, or `iptables`) and heal — what happens to in-flight `publisher.put/2` calls, what the reconnect timing looks like, what is and is not observable from the Elixir side.
9. TLA+ spec at `docs/specs/0001-phoenix-pubsub-adapter/` with a `.tla` module, a `.cfg` TLC model config, and a readme. Spec models two nodes, a dynamic connectivity relation, a pub/sub API with subscribe/unsubscribe/publish/deliver actions, and the locality-filter semantic. Properties verified by TLC:
   - **Safety 1 (at-most-once):** for any (publish, subscriber) pair, the subscriber's `received` log contains the publish at most once.
   - **Safety 2 (no mis-delivery):** no process receives a publish for a topic it is not currently subscribed to.
   - **Safety 3 (no self-delivery):** a Zenoh session does not receive its own publications through the remote-subscription callback.
   - **Liveness (weak):** if the connectivity relation is `connected` continuously from time T and subscriber S remains subscribed to topic t, every publish to t after T is eventually delivered to S.
   The spec's readme states, in one sentence, that the model characterizes observed Zenoh behavior under the PRD's configuration and is not a contractual guarantee. The spec is written after Phase 0 journal entries exist, so it models what was observed, not what was guessed.

## Testing Decisions

### What makes a good test here

Tests assert externally observable behavior: what messages reach what subscribers, what happens when the network is broken, what happens when the wire is corrupted. Tests do not assert the identity of internal processes, the shape of internal state, or the specific Zenoh APIs used to accomplish a given outcome. The adapter's internal structure is expected to evolve (session sharing, per-topic subscriptions, alternative echo-avoidance mechanisms) without invalidating the tests.

Property tests are preferred over example-based tests for invariants that can be stated as universal quantification over event sequences (delivery, no-duplication, FIFO-per-publisher-per-topic). Example-based tests are preferred for specific scripted scenarios (partition and heal, malformed envelope).

Tests are real where real is affordable. The two-BEAM happy-path test uses two actual OS processes with two actual `Zenohex.Session`s — not a fake transport, not a mocked `zenohex`. The one thing that is *not* real by default is the Pi: the Mac↔Pi run is a one-time journal-backed validation, not a CI check. This is a deliberate split between fast-and-automated and slow-and-human.

### Modules with dedicated tests

- `Loam.Phoenix.Envelope` — pure property-tested and example-tested. Round-trip property for arbitrary terms. Example tests for the malformed and unknown-version paths. This is the first module to write and test because the wire format is easy to get subtly wrong and is load-bearing for everything else.
- `Loam.Phoenix.KeyExpr` — pure property-tested for round-tripping arbitrary binaries and arbitrary pubsub-instance names. Example tests for edge cases (empty, unicode, very long).
- `Loam.Phoenix.Adapter` — behaviour-compliance smoke tests; most of its real behavior is exercised by the two-BEAM integration test rather than by module-level unit tests.
- `Loam.Phoenix.SessionSupervisor` — not directly unit-tested; its behavior is exercised by the integration tests. A crash-and-recover test is desirable if easy; not a gate item.
- `Loam.Phoenix.Dispatcher` — tested indirectly through the two-BEAM integration tests. Dispatcher failures surface as missing deliveries.

### Cross-node integration tests

Implemented as one test module that spawns two OS processes using `System.cmd` (or `Port`, whichever is simpler), each running a small Elixir script that starts a `Phoenix.PubSub` instance with `Loam.Phoenix.Adapter` and communicates results back to the parent via stdout or a known file. This is the least magic and least dependent-on-test-framework option; there is no prior art in this repo to copy from (the repo has one trivial `mix test` file), so this PRD establishes the pattern.

The partition test builds on the same two-process rig and adds a pre-test `pfctl`/`iptables` invocation to block the relevant port, with a post-test cleanup. The test is tagged `:partition` and excluded from default runs; the tagged run requires elevated privileges.

### Property test harness

`StreamData` is already a dev/test dep. The property test uses `StreamData`'s event-sequence generators to build lists of `{subscribe, publish, unsubscribe}` events and dispatches them against the two-BEAM rig. Shrinking produces minimal failing sequences. This is the first `StreamData` usage in the repo; the PRD establishes the pattern.

### Prior art

None in this repo — the PRD is the first real implementation work. The patterns established here (two-process integration rig, `:partition`-tagged scripted test, StreamData event-sequence property tests) become the prior art for Phase 2 and beyond.

## Out of Scope

The following are explicit non-goals for this PRD. Each has a reason worth recording, so that a future PRD that wants to take one on starts with the question already framed.

- **Client or router Zenoh modes.** Peer is the single topology this PRD models, tests, and specifies. Client/router add deployment shape, bootstrap semantics, and failure modes that deserve their own PRD. The config surface does not preclude future modes (`mode:` is a passthrough), but any non-`:peer` value is rejected for now.
- **Multi-session sharing.** One `Zenohex.Session` per `Phoenix.PubSub` instance. A future PRD can introduce session sharing (e.g., one `Zenohex.Session` used by both `Phoenix.PubSub` and an eventual `Loam.Registry`) via an optional `session:` config key; this PRD's config shape is forward-compatible with that.
- **Runtime reconfiguration.** Endpoints and mode are read at start. Changing them requires restarting the `Phoenix.PubSub` instance. Hot reconfiguration is a separate problem that interacts with supervision, connection state, and in-flight messages, and is not worth solving before the basic semantics are settled.
- **Reliable delivery mode.** Zenoh's reliable/push reliability is not wired up. Reliable pub/sub changes backpressure, memory, and failure-mode semantics, which reshape what the adapter is rather than extend it. Belongs in a dedicated PRD.
- **Bounded history on reconnect.** Using `zenoh-ext` publication cache or querying subscribers to give reconnecting subscribers partition-window history is a legitimate direction but opens the CRDT-shaped "what does history mean during and after partition?" question parked in Phase 5+.
- **Cross-runtime subscribers.** A non-BEAM Zenoh peer (Rust, Python, C) cannot subscribe to the adapter's keyexpr prefix and decode the traffic, because the wire format uses `:erlang.term_to_binary`. Interop is a separate problem that would require a language-neutral payload schema and belongs in a separate PRD if demand appears.
- **Wildcard topic subscription.** `Phoenix.PubSub`'s public API does not expose wildcard subscription; accepting Zenoh-style wildcards in `Phoenix.PubSub.subscribe/2` is out of scope. The opaque-encoding topic mapping (Solution item 1) deliberately forecloses naive wildcarding.
- **`direct_broadcast/5` semantics.** Raising `:not_supported` is the chosen behavior; designing the targeted-broadcast semantics (which requires committing to what a "node address" is at the adapter level) reopens the node-identity question that Phase 2's Registry will own. Belongs in the same future PRD that resolves Registry node identity.
- **Security and access control.** No auth, no TLS configuration, no allowlist of peers. Whatever `zenohex` surfaces passes through verbatim; any tightening is an operator responsibility. A real security story belongs in a dedicated PRD once the semantic story is stable.
- **Formal verification beyond characterization.** The TLA+ spec models what Zenoh does under this adapter's configuration. It does not model Zenoh's internal routing algorithms, and it is not a proof that `zenohex` or Zenoh itself are correct.

## Further Notes

**Why this is the first PRD.** Phase 0 (substrate familiarity) is real work but does not have the shape of a spec: success is "I now have intuitions I didn't have before," which is a journal outcome, not a PRD outcome. Phase 1 is the first artifact with an external contract (the `Phoenix.PubSub.Adapter` behaviour), a testable semantic, and a non-trivial surface of load-bearing decisions. Writing it forces the decisions in public, which is the whole point of loam.

**Why peer mode is enough for Phase 1.** Peer mode is the simplest Zenoh topology and the most honest starting point for "what does broadcast look like on a partition-tolerant substrate?" Clients-and-routers add a deployment story that is independently interesting and independently deserving of its own semantic walk-through. Doing them both at once would muddle both.

**Why opaque topic encoding is worth the ugliness.** Inspectable keyexprs (slash-translated topics, direct-string topics) feel nicer. They also foreclose on future freedom: once users rely on the keyexpr structure to subscribe from non-loam Zenoh clients, the adapter's topic encoding is an external contract. Opaque encoding makes that impossible, which preserves the adapter's right to evolve the keyexpr scheme in later phases without breaking third-party observers. The debug helper `Loam.Phoenix.decode_key/1` addresses the ergonomic cost.

**Why the spec comes after Phase 0, not before.** A spec written before the substrate is understood risks modeling what we think Zenoh does, which may not be what Zenoh does. The spec becomes aspirational. A spec written after Phase 0 models what was observed, which is its actual job.

**Why `docs/specs/` as a new convention is worth introducing now.** Phase 2 (Registry) and Phase 3 (Supervisor) will have far harder semantic questions and will benefit from formal specification. The cost of establishing "where do specs live, how are they run, what do their readmes say" is higher when the semantic question is hard than when it is easy. Paying that cost here, on the easiest semantic question in the roadmap, leaves Phase 2 free to focus on the spec's content rather than its infrastructure.

**Two-week-context-gap checklist** (things future-me should be able to find without re-reading this PRD in full):
- The seven-item decision list in Solution.
- The nine-item gate in Shipped-When.
- The five most-likely-to-surprise future-me choices: opaque topic encoding; ZID as node name; locality filter for echo avoidance; `direct_broadcast` raises; characterization-not-guarantee framing of the spec.
- The non-goals list, as the canonical answer to "should this scope grow?"

**Relationship to downstream tasks.** This PRD is broken into implementation tasks under `docs/tasks/NNNN-*.md` via `/prd-to-tasks`. Tasks implement the gate items. The PRD's gate items are the acceptance criteria for the task set as a whole; individual task files inherit acceptance criteria for their slice. The PRD's status is `draft` until the Phase 0 journal entries exist and the first task begins, then `in_progress`, then `shipped` when all nine gate items land.

**What comes next after this PRD ships.** Phase 2: Registry on Zenoh. The question is what `Registry.register/3` and `Registry.lookup/2` mean when the name-to-pid mapping is a Zenoh key expression instead of an ETS table. Expected load-bearing decisions: wildcard register semantics, claim conflict resolution across partitions, call-vs-cast cost model, whether Registry presupposes a PubSub adapter (probably yes, but worth stating explicitly). The semantic work done in this PRD — node identity, partition characterization, wire format — is the referent Registry will build on.
