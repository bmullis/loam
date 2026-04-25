defmodule Loam.Phoenix.IntegrationHelper do
  @moduledoc false

  # Runs on a peer BEAM via :peer.call to start a Phoenix.PubSub instance with
  # the loam adapter, then broadcast a message back to the parent BEAM via
  # Zenoh. Lives under test/support/ so it's compiled to disk (standard test
  # modules are compiled in-memory and aren't visible to peer nodes).

  def run_remote(pubsub_name, listen_port, connect_port, topic, message) do
    Application.ensure_all_started(:phoenix_pubsub)
    Application.ensure_all_started(:zenohex)

    {:ok, _sup} =
      Phoenix.PubSub.Supervisor.start_link(
        name: pubsub_name,
        adapter: Loam.Phoenix.Adapter,
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{listen_port}"],
          connect: ["tcp/127.0.0.1:#{connect_port}"],
          multicast_scouting: false
        ]
      )

    Process.sleep(1500)
    :ok = Phoenix.PubSub.broadcast(pubsub_name, topic, message)
    Process.sleep(500)
    :ok
  end
end
