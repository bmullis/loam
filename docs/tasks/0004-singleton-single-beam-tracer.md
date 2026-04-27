---
status: todo
type: AFK
created: 2026-04-26
parent_prd: docs/prds/0003-singleton-on-zenoh.md
blocked_by:
  - docs/tasks/0002-monitor-debounce-window.md
  - docs/tasks/0003-resolve-singleton-paradigm-naming.md
---

## What to build

Ship `Loam.Singleton` (or its renamed equivalent from slice 0003) end-to-end on a single BEAM. Module surface: `child_spec/1`, `start_link/1`. Internal modules per parent PRD §Implementation Decisions: `Loam.Singleton.Server` (GenServer holding singleton state) and `Loam.Singleton.LocalSup` (per-instance Supervisor running the child while this BEAM holds the name). Configuration: `:registry`, `:name`, `:child_spec`, `:max_restarts`, `:max_seconds`, `:start_jitter_ms` (default 500), `:vacancy_debounce_ms` (default 1000).

Behavior on a single BEAM: starts, waits jitter, registers in `Loam.Registry`, starts `LocalSup` with the configured child spec, monitors the registered name. On local child crash, `LocalSup` restarts subject to max-restarts/max-seconds. On `LocalSup` giving up, the singleton unregisters (vacating the name). Telemetry events emitted: `[:loam, :singleton, :registered]`, `[:loam, :singleton, :child_started]`, `[:loam, :singleton, :evicted]` (the last only fires in slice 0006; emit-path wired here).

This is the smallest tracer through every layer (Registry monitor, Server, LocalSup, telemetry, child spec) on a single node. Cross-node behavior is exercised in slices 0005+.

See parent PRD §Solution decisions 1, 3, 4 and §Implementation Decisions.

## Acceptance criteria

- [ ] `Loam.Singleton.start_link/1` accepts the configuration shape from the PRD and starts cleanly.
- [ ] `child_spec/1` returns a spec mountable in any application supervisor.
- [ ] On start, registers `:name` in the configured `Loam.Registry`; `Loam.Registry.lookup/2` returns the child pid.
- [ ] Local child crash is restarted by `LocalSup` with the same registered name (re-registered after restart, no spurious `:name_vacant` to other watchers within debounce).
- [ ] Max-restarts exhaustion causes `LocalSup` to give up; singleton unregisters; name vacates.
- [ ] Telemetry events `[:loam, :singleton, :registered]` and `[:loam, :singleton, :child_started]` fire with documented metadata.
- [ ] Standard child-spec shapes accepted: `{Module, args}`, MFA-style maps, full `%{id, start, ...}` maps.
- [ ] Decision journal entries written for: (a) free-for-all + jitter, (b) `:permanent`-only, (c) local Supervisor reuse.
- [ ] Public API documented in moduledoc; loud disclaimer on stateless / `terminate/2`-flush usage.
- [ ] Single-BEAM tests: register-on-start, crash-and-restart, max-restarts-exhaustion.

## User stories addressed

- User story 1
- User story 8
- User story 9
- User story 10
- User story 17
- User story 19
