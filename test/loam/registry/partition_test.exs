defmodule Loam.Registry.PartitionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scripted partition test for `Loam.Registry`, exercising the LWW conflict
  semantic specified in PRD-0002 Solution item 5 and gate item 4.

  Asserts:

  - Pre-partition register propagates from parent to peer.
  - Both sides register the *same* name during partition. Both calls return
    `:ok` and the local mirrors hold each side's claim.
  - On heal, the LWW comparator picks one winner; both mirrors converge on
    the same `lookup/2` answer.

  We do *not* assert which side wins — the comparator is `(lamport, zid)`
  lexicographic, and the ZIDs are runtime-assigned by Zenoh. The test
  derives the expected winner from the observed post-heal state.

  ## Running

  Tagged `:partition`; excluded from default `mix test`. Must run as root
  (pfctl):

      sudo -E env "PATH=$PATH" mix test --only partition test/loam/registry/partition_test.exs
  """

  @moduletag :partition

  alias Loam.Registry
  alias Loam.Registry.IntegrationHelper

  @peer_call_timeout 30_000
  @anchor "loam_registry_partition_test"

  setup_all do
    if :os.type() != {:unix, :darwin} do
      raise "Loam.Registry.PartitionTest currently implements pfctl (Darwin only)."
    end

    if System.cmd("id", ["-u"]) |> elem(0) |> String.trim() != "0" do
      raise """
      Loam.Registry.PartitionTest must run as root.

          sudo -E env "PATH=$PATH" mix test --only partition test/loam/registry/partition_test.exs
      """
    end

    on_exit(fn -> partition_clear() end)
    :ok
  end

  setup do
    cluster = :"loam_partition_reg_#{:erlang.unique_integer([:positive])}"
    {:ok, cluster: cluster}
  end

  test "concurrent register during partition: heal converges on a single LWW winner",
       %{cluster: cluster} do
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, parent} = start_local(cluster, parent_port, child_port)
    Process.unlink(parent)

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

      # Confirm pre-partition connectivity with a throwaway register.
      probe_pid = spawn(fn -> :timer.sleep(:infinity) end)
      :ok = Registry.register(cluster, :probe, probe_pid, :pre)

      assert :peer.call(
               peer,
               IntegrationHelper,
               :wait_lookup,
               [cluster, :probe, [{probe_pid, :pre}], 5_000],
               @peer_call_timeout
             ) == [{probe_pid, :pre}]

      # Partition: block both directions on the peer's listen port.
      :ok = partition_apply(child_port)

      # Both sides try to claim :contested during the partition.
      parent_pid = spawn(fn -> :timer.sleep(:infinity) end)
      :ok = Registry.register(cluster, :contested, parent_pid, :from_parent)

      peer_pid =
        :peer.call(
          peer,
          IntegrationHelper,
          :register_anchor,
          [cluster, :contested, :from_peer],
          @peer_call_timeout
        )

      # Each side sees its own claim during partition.
      assert Registry.lookup(cluster, :contested) == [{parent_pid, :from_parent}]

      assert :peer.call(
               peer,
               IntegrationHelper,
               :lookup_remote,
               [cluster, :contested],
               @peer_call_timeout
             ) == [{peer_pid, :from_peer}]

      # Hold then heal.
      Process.sleep(2_000)
      :ok = partition_clear()

      # Convergence: after heal, both sides agree on the winner. Wait up to
      # 10s for the announce backlog + LWW resolution.
      converged_parent =
        wait_until_match(fn -> Registry.lookup(cluster, :contested) end, 10_000)

      converged_peer =
        :peer.call(
          peer,
          IntegrationHelper,
          :wait_lookup,
          [cluster, :contested, converged_parent, 10_000],
          @peer_call_timeout
        )

      assert converged_parent == converged_peer

      # And the winner is one of the two pids.
      assert converged_parent in [[{parent_pid, :from_parent}], [{peer_pid, :from_peer}]]
    after
      partition_clear()
      :peer.stop(peer)
      if Process.alive?(parent), do: GenServer.stop(parent, :normal, 5_000)
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
    tmp = Path.join(System.tmp_dir!(), "loam_registry_partition_#{port}.pf")
    File.write!(tmp, rule)

    try do
      {_, 0} = System.cmd("pfctl", ["-a", @anchor, "-f", tmp], stderr_to_stdout: true)
      {_, 0} = System.cmd("pfctl", ["-E"], stderr_to_stdout: true)
    after
      File.rm(tmp)
    end

    :ok
  end

  defp partition_clear do
    System.cmd("pfctl", ["-a", @anchor, "-F", "rules"], stderr_to_stdout: true)
    :ok
  end

  defp start_local(cluster, listen_port, connect_port) do
    Loam.Registry.Session.start_link(
      name: cluster,
      heartbeat_interval_ms: 1_000,
      heartbeat_misses: 5,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: ["tcp/127.0.0.1:#{connect_port}"],
        multicast_scouting: false
      ]
    )
  end

  defp unique_port, do: 28_900 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
