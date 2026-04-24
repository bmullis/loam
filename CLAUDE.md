# loam

A long-term research project exploring what OTP-shaped abstractions should look like when the underlying substrate is Zenoh instead of Erlang distribution.

## Thesis

The BEAM's distribution model assumes named nodes, full-mesh TCP, and cookie auth. It shows its age in constrained or partitioned networks: NAT traversal is painful, partition tolerance is weak, and mobile/intermittent nodes don't fit the model well. Projects like Partisan have explored alternatives but stay within a BEAM-to-BEAM frame.

Zenoh is a fundamentally different substrate: location-transparent pub/sub/query over arbitrary transports (TCP, UDP, QUIC, serial, shared memory), with routing that handles partitions and mobility natively.

The question: what should OTP primitives (Registry, Supervisor, GenServer, PubSub) mean when the substrate is Zenoh rather than Erlang distribution? The semantic choices aren't obvious and the tradeoffs aren't documented anywhere. The code and specifications are public; the reasoning behind them is worked out in a local design journal.

## What This Repo Is

- A single Elixir library built on top of `zenohex` (no FFI work, no fork).
- Decisions are recorded. PRDs and RFCs are public specifications; a design journal (gitignored, local only) captures the reasoning, rejected alternatives, and open questions behind them.
- Property-based testing (StreamData) from day one. Formal methods (TLA+ or Alloy) for the hardest semantic questions: partition behavior, convergence, registry consistency.

## What This Repo Is NOT

- Not a product. No users, no field testing.
- Not a Matter/Thread/TAK replacement.
- Not a general-purpose message queue.
- Not trying to replace Erlang distribution for everyone.
- Not an umbrella. No Phoenix app, no dashboard, no demo UI. Sibling modules can split into separate repos later once interfaces stabilize.

## Working Conventions

### Directory layout

- `lib/` — library code.
- `test/` — tests, property-based where it matters.
- `docs/prds/NNNN-slug.md` — product requirements docs. Tracked. Status in frontmatter.
- `docs/tasks/NNNN-slug.md` — tracer-bullet vertical slices derived from PRDs. Tracked.
- `docs/rfcs/NNNN-slug.md` — architecture refactor proposals. Tracked.
- `docs/journal/YYYY-MM-DD-slug.md` — design journal. Local only (gitignored). Captures reasoning, rejected alternatives, open questions. Decisions graduate from the journal into a PRD or RFC when they're ready to be public.

Files never move when status changes. Status lives in frontmatter so cross-references stay stable.

### Tracking

No GitHub issues or projects. Working artifacts live as local markdown under `docs/`. The `.claude/skills/` directory has skills (`write-a-prd`, `prd-to-tasks`, `improve-codebase-architecture`) that write into these folders.

### Commits

- Small commits, merged to main. No long-lived feature branches.
- Journal entries before code changes when a semantic question is on the table. Journal entries never appear in commits; they're a local working artifact.

### Pace

Hours here and there over months, not a sprint. Decisions should survive two-week context gaps. Favor writing things down.

## Traps to Avoid

- Don't scaffold broadly. Single library, no umbrella, no demo apps.
- Don't rewrite or fork `zenohex`. Build on top.
- Don't optimize prematurely. Semantics first, performance later.
- Don't skip the design journal. The code without the journal is just engineering.

## Roadmap

Rough multi-year shape. See PRDs for committed current state; journal for in-flight reasoning.

- **Phase 0** — Substrate familiarity. Get `zenohex` running between Mac and Pi. Pub/sub across LAN. Break the network intentionally. Build muscle memory before making semantic decisions.
- **Phase 1** — Phoenix.PubSub adapter. Small enough to finish, useful enough someone might use it. Forces the first semantic decisions (topic-to-key-expression mapping, delivery guarantees).
- **Phase 2** — Registry on Zenoh. Name-to-PID becomes key-expression-to-subscribers. Wildcards, partition behavior, call semantics.
- **Phase 3** — Supervisor semantics across partitions.
- **Phase 4** — GenServer-equivalent with Zenoh-backed mailbox.
- **Phase 5+** — Open. CRDTs, cross-partition `:global` equivalents, wherever the journal points.

## References

- Zenoh: https://zenoh.io/
- zenohex: https://github.com/biyooon-ex/zenohex
- Partisan (prior art): https://partisan.dev/
- Phoenix.PubSub: https://hexdocs.pm/phoenix_pubsub/
- StreamData: https://hexdocs.pm/stream_data/
