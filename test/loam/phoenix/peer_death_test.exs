defmodule Loam.Phoenix.PeerDeathTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Peer-death drop test for `Loam.Phoenix.Adapter`, exercising the `:drop`
  regime documented in PRD-0001 Solution item 2 — broadcasts published while
  the far-side BEAM is down are dropped, not buffered for replay.

  Asserts:

  - With a peer connected, `peers_zid` reflects the peer.
  - After the peer is killed abruptly (`:erlang.halt`), `peers_zid` clears
    within a reasonable timeout.
  - Publishes after peer-death return `:ok` and do not crash or block the
    publisher (`congestion_control: :drop` engages).
  - When a fresh peer subscribes on the same endpoint, only post-restart
    publishes are delivered. The during-down publish is gone — there is no
    publication cache, no replay, no querying subscriber.

  Tagged `:peer_death`; excluded from default `mix test`. Run explicitly:

      mix test --only peer_death

  Does **not** require root — abrupt peer kill is an in-BEAM operation.
  """

  @moduletag :peer_death

  alias Loam.Phoenix.IntegrationHelper

  @peer_call_timeout 30_000
  @peers_clear_timeout 30_000

  setup do
    pubsub_name = :"loam_peer_death_pubsub_#{:erlang.unique_integer([:positive])}"
    {:ok, pubsub_name: pubsub_name}
  end

  test "during-down publishes are dropped; only post-restart publishes deliver",
       %{pubsub_name: pubsub_name} do
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, _sup} = start_local_pubsub(pubsub_name, parent_port, child_port)
    adapter_name = Module.concat(pubsub_name, Adapter)

    # Start peer1 with a subscriber that will be aborted when we kill the peer.
    {:ok, peer1, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    _aborted_collector =
      Task.async(fn ->
        # This call dies when the peer halts; rescue the noise.
        try do
          :peer.call(
            peer1,
            IntegrationHelper,
            :collect_remote,
            [pubsub_name, child_port, parent_port, "pd:test", 1, 20_000],
            @peer_call_timeout
          )
        catch
          :exit, _ -> :peer_died
        end
      end)

    Process.sleep(2_500)

    assert peers_zid(adapter_name) != [],
           "expected peer1 to be visible in peers_zid"

    # Kill peer1 abruptly. :peer.cast does not wait for a reply, so the call
    # returns even though the remote BEAM is mid-halt. The TCP socket gets an
    # RST when the OS process exits.
    :peer.cast(peer1, :erlang, :halt, [0])

    # Wait for peers_zid to actually clear before publishing. Otherwise the
    # publish would land in the TCP send buffer and we'd be testing buffered
    # delivery, not :drop.
    assert wait_until_peers_clear(adapter_name, @peers_clear_timeout),
           "peers_zid did not clear within #{@peers_clear_timeout}ms after peer kill"

    # Broadcast during-down. With peers_zid empty, congestion_control: :drop
    # should engage. Must not crash, must return :ok promptly.
    assert :ok = Phoenix.PubSub.broadcast(pubsub_name, "pd:test", "during_down")

    # Start peer2 on the same loopback endpoint as peer1.
    {:ok, peer2, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      collector =
        Task.async(fn ->
          :peer.call(
            peer2,
            IntegrationHelper,
            :collect_remote,
            [pubsub_name, child_port, parent_port, "pd:test", 1, 10_000],
            @peer_call_timeout
          )
        end)

      # Re-peering handshake.
      Process.sleep(2_500)

      assert :ok = Phoenix.PubSub.broadcast(pubsub_name, "pd:test", "post_restart")

      # Peer2 should see exactly one message — the post_restart one. The
      # during_down message is gone (no replay).
      assert ["post_restart"] = Task.await(collector, @peer_call_timeout)
    after
      :peer.stop(peer2)
    end
  end

  ## Helpers

  defp peers_zid(adapter_name) do
    state = :persistent_term.get({Loam.Phoenix.Session, adapter_name})
    {:ok, info} = Zenohex.Session.info(state.session_id)
    info.peers_zid
  end

  defp wait_until_peers_clear(adapter_name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      case peers_zid(adapter_name) do
        [] -> :cleared
        _ -> Process.sleep(250) && :polling
      end
    end)
    |> Enum.find_value(fn
      :cleared -> true
      :polling -> if System.monotonic_time(:millisecond) > deadline, do: false, else: nil
    end)
  end

  defp start_local_pubsub(name, listen_port, connect_port) do
    Phoenix.PubSub.Supervisor.start_link(
      name: name,
      adapter: Loam.Phoenix.Adapter,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: ["tcp/127.0.0.1:#{connect_port}"],
        multicast_scouting: false,
        # Tighten lease so peer-loss is declared faster after the TCP RST,
        # keeping the test runtime reasonable.
        raw: [
          {"transport/link/tx/lease", "3000"},
          {"transport/link/tx/keep_alive", "4"}
        ]
      ]
    )
  end

  defp unique_port, do: 28_000 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
