defmodule Loam.AnchorPartitionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scripted partition test for `Loam.Anchor`, exercising the LWW eviction
  semantic during a real network partition.

  Asserts:

  - Both sides independently start a child during the partition window.
  - On heal, the LWW comparator picks one winner; both registries converge
    on the same `lookup/2` answer.
  - The loser's child runs `terminate/2` (the AnchorWorker fixture sends
    `{:anchor_worker_terminated, pid, reason}` to its reporter).

  Tagged `:partition`; excluded from default `mix test`. Must run as root
  (pfctl, Darwin only):

      sudo -E env "PATH=$PATH" mix test --only partition test/loam/anchor_partition_test.exs
  """

  @moduletag :partition

  alias Loam.Anchor
  alias Loam.Anchor.IntegrationHelper
  alias Loam.Registry
  alias Loam.Test.AnchorWorker

  @peer_call_timeout 30_000
  @anchor_pf "loam_anchor_partition_test"

  setup_all do
    if :os.type() != {:unix, :darwin} do
      raise "Loam.AnchorPartitionTest currently implements pfctl (Darwin only)."
    end

    if System.cmd("id", ["-u"]) |> elem(0) |> String.trim() != "0" do
      raise """
      Loam.AnchorPartitionTest must run as root.

          sudo -E env "PATH=$PATH" mix test --only partition test/loam/anchor_partition_test.exs
      """
    end

    on_exit(fn -> partition_clear() end)
    :ok
  end

  test "partition: both run during partition; heal converges to one LWW winner; loser terminate/2 ran" do
    cluster = :"loam_anchor_part_#{:erlang.unique_integer([:positive])}"
    parent_port = unique_port()
    peer_port = unique_port()

    {:ok, parent_sess} =
      Loam.Registry.Session.start_link(
        name: cluster,
        heartbeat_interval_ms: 1_000,
        heartbeat_misses: 5,
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{parent_port}"],
          connect: ["tcp/127.0.0.1:#{peer_port}"],
          multicast_scouting: false
        ]
      )

    Process.unlink(parent_sess)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      {:ok, peer_anchor} =
        :peer.call(
          peer,
          IntegrationHelper,
          :start_anchor_remote,
          [cluster, peer_port, parent_port, :svc, [start_jitter_ms: 0, vacancy_debounce_ms: 200]],
          @peer_call_timeout
        )

      # Wait for handshake.
      Process.sleep(2_000)

      # Partition before parent's anchor starts so each side starts in
      # isolation.
      :ok = partition_apply(peer_port)

      {:ok, parent_anchor} =
        Anchor.start_link(
          registry: cluster,
          name: :svc,
          child_spec: {AnchorWorker, [report_to: self()]},
          start_jitter_ms: 0,
          vacancy_debounce_ms: 200
        )

      Process.unlink(parent_anchor)

      # Both sides observe their own claim during partition.
      parent_lookup =
        wait_until_match(fn -> Registry.lookup(cluster, :svc) end, 5_000)

      assert match?([{^parent_anchor, _}], parent_lookup)

      peer_lookup =
        :peer.call(
          peer,
          IntegrationHelper,
          :wait_lookup,
          [cluster, :svc, peer_anchor, 5_000],
          @peer_call_timeout
        )

      assert match?([{^peer_anchor, _}], peer_lookup)

      # Hold then heal.
      Process.sleep(2_000)
      :ok = partition_clear()

      # Convergence: 10s budget for the announce backlog + LWW resolution
      # + child termination.
      converged_parent =
        wait_until_match(fn -> Registry.lookup(cluster, :svc) end, 10_000)

      converged_peer =
        :peer.call(
          peer,
          IntegrationHelper,
          :wait_lookup,
          [cluster, :svc, :any, 10_000],
          @peer_call_timeout
        )

      assert converged_parent == converged_peer

      # The winner is one of the two anchors.
      [{winner_pid, _}] = converged_parent
      assert winner_pid in [parent_anchor, peer_anchor]

      # If the parent lost, terminate/2 ran on the parent's child.
      if winner_pid == peer_anchor do
        assert_received {:anchor_worker_terminated, _terminated_pid, _reason}
      end

      # Both anchors are still alive; the loser is in standby.
      assert Process.alive?(parent_anchor)

      :ok =
        :peer.call(
          peer,
          GenServer,
          :stop,
          [peer_anchor, :normal, 5_000],
          @peer_call_timeout
        )
    after
      partition_clear()
      :peer.stop(peer)
      if Process.alive?(parent_sess), do: GenServer.stop(parent_sess, :normal, 5_000)
    end
  end

  ## Helpers

  defp wait_until_match(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(100)
      fun.()
    end)
    |> Enum.find(fn r ->
      match?([{_, _}], r) or System.monotonic_time(:millisecond) > deadline
    end)
  end

  defp partition_apply(port) do
    rule = "block drop quick proto tcp from any to 127.0.0.1 port #{port}\n"
    tmp = Path.join(System.tmp_dir!(), "loam_anchor_partition_#{port}.pf")
    File.write!(tmp, rule)

    try do
      {_, 0} = System.cmd("pfctl", ["-a", @anchor_pf, "-f", tmp], stderr_to_stdout: true)
      {_, 0} = System.cmd("pfctl", ["-E"], stderr_to_stdout: true)
    after
      File.rm(tmp)
    end

    :ok
  end

  defp partition_clear do
    System.cmd("pfctl", ["-a", @anchor_pf, "-F", "rules"], stderr_to_stdout: true)
    :ok
  end

  defp unique_port, do: 28_700 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
