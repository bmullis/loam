# loam

A long-term research project exploring what OTP-shaped abstractions should look like when the underlying substrate is [Zenoh](https://zenoh.io/) instead of Erlang distribution.

## Status

Early. No Hex package yet. No public interfaces yet.

PRDs and RFCs land under `docs/` as specifications stabilize.

## Shape

- Single Elixir library built on top of [`zenohex`](https://github.com/biyooon-ex/zenohex). No FFI, no fork.
- Semantics first, performance later.
- Property-based testing (StreamData) for the semantic layer. Formal methods (TLA+ or Alloy) reserved for the hardest questions.

## Roadmap (rough)

0. **Substrate familiarity.** Get `zenohex` running across real hardware. Break the network on purpose.
1. **Phoenix.PubSub adapter.** First semantic decisions: topic-to-key-expression mapping, delivery guarantees.
2. **Registry on Zenoh.** Name-to-PID becomes key-expression-to-subscribers. Wildcards, partitions, call semantics.
3. **Supervisor semantics across partitions.**
4. **GenServer-equivalent with Zenoh-backed mailbox.**
5. Open.

## Prior Art

- [Partisan](https://partisan.dev/) — alternative BEAM distribution, stays within a BEAM-to-BEAM frame.
- [Zenoh](https://zenoh.io/) — the substrate this project builds on.

## License

TBD.
