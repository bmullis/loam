defmodule Loam.Phoenix.Adapter do
  @moduledoc """
  `Phoenix.PubSub.Adapter` implementation backed by Zenoh.

  See `docs/prds/0001-phoenix-pubsub-adapter.md` for design rationale.

  ## Configuration

      config :my_app, MyApp.PubSub,
        adapter: Loam.Phoenix.Adapter,
        zenoh: [
          mode: :peer,
          listen: ["tcp/0.0.0.0:7447"],
          connect: ["tcp/192.168.1.10:7447"],
          # Optional escape hatch for any Zenoh config path not surfaced above.
          # Each entry is `{json5_path, json5_value}` and is applied after the
          # named keys. See Zenoh's config docs for the full schema.
          raw: [
            {"transport/link/tx/lease", "3000"}
          ]
        ],
        namespace: "loam/phx",          # optional
        node_name: nil                  # optional; defaults to the Zenoh ZID

  Only `adapter:` and `zenoh:` are required. `direct_broadcast/5` raises —
  this PRD does not commit to a node-targeting semantic; that lives with
  the future Registry PRD.

  > #### Pubsub instance name must match across BEAMs {: .warning}
  >
  > The keyexpr namespace is derived from `:name`. Two BEAMs with different
  > `Phoenix.PubSub` instance names will not see each other's broadcasts even
  > if their Zenoh sessions are peered (`peers_zid` populated). The split is
  > silent — broadcasts succeed locally and on the wire, they just land in a
  > different keyexpr namespace. Match `:name` on every BEAM that should share
  > a broadcast domain.
  """

  @behaviour Phoenix.PubSub.Adapter

  alias Loam.Phoenix.Session

  ## Phoenix.PubSub.Adapter callbacks

  @impl true
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Session, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  @impl true
  def node_name(adapter_name) do
    Session.fetch!(adapter_name).node_name
  end

  @impl true
  def broadcast(adapter_name, topic, message, dispatcher) do
    # Local dispatch is done by Phoenix.PubSub.broadcast/4 itself (it calls
    # dispatch after the adapter returns). The adapter's job is only to fan
    # out to remote nodes — same shape as Phoenix.PubSub.PG2.
    Session.publish(adapter_name, topic, message, dispatcher)
  end

  @impl true
  def direct_broadcast(_adapter_name, _node_name, _topic, _message, _dispatcher) do
    raise ArgumentError, """
    Loam.Phoenix.Adapter does not support direct_broadcast/5.

    Targeted node-to-node broadcast requires committing to a stable node-identity
    semantic, which is intentionally deferred to the Registry-on-Zenoh PRD.
    Use broadcast/4 instead.
    """
  end
end
