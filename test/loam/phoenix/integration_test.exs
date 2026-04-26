defmodule Loam.Phoenix.IntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Cross-BEAM tests using :peer (no distribution / no EPMD). Each test runs
  # a parent BEAM (the test process) and one peer BEAM, both running
  # Phoenix.PubSub with the loam adapter on different loopback TCP ports.

  alias Loam.Phoenix.IntegrationHelper

  @peer_call_timeout 30_000

  setup do
    pubsub_name = :"loam_integration_pubsub_#{:erlang.unique_integer([:positive])}"
    {:ok, pubsub_name: pubsub_name}
  end

  test "peer → parent: broadcast from peer reaches parent's subscriber", %{
    pubsub_name: pubsub_name
  } do
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, _sup} = start_local_pubsub(pubsub_name, parent_port, child_port)
    :ok = Phoenix.PubSub.subscribe(pubsub_name, "room:42")

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      :ok =
        peer_call(peer, :broadcast_remote, [
          pubsub_name,
          child_port,
          parent_port,
          [{"room:42", {"hello", "from_peer"}}]
        ])

      assert_receive {"hello", "from_peer"}, 10_000
      refute_receive _other, 200
    after
      :peer.stop(peer)
    end
  end

  test "parent → peer: broadcast from parent reaches peer's subscriber", %{
    pubsub_name: pubsub_name
  } do
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, _sup} = start_local_pubsub(pubsub_name, parent_port, child_port)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      collector =
        Task.async(fn ->
          peer_call(peer, :collect_remote, [
            pubsub_name,
            child_port,
            parent_port,
            "room:99",
            1,
            5_000
          ])
        end)

      # Give the peer time to start its pubsub, subscribe, and complete the
      # Zenoh handshake (helper sleeps 1500ms internally).
      Process.sleep(2_000)
      :ok = Phoenix.PubSub.broadcast(pubsub_name, "room:99", {"hello", "from_parent"})

      assert [{"hello", "from_parent"}] = Task.await(collector, @peer_call_timeout)
    after
      :peer.stop(peer)
    end
  end

  test "topics are isolated by keyexpr", %{pubsub_name: pubsub_name} do
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, _sup} = start_local_pubsub(pubsub_name, parent_port, child_port)
    :ok = Phoenix.PubSub.subscribe(pubsub_name, "room:1")
    # Deliberately not subscribing to room:2 — assert it never arrives.

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      :ok =
        peer_call(peer, :broadcast_remote, [
          pubsub_name,
          child_port,
          parent_port,
          [
            {"room:2", "should_not_arrive"},
            {"room:1", "should_arrive"}
          ]
        ])

      assert_receive "should_arrive", 10_000
      refute_receive "should_not_arrive", 500
    after
      :peer.stop(peer)
    end
  end

  defp peer_call(peer, fun, args) do
    :peer.call(peer, IntegrationHelper, fun, args, @peer_call_timeout)
  end

  defp start_local_pubsub(name, listen_port, connect_port) do
    Phoenix.PubSub.Supervisor.start_link(
      name: name,
      adapter: Loam.Phoenix.Adapter,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: ["tcp/127.0.0.1:#{connect_port}"],
        multicast_scouting: false
      ]
    )
  end

  defp unique_port do
    28_000 + :erlang.unique_integer([:positive, :monotonic])
  end

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
