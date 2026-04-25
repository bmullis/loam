# loam

Exploring what OTP-shaped abstractions should look like when the underlying substrate is [Zenoh](https://zenoh.io/) instead of Erlang distribution.

## Status

Early. No Hex package yet. No public interfaces yet.

PRDs and RFCs land under `docs/` as specifications stabilize.

## Shape

- Single Elixir library built on top of [`zenohex`](https://github.com/biyooon-ex/zenohex). No FFI, no fork.
- Semantics first, performance later.
- Property-based testing (StreamData) for the semantic layer. Formal methods (TLA+ or Alloy) reserved for the hardest questions.

## Prior Art

- [Partisan](https://partisan.dev/) — alternative BEAM distribution, stays within a BEAM-to-BEAM frame.
- [Zenoh](https://zenoh.io/) — the substrate this project builds on.
