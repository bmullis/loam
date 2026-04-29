defmodule Loam.AnchorPeerDeathTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Peer-death failover for `Loam.Anchor`. The owning BEAM's OS process is
  killed; the surviving BEAM observes `:name_vacant` (after the registry's
  peer-loss eviction + the anchor's vacancy debounce) and takes over.

  Tagged `:peer_death`. Does not require root.

      mix test --only peer_death test/loam/anchor_peer_death_test.exs
  """

  @moduletag :peer_death

  alias Loam.Anchor
  alias Loam.Anchor.IntegrationHelper
  alias Loam.Registry
  alias Loam.Test.AnchorWorker

  @peer_call_timeout 30_000
  @heartbeat_ms 600
  @heartbeat_misses 3
  @eviction_slack_ms 8_000
  @vacancy_debounce_ms 200

  setup do
    cluster = :"loam_anchor_pd_#{:erlang.unique_integer([:positive])}"
    {:ok, cluster: cluster}
  end

  test "owner BEAM dies; survivor takes over within bounded window",
       %{cluster: cluster} do
    parent_port = unique_port()
    peer_port = unique_port()

    {:ok, parent_sess} = start_local_sess(cluster, parent_port, peer_port)
    Process.unlink(parent_sess)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    parent_anchor = nil

    try do
      # Peer starts first and registers; its session+anchor wait through the
      # 1500ms handshake before the anchor races, so the parent's eventual
      # anchor will arrive after.
      {:ok, peer_anchor} =
        :peer.call(
          peer,
          IntegrationHelper,
          :start_anchor_remote,
          [
            cluster,
            peer_port,
            parent_port,
            :svc,
            [
              heartbeat_interval_ms: @heartbeat_ms,
              heartbeat_misses: @heartbeat_misses,
              start_jitter_ms: 0,
              vacancy_debounce_ms: @vacancy_debounce_ms
            ]
          ],
          @peer_call_timeout
        )

      # Sanity: peer-side mirror should have the registration locally first.
      assert wait_until(
               fn ->
                 case :peer.call(peer, IntegrationHelper, :lookup_remote, [cluster, :svc],
                        @peer_call_timeout) do
                   [{^peer_anchor, _}] -> true
                   _ -> false
                 end
               end,
               5_000
             ),
             "peer's own mirror should have its registration"

      # Parent's anchor starts after the peer is established as owner, so
      # it observes the existing owner and stays in standby with a monitor.
      {:ok, parent_anchor} =
        Anchor.start_link(
          registry: cluster,
          name: :svc,
          child_spec: {AnchorWorker, [report_to: self()]},
          start_jitter_ms: 0,
          vacancy_debounce_ms: @vacancy_debounce_ms,
          max_restarts: 3,
          max_seconds: 5
        )

      Process.unlink(parent_anchor)

      assert wait_until(
               fn ->
                 case Registry.lookup(cluster, :svc) do
                   [{^peer_anchor, _}] -> true
                   _ -> false
                 end
               end,
               5_000
             ),
             "expected parent to see peer's anchor as owner"

      # Kill peer abruptly.
      :peer.cast(peer, :erlang, :halt, [0])

      # Bound: peer-loss eviction (heartbeat_ms * misses) + debounce + jitter + slack.
      failover_window =
        @heartbeat_ms * @heartbeat_misses + @vacancy_debounce_ms + 800 + @eviction_slack_ms

      assert wait_until(
               fn ->
                 case Registry.lookup(cluster, :svc) do
                   [{^parent_anchor, child_pid}] when is_pid(child_pid) -> true
                   _ -> false
                 end
               end,
               failover_window
             ),
             "expected parent's anchor to take over within #{failover_window}ms"

      [{^parent_anchor, child_pid}] = Registry.lookup(cluster, :svc)
      assert Process.alive?(child_pid)
      assert_received {:anchor_worker_started, ^child_pid}
    after
      try do
        :peer.stop(peer)
      catch
        :exit, _ -> :ok
      end

      try do
        if is_pid(parent_anchor) and Process.alive?(parent_anchor),
          do: GenServer.stop(parent_anchor, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end

      try do
        if Process.alive?(parent_sess), do: GenServer.stop(parent_sess, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
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

  defp start_local_sess(cluster, listen_port, connect_port) do
    Loam.Registry.Session.start_link(
      name: cluster,
      heartbeat_interval_ms: @heartbeat_ms,
      heartbeat_misses: @heartbeat_misses,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: ["tcp/127.0.0.1:#{connect_port}"],
        multicast_scouting: false,
        raw: [
          {"transport/link/tx/lease", "3000"},
          {"transport/link/tx/keep_alive", "4"}
        ]
      ]
    )
  end

  defp unique_port, do: 28_950 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
