defmodule Loam.Registry.IntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  # Two Loam.Registry.Session instances in one BEAM, each with its own
  # Zenohex.Session bound to a different loopback port and peering with the
  # other. Validated as a working setup by
  # docs/journal/2026-04-25-zenohex-two-local-sessions.md.
  #
  # This is the first cross-Zenoh smoke test for Registry: a register on
  # session A becomes visible to lookup on session B after a brief handshake.

  alias Loam.Registry
  alias Loam.Registry.Session

  @handshake_ms 1500
  @propagation_ms 500

  defp unique_port, do: 28_500 + :erlang.unique_integer([:positive, :monotonic])

  defp start_pair(cluster_name, proc_a, proc_b, opts \\ []) do
    port_a = unique_port()
    port_b = unique_port()

    base_opts = [
      name: cluster_name,
      heartbeat_interval_ms: Keyword.get(opts, :heartbeat_interval_ms, 5_000),
      heartbeat_misses: Keyword.get(opts, :heartbeat_misses, 3)
    ]

    {:ok, a} =
      Session.start_link(
        base_opts ++
          [
            process_name: proc_a,
            zenoh: [
              mode: :peer,
              listen: ["tcp/127.0.0.1:#{port_a}"],
              connect: ["tcp/127.0.0.1:#{port_b}"],
              multicast_scouting: false
            ]
          ]
      )

    {:ok, b} =
      Session.start_link(
        base_opts ++
          [
            process_name: proc_b,
            zenoh: [
              mode: :peer,
              listen: ["tcp/127.0.0.1:#{port_b}"],
              connect: ["tcp/127.0.0.1:#{port_a}"],
              multicast_scouting: false
            ]
          ]
      )

    # Unlink so the test process exiting doesn't asynchronously kill the
    # sessions before on_exit gets to stop them cleanly. Otherwise the
    # cleanup races and GenServer.stop sees :no_process.
    for s <- [a, b], do: Process.unlink(s)

    Process.sleep(@handshake_ms)

    on_exit(fn ->
      for s <- [a, b] do
        try do
          if Process.alive?(s), do: GenServer.stop(s, :normal, 5_000)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    %{a: a, b: b}
  end

  defp start_one(cluster, proc, listen_port, connect_ports, opts) do
    {:ok, pid} =
      Session.start_link(
        name: cluster,
        process_name: proc,
        heartbeat_interval_ms: Keyword.get(opts, :heartbeat_interval_ms, 5_000),
        heartbeat_misses: Keyword.get(opts, :heartbeat_misses, 3),
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{listen_port}"],
          connect: Enum.map(connect_ports, &"tcp/127.0.0.1:#{&1}"),
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

  defp wait_lookup(registry, name, expected, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      :timer.sleep(25)
      Registry.lookup(registry, name)
    end)
    |> Enum.find(fn result ->
      result == expected or System.monotonic_time(:millisecond) > deadline
    end)
  end

  test "register on A becomes visible to B" do
    uniq = :erlang.unique_integer([:positive])
    cluster = :"reg_int_cluster_#{uniq}"
    name_a = :"reg_int_a_#{uniq}"
    name_b = :"reg_int_b_#{uniq}"
    %{} = start_pair(cluster, name_a, name_b)

    target = spawn(fn -> :timer.sleep(:infinity) end)
    :ok = Registry.register(name_a, :alice, target, %{role: :leader})

    assert wait_lookup(name_b, :alice, [{target, %{role: :leader}}]) ==
             [{target, %{role: :leader}}]

    assert Registry.count(name_b) >= 1
  end

  test "unregister on A propagates to B" do
    uniq = :erlang.unique_integer([:positive])
    cluster = :"reg_int_cluster_#{uniq}"
    name_a = :"reg_int_a_#{uniq}"
    name_b = :"reg_int_b_#{uniq}"
    %{} = start_pair(cluster, name_a, name_b)

    target = spawn(fn -> :timer.sleep(:infinity) end)
    :ok = Registry.register(name_a, :bob, target, nil)
    assert wait_lookup(name_b, :bob, [{target, nil}]) == [{target, nil}]

    :ok = Registry.unregister(name_a, :bob)
    assert wait_lookup(name_b, :bob, []) == []
  end

  test "concurrent register on both sides: LWW winner survives, loser pid is notified" do
    uniq = :erlang.unique_integer([:positive])
    cluster = :"reg_int_cluster_#{uniq}"
    name_a = :"reg_int_a_#{uniq}"
    name_b = :"reg_int_b_#{uniq}"
    %{a: a, b: b} = start_pair(cluster, name_a, name_b)

    # Idle pids that never consume their mailbox so the test can inspect
    # for the eviction message via Process.info/2.
    pid_a = spawn(fn -> :timer.sleep(:infinity) end)
    pid_b = spawn(fn -> :timer.sleep(:infinity) end)

    # The two sessions both register the same name. Both succeed locally
    # (the local mirror sees no conflict at register time). On Zenoh
    # delivery, the LWW comparator picks a deterministic winner per
    # (lamport, zid).
    :ok = Registry.register(name_a, :charlie, pid_a, :a_value)
    :ok = Registry.register(name_b, :charlie, pid_b, :b_value)

    Process.sleep(@propagation_ms)

    [{winning_pid, _val}] = Registry.lookup(name_a, :charlie)
    assert [{^winning_pid, _}] = Registry.lookup(name_b, :charlie)

    losing_pid = if winning_pid == pid_a, do: pid_b, else: pid_a
    winner_zid = if winning_pid == pid_a, do: Session.zid(a), else: Session.zid(b)
    assert receive_eviction(losing_pid, :charlie, winner_zid, 1_000)
  end

  test "late-joiner sees pre-existing entries via snapshot exchange" do
    uniq = :erlang.unique_integer([:positive])
    cluster = :"reg_int_cluster_#{uniq}"
    name_a = :"reg_int_a_#{uniq}"
    name_b = :"reg_int_b_#{uniq}"
    port_a = unique_port()
    port_b = unique_port()

    # A starts alone, registers entries before B exists.
    _a = start_one(cluster, name_a, port_a, [port_b], heartbeat_interval_ms: 300)
    Process.sleep(300)

    target1 = spawn(fn -> :timer.sleep(:infinity) end)
    target2 = spawn(fn -> :timer.sleep(:infinity) end)
    :ok = Registry.register(name_a, :early1, target1, :v1)
    :ok = Registry.register(name_a, :early2, target2, :v2)

    # B joins late. After heartbeat + snapshot exchange, B should see A's
    # pre-existing entries even though B was not subscribed when they were
    # originally announced.
    _b = start_one(cluster, name_b, port_b, [port_a], heartbeat_interval_ms: 300)

    assert wait_lookup(name_b, :early1, [{target1, :v1}], 5_000) ==
             [{target1, :v1}]

    assert wait_lookup(name_b, :early2, [{target2, :v2}], 5_000) ==
             [{target2, :v2}]
  end

  test "peer death evicts the dead peer's entries within heartbeat-miss window" do
    uniq = :erlang.unique_integer([:positive])
    cluster = :"reg_int_cluster_#{uniq}"
    name_a = :"reg_int_a_#{uniq}"
    name_b = :"reg_int_b_#{uniq}"

    %{a: a, b: _b} =
      start_pair(cluster, name_a, name_b,
        heartbeat_interval_ms: 200,
        heartbeat_misses: 3
      )

    target = spawn(fn -> :timer.sleep(:infinity) end)
    :ok = Registry.register(name_a, :doomed, target, :v)
    assert wait_lookup(name_b, :doomed, [{target, :v}]) == [{target, :v}]

    # Kill A. The Session terminate/2 closes its Zenohex.Session, which
    # should clear A's ZID from B's peers_zid. B's peer-check timer (every
    # ~100ms) should observe that and evict A's entries from B's mirror.
    GenServer.stop(a, :normal, 5_000)

    # Window: heartbeat_interval_ms * heartbeat_misses + slack for the
    # peer_check timer + zenoh propagation.
    assert wait_lookup(name_b, :doomed, [], 5_000) == []
  end

  defp receive_eviction(pid, name, winner_zid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      :timer.sleep(25)

      case Process.info(pid, :messages) do
        {:messages, msgs} ->
          Enum.any?(msgs, &match?({:loam_registry, :evicted, ^name, ^winner_zid}, &1))

        _ ->
          false
      end
    end)
    |> Enum.find(fn found ->
      found or System.monotonic_time(:millisecond) > deadline
    end)
  end
end
