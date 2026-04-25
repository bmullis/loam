defmodule Loam.Phoenix.IntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Spins up a second BEAM via :peer (no distribution / no EPMD), runs
  # Phoenix.PubSub + the loam adapter on it, and verifies a cross-process
  # broadcast over Zenoh reaches a subscriber on the test BEAM. Both BEAMs
  # use loopback TCP, multicast scouting disabled, explicit connect endpoints.

  test "broadcast from a peer BEAM is delivered to a subscriber on the local BEAM" do
    parent_port = unique_port()
    child_port = unique_port()
    pubsub_name = :loam_integration_pubsub
    topic = "room:42"

    {:ok, _sup} =
      Phoenix.PubSub.Supervisor.start_link(
        name: pubsub_name,
        adapter: Loam.Phoenix.Adapter,
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{parent_port}"],
          connect: ["tcp/127.0.0.1:#{child_port}"],
          multicast_scouting: false
        ]
      )

    :ok = Phoenix.PubSub.subscribe(pubsub_name, topic)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      :ok =
        :peer.call(peer, Loam.Phoenix.IntegrationHelper, :run_remote, [
          pubsub_name,
          child_port,
          parent_port,
          topic,
          {:hello, :from_peer}
        ])

      assert_receive {:hello, :from_peer}, 10_000
    after
      :peer.stop(peer)
    end
  end

  defp unique_port do
    28_000 + :erlang.unique_integer([:positive, :monotonic])
  end

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path ->
      [~c"-pa", path]
    end)
  end
end
