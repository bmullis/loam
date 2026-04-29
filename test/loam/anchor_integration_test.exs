defmodule Loam.AnchorIntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Loam.Anchor
  alias Loam.Registry
  alias Loam.Registry.Session
  alias Loam.Test.AnchorWorker

  @handshake_ms 1_500
  @converge_ms 4_000

  defp unique_port, do: 28_500 + :erlang.unique_integer([:positive, :monotonic])

  defp start_session(cluster, proc_name, listen_port, connect_ports) do
    {:ok, sup} =
      Session.start_link(
        name: cluster,
        process_name: proc_name,
        heartbeat_interval_ms: 1_000,
        heartbeat_misses: 3,
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{listen_port}"],
          connect: Enum.map(connect_ports, fn p -> "tcp/127.0.0.1:#{p}" end),
          multicast_scouting: false
        ]
      )

    Process.unlink(sup)

    on_exit(fn ->
      try do
        if Process.alive?(sup), do: GenServer.stop(sup, :normal, 5_000)
      catch
        :exit, _ -> :ok
      end
    end)

    sup
  end

  defp start_anchor(registry, name) do
    {:ok, pid} =
      Anchor.start_link(
        registry: registry,
        name: name,
        child_spec: {AnchorWorker, [report_to: self()]},
        start_jitter_ms: 100,
        vacancy_debounce_ms: 200,
        max_restarts: 3,
        max_seconds: 5
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

  defp wait_until_converged(sessions, name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_converged(sessions, name, deadline)
  end

  defp do_wait_converged(sessions, name, deadline) do
    snapshots = Enum.map(sessions, &Registry.lookup(&1, name))

    cond do
      Enum.all?(snapshots, &match?([{_, _}], &1)) and Enum.uniq(snapshots) |> length() == 1 ->
        {:ok, hd(snapshots)}

      System.monotonic_time(:millisecond) > deadline ->
        {:timeout, snapshots}

      true ->
        Process.sleep(50)
        do_wait_converged(sessions, name, deadline)
    end
  end

  describe "two-BEAM happy path" do
    test "exactly one anchor wins; both sides converge on the same owner" do
      cluster = :"anchor_cluster_#{System.unique_integer([:positive])}"
      proc_a = :"anchor_sess_a_#{System.unique_integer([:positive])}"
      proc_b = :"anchor_sess_b_#{System.unique_integer([:positive])}"

      port_a = unique_port()
      port_b = unique_port()

      start_session(cluster, proc_a, port_a, [port_b])
      start_session(cluster, proc_b, port_b, [port_a])
      Process.sleep(@handshake_ms)

      anchor_a = start_anchor(proc_a, :svc)
      anchor_b = start_anchor(proc_b, :svc)

      {:ok, [{owner_pid, child_pid}]} = wait_until_converged([proc_a, proc_b], :svc, @converge_ms)

      assert owner_pid in [anchor_a, anchor_b]
      assert is_pid(child_pid)
      assert Process.alive?(child_pid)

      # Wait briefly so any duplicate AnchorWorker started by the loser had
      # time to terminate; assert the loser has no running child.
      Process.sleep(500)

      loser_pid = if owner_pid == anchor_a, do: anchor_b, else: anchor_a
      loser_state = :sys.get_state(loser_pid)
      assert loser_state.status == :standby
      assert loser_state.local_sup == nil
      assert loser_state.child_pid == nil
    end
  end

  describe "late join" do
    test "C joins; observes existing owner via snapshot bootstrap; no eviction" do
      cluster = :"anchor_cluster_#{System.unique_integer([:positive])}"
      proc_a = :"anchor_sess_a_#{System.unique_integer([:positive])}"
      proc_b = :"anchor_sess_b_#{System.unique_integer([:positive])}"
      proc_c = :"anchor_sess_c_#{System.unique_integer([:positive])}"

      port_a = unique_port()
      port_b = unique_port()
      port_c = unique_port()

      start_session(cluster, proc_a, port_a, [port_b])
      start_session(cluster, proc_b, port_b, [port_a])
      Process.sleep(@handshake_ms)

      anchor_a = start_anchor(proc_a, :svc)
      anchor_b = start_anchor(proc_b, :svc)

      {:ok, [{owner_pid, _child_pid}]} =
        wait_until_converged([proc_a, proc_b], :svc, @converge_ms)

      # C joins after A and B have already converged.
      start_session(cluster, proc_c, port_c, [port_a, port_b])
      Process.sleep(@handshake_ms)

      anchor_c = start_anchor(proc_c, :svc)

      {:ok, [{owner_pid_after, _}]} =
        wait_until_converged([proc_a, proc_b, proc_c], :svc, @converge_ms)

      # No eviction: the owner did not change.
      assert owner_pid_after == owner_pid
      refute anchor_c == owner_pid

      Process.sleep(500)
      c_state = :sys.get_state(anchor_c)
      assert c_state.status == :standby
      assert c_state.local_sup == nil
      assert c_state.child_pid == nil

      # The original owner is still A or B.
      assert owner_pid in [anchor_a, anchor_b]
    end
  end
end
