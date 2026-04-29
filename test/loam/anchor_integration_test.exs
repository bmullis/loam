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

  defp attach_telemetry(events) do
    parent = self()
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
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

  describe "max-restarts cross-Session failover" do
    test "owner exhausts max-restarts; peer observes :name_vacant and takes over" do
      # Attach :evicted telemetry first so we can stop A as soon as its
      # max-restarts exhausts (otherwise A re-races B for the vacant name).
      attach_telemetry([[:loam, :anchor, :evicted]])

      cluster = :"anchor_cluster_#{System.unique_integer([:positive])}"
      proc_a = :"anchor_sess_a_#{System.unique_integer([:positive])}"
      proc_b = :"anchor_sess_b_#{System.unique_integer([:positive])}"

      port_a = unique_port()
      port_b = unique_port()

      start_session(cluster, proc_a, port_a, [port_b])
      start_session(cluster, proc_b, port_b, [port_a])
      Process.sleep(@handshake_ms)

      # A starts first with max_restarts: 0 (one crash → unregister).
      {:ok, anchor_a} =
        Anchor.start_link(
          registry: proc_a,
          name: :svc,
          child_spec: {AnchorWorker, [report_to: self()]},
          start_jitter_ms: 0,
          vacancy_debounce_ms: 200,
          max_restarts: 0,
          max_seconds: 1
        )

      Process.unlink(anchor_a)

      # Wait for A to register.
      assert wait_until(
               fn ->
                 case Registry.lookup(proc_a, :svc) do
                   [{^anchor_a, _}] -> true
                   _ -> false
                 end
               end,
               3_000
             )

      # B starts with healthy max_restarts; will sit in standby with monitor.
      {:ok, anchor_b} =
        Anchor.start_link(
          registry: proc_b,
          name: :svc,
          child_spec: {AnchorWorker, [report_to: self()]},
          start_jitter_ms: 0,
          vacancy_debounce_ms: 200,
          max_restarts: 3,
          max_seconds: 5
        )

      Process.unlink(anchor_b)

      on_exit(fn ->
        for p <- [anchor_a, anchor_b] do
          try do
            if Process.alive?(p), do: GenServer.stop(p, :normal, 5_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      # B observes A's ownership.
      assert wait_until(
               fn ->
                 case Registry.lookup(proc_b, :svc) do
                   [{^anchor_a, _}] -> true
                   _ -> false
                 end
               end,
               3_000
             )

      # Crash A's child. With max_restarts: 0, LocalSup gives up immediately.
      [{^anchor_a, a_child}] = Registry.lookup(proc_a, :svc)
      Process.exit(a_child, :kill)

      # As soon as A reports :evicted (reason: :owner_lost_locally), stop A
      # so it does not re-race B for the now-vacant name.
      assert_receive {:telemetry, [:loam, :anchor, :evicted], _,
                      %{reason: :owner_lost_locally}},
                     3_000

      try do
        GenServer.stop(anchor_a, :normal, 1_000)
      catch
        :exit, _ -> :ok
      end

      # B should observe the vacancy and take over.
      assert wait_until(
               fn ->
                 case Registry.lookup(proc_b, :svc) do
                   [{^anchor_b, c}] when is_pid(c) -> true
                   _ -> false
                 end
               end,
               5_000
             ),
             "expected B to take over after A's max-restarts exhaustion"

      [{^anchor_b, b_child}] = Registry.lookup(proc_b, :svc)
      assert Process.alive?(b_child)
    end
  end

  defp wait_until(fun, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Stream.repeatedly(fn ->
      Process.sleep(50)
      fun.()
    end)
    |> Enum.find(fn r -> r or System.monotonic_time(:millisecond) > deadline end) || false
  end

  describe "LWW eviction telemetry" do
    test "loser fires :evicted with reason :lww_lost; child terminate/2 ran" do
      cluster = :"anchor_cluster_#{System.unique_integer([:positive])}"
      proc_a = :"anchor_sess_a_#{System.unique_integer([:positive])}"
      proc_b = :"anchor_sess_b_#{System.unique_integer([:positive])}"

      port_a = unique_port()
      port_b = unique_port()

      start_session(cluster, proc_a, port_a, [port_b])
      start_session(cluster, proc_b, port_b, [port_a])
      Process.sleep(@handshake_ms)

      attach_telemetry([[:loam, :anchor, :evicted]])

      {:ok, anchor_a} =
        Anchor.start_link(
          registry: proc_a,
          name: :svc,
          child_spec: {AnchorWorker, [report_to: self()]},
          start_jitter_ms: 0,
          vacancy_debounce_ms: 200
        )

      Process.unlink(anchor_a)

      {:ok, anchor_b} =
        Anchor.start_link(
          registry: proc_b,
          name: :svc,
          child_spec: {AnchorWorker, [report_to: self()]},
          start_jitter_ms: 0,
          vacancy_debounce_ms: 200
        )

      Process.unlink(anchor_b)

      on_exit(fn ->
        for p <- [anchor_a, anchor_b] do
          try do
            if Process.alive?(p), do: GenServer.stop(p, :normal, 5_000)
          catch
            :exit, _ -> :ok
          end
        end
      end)

      {:ok, [{owner_pid, _}]} = wait_until_converged([proc_a, proc_b], :svc, @converge_ms)

      # Eviction telemetry observed on the loser, with full metadata.
      assert_receive {:telemetry, [:loam, :anchor, :evicted], _,
                      %{
                        reason: :lww_lost,
                        registry: _,
                        name: :svc,
                        local_zid: lzid,
                        winner_zid: wzid
                      }},
                     @converge_ms

      assert is_binary(lzid)
      assert is_binary(wzid)
      assert lzid != wzid

      # The loser's child ran terminate/2 (AnchorWorker reports it).
      assert_received {:anchor_worker_terminated, _terminated_pid, _reason}

      # Loser is alive and in standby with monitor.
      loser_pid = if owner_pid == anchor_a, do: anchor_b, else: anchor_a
      Process.sleep(200)
      loser_state = :sys.get_state(loser_pid)
      assert loser_state.status == :standby
      assert is_reference(loser_state.monitor_ref)
      assert loser_state.local_sup == nil
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
