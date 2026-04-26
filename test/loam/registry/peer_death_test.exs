defmodule Loam.Registry.PeerDeathTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Peer-death eviction test for `Loam.Registry`, exercising PRD-0002
  Solution item 6 and gate item 5.

  Asserts:

  - With a peer connected, `peers_zid` reflects the peer and a registration
    on the peer becomes visible on the parent.
  - After the peer is killed abruptly (`:erlang.halt`), the parent's
    Session evicts every entry owned by the peer's ZID within
    `heartbeat_interval_ms * heartbeat_misses + slack`.
  - A fresh peer joining on the same endpoint can register the same name
    without conflict — the prior entry is gone, the snapshot exchange does
    not resurrect it (the dead peer is no longer a snapshot source).

  Tagged `:peer_death`. Does not require root.

      mix test --only peer_death test/loam/registry/peer_death_test.exs
  """

  @moduletag :peer_death

  alias Loam.Registry
  alias Loam.Registry.IntegrationHelper

  @peer_call_timeout 30_000
  @heartbeat_ms 600
  @heartbeat_misses 3
  @eviction_slack_ms 8_000

  setup do
    cluster = :"loam_peer_death_reg_#{:erlang.unique_integer([:positive])}"
    {:ok, cluster: cluster}
  end

  test "dead peer's entries are evicted; fresh peer can re-register without conflict",
       %{cluster: cluster} do
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, parent} = start_local(cluster, parent_port, child_port)
    Process.unlink(parent)

    {:ok, peer1, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    :ok =
      :peer.call(
        peer1,
        IntegrationHelper,
        :start_registry_persistent,
        [
          cluster,
          child_port,
          parent_port,
          [heartbeat_interval_ms: @heartbeat_ms, heartbeat_misses: @heartbeat_misses]
        ],
        @peer_call_timeout
      )

    anchor =
      :peer.call(
        peer1,
        IntegrationHelper,
        :register_anchor,
        [cluster, :doomed, :v1],
        @peer_call_timeout
      )

    assert wait_until(fn -> Registry.lookup(cluster, :doomed) == [{anchor, :v1}] end, 5_000),
           "expected parent to see peer1's registration"

    # Kill peer1 abruptly. Its TCP socket gets RST when the OS process exits.
    # No :peer.stop after this — the OS process is gone and the controlling
    # :peer process exits on its own.
    :peer.cast(peer1, :erlang, :halt, [0])

    eviction_window = @heartbeat_ms * @heartbeat_misses + @eviction_slack_ms

    assert wait_until(fn -> Registry.lookup(cluster, :doomed) == [] end, eviction_window),
           "parent did not evict peer1's entry within #{eviction_window}ms after halt"

    # Fresh peer on the same endpoint can register the same name with no
    # conflict — the prior entry is gone for good.
    {:ok, peer2, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      :ok =
        :peer.call(
          peer2,
          IntegrationHelper,
          :start_registry_persistent,
          [
            cluster,
            child_port,
            parent_port,
            [heartbeat_interval_ms: @heartbeat_ms, heartbeat_misses: @heartbeat_misses]
          ],
          @peer_call_timeout
        )

      fresh_anchor =
        :peer.call(
          peer2,
          IntegrationHelper,
          :register_anchor,
          [cluster, :doomed, :v2],
          @peer_call_timeout
        )

      assert wait_until(
               fn -> Registry.lookup(cluster, :doomed) == [{fresh_anchor, :v2}] end,
               5_000
             ),
             "expected parent to see peer2's fresh registration"
    after
      :peer.stop(peer2)
      if Process.alive?(parent), do: GenServer.stop(parent, :normal, 5_000)
    end
  end

  ## Helpers

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(100)
      fun.()
    end)
    |> Enum.find(fn r -> r or System.monotonic_time(:millisecond) > deadline end) || false
  end

  defp start_local(cluster, listen_port, connect_port) do
    Loam.Registry.Session.start_link(
      name: cluster,
      heartbeat_interval_ms: @heartbeat_ms,
      heartbeat_misses: @heartbeat_misses,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: ["tcp/127.0.0.1:#{connect_port}"],
        multicast_scouting: false,
        # Tighten Zenoh's session lease so peer-loss is declared faster
        # after TCP RST. Same trick as PRD-0001's peer_death_test.
        raw: [
          {"transport/link/tx/lease", "3000"},
          {"transport/link/tx/keep_alive", "4"}
        ]
      ]
    )
  end

  defp unique_port, do: 28_900 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
