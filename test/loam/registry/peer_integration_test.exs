defmodule Loam.Registry.PeerIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  @moduledoc """
  Two-OS-process integration test for `Loam.Registry`. Mirrors PRD-0001's
  `Loam.Phoenix.IntegrationTest` rig: parent BEAM (the test process) plus
  one peer BEAM, both running a `Loam.Registry.Session` on different
  loopback TCP ports, peering with each other over Zenoh.

  The "anchor pid" pattern: registrations require a pid alive on the
  registering BEAM, so the helper spawns a long-lived idle pid on the peer
  and registers that. Without this, a pid registered inside a `:peer.call`
  return value would die as the call exits and the entry would immediately
  vanish via the local pid-monitor cleanup path.
  """

  alias Loam.Registry
  alias Loam.Registry.IntegrationHelper

  @peer_call_timeout 30_000

  setup do
    cluster = :"loam_peer_int_#{:erlang.unique_integer([:positive])}"
    {:ok, cluster: cluster}
  end

  defp unique_port, do: 28_900 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end

  defp start_local(cluster, listen_port, connect_port) do
    {:ok, pid} =
      Loam.Registry.Session.start_link(
        name: cluster,
        heartbeat_interval_ms: 1_000,
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{listen_port}"],
          connect: ["tcp/127.0.0.1:#{connect_port}"],
          multicast_scouting: false
        ]
      )

    Process.unlink(pid)

    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    pid
  end

  test "register on peer is visible to parent's lookup", %{cluster: cluster} do
    parent_port = unique_port()
    child_port = unique_port()

    _parent = start_local(cluster, parent_port, child_port)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      :ok =
        :peer.call(
          peer,
          IntegrationHelper,
          :start_registry_persistent,
          [cluster, child_port, parent_port],
          @peer_call_timeout
        )

      anchor =
        :peer.call(
          peer,
          IntegrationHelper,
          :register_anchor,
          [cluster, :remote_anchor, %{from: :peer}],
          @peer_call_timeout
        )

      assert is_pid(anchor)
      # We don't run with distribution, so node(anchor) reports
      # :nonode@nohost on both sides. The load-bearing assertion is the
      # pid-term equality below.

      # Wait for the announce to arrive at the parent's mirror.
      deadline = System.monotonic_time(:millisecond) + 5_000

      result =
        Stream.repeatedly(fn ->
          Process.sleep(50)
          Registry.lookup(cluster, :remote_anchor)
        end)
        |> Enum.find(fn r ->
          r != [] or System.monotonic_time(:millisecond) > deadline
        end)

      assert result == [{anchor, %{from: :peer}}]
      assert Registry.count(cluster) >= 1
    after
      :peer.stop(peer)
    end
  end

  test "register on parent is visible to peer's lookup", %{cluster: cluster} do
    parent_port = unique_port()
    child_port = unique_port()

    _parent = start_local(cluster, parent_port, child_port)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      :ok =
        :peer.call(
          peer,
          IntegrationHelper,
          :start_registry_persistent,
          [cluster, child_port, parent_port],
          @peer_call_timeout
        )

      target = spawn(fn -> :timer.sleep(:infinity) end)
      :ok = Registry.register(cluster, :parent_anchor, target, :the_value)

      result =
        :peer.call(
          peer,
          IntegrationHelper,
          :wait_lookup,
          [cluster, :parent_anchor, [{target, :the_value}], 5_000],
          @peer_call_timeout
        )

      assert result == [{target, :the_value}]
    after
      :peer.stop(peer)
    end
  end

  test "unregister on parent propagates to peer's lookup", %{cluster: cluster} do
    parent_port = unique_port()
    child_port = unique_port()

    _parent = start_local(cluster, parent_port, child_port)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      :ok =
        :peer.call(
          peer,
          IntegrationHelper,
          :start_registry_persistent,
          [cluster, child_port, parent_port],
          @peer_call_timeout
        )

      target = spawn(fn -> :timer.sleep(:infinity) end)
      :ok = Registry.register(cluster, :will_unreg, target, nil)

      assert :peer.call(
               peer,
               IntegrationHelper,
               :wait_lookup,
               [cluster, :will_unreg, [{target, nil}], 5_000],
               @peer_call_timeout
             ) == [{target, nil}]

      :ok = Registry.unregister(cluster, :will_unreg)

      assert :peer.call(
               peer,
               IntegrationHelper,
               :wait_lookup,
               [cluster, :will_unreg, [], 5_000],
               @peer_call_timeout
             ) == []
    after
      :peer.stop(peer)
    end
  end
end
