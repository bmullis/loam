defmodule Loam.Anchor do
  @moduledoc """
  Eventually-exactly-one-live-owner primitive on top of `Loam.Registry`.

  An Anchor races to claim a cluster-wide name and runs a configured child
  process while it holds the name. If the BEAM holding the name dies, the
  name vacates and surviving Anchors race to take over. On Last-Writer-Wins
  conflict (partition heal), the loser terminates its child and steps back
  to standby.

  See `docs/prds/0003-anchor-on-zenoh.md` for the full semantic.

  ## Usage

      children = [
        {Loam.Registry, name: MyApp.Registry},
        {Loam.Anchor,
         registry: MyApp.Registry,
         name: :my_singleton,
         child_spec: {MyApp.Worker, []}}
      ]

  Look up the running child via `Loam.Registry.lookup/2` using the same
  `:name` you configured.

  ## Stateless workloads only

  Anchor does not transfer state between owners. On eviction, the loser's
  `terminate/2` runs (subject to the supervisor's shutdown timeout) and
  the winner's child starts cold from its child spec. There is no in-band
  state handoff. Use Anchor for stateless workloads, or workloads where
  externalized state plus a `terminate/2` flush is acceptable.

  ## Configuration

    * `:registry` (required) — the `Loam.Registry` instance to claim names in.
    * `:name` (required) — the Erlang term to claim.
    * `:child_spec` (required) — standard child-spec shape (`{Module, args}`,
      module atom, or full `%{id: ..., start: ..., ...}` map).
    * `:max_restarts` (default 3) — forwarded to the per-instance Supervisor.
    * `:max_seconds` (default 5) — forwarded to the per-instance Supervisor.
    * `:start_jitter_ms` (default 500) — uniform random `[0, jitter]` delay
      before the first registration attempt; damps boot-storm contention.
    * `:vacancy_debounce_ms` (default 1000) — forwarded to
      `Loam.Registry.monitor/3`. Peaceful handoff window.

  ## Telemetry

    * `[:loam, :anchor, :registered]` — measurements `%{system_time: integer}`,
      metadata `%{registry: atom, name: term}`. Emitted when this BEAM
      successfully registers and starts the local child.
    * `[:loam, :anchor, :child_started]` — measurements `%{system_time: integer}`,
      metadata `%{registry: atom, name: term, child_pid: pid}`. Emitted on
      each (re)start of the local child while we hold the name.
    * `[:loam, :anchor, :evicted]` — measurements `%{system_time: integer}`,
      metadata `%{registry: atom, name: term, reason: :lww_lost | :owner_lost_locally}`.
      Emitted when this BEAM terminates the child due to LWW eviction or
      local supervisor giving up. (LWW path wires in slice 0006.)
  """

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, {__MODULE__, Keyword.fetch!(opts, :name)}),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Loam.Anchor.Server.start_link(opts)
end
