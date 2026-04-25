# loam

Single Elixir library on top of `zenohex`.

## Directory layout

- `lib/`, `test/` — library code and tests.
- `docs/prds/NNNN-slug.md` — product requirements docs. Tracked. Status in frontmatter.
- `docs/rfcs/NNNN-slug.md` — refactor proposals. Tracked. Status in frontmatter.
- `docs/specs/NNNN-slug/` — formal specifications (TLA+/Alloy module, model config, readme).
- `docs/journal/YYYY-MM-DD-slug.md` — design journal. Local only (gitignored).

Files never move when status changes; status lives in frontmatter so cross-references stay stable.

## Conventions

- No GitHub issues or projects. Working artifacts are local markdown under `docs/`.
- Small commits, merged to main. No long-lived feature branches.
- When a semantic question is on the table, write a journal entry before code.
- Don't fork or modify `zenohex`. Build on top.
- Don't scaffold an umbrella, demo app, or dashboard.
- Property-based tests (StreamData) for invariants; formal specs for the hardest semantic questions.
- Decisions should survive two-week context gaps. Write things down.
