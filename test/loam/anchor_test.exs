defmodule Loam.AnchorTest do
  use ExUnit.Case, async: true

  alias Loam.Anchor
  alias Loam.Registry
  alias Loam.Test.AnchorWorker

  defp start_registry(ctx) do
    name = Module.concat(__MODULE__, "Reg#{System.unique_integer([:positive])}")
    start_supervised!({Loam.Registry.Session, name: name})
    Map.put(ctx, :registry, name)
  end

  defp start_anchor(opts) do
    start_supervised!({Anchor, opts})
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

  defp wait_for_owner(registry, name, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_owner(registry, name, deadline)
  end

  defp do_wait_for_owner(registry, name, deadline) do
    case Registry.lookup(registry, name) do
      [{server_pid, child_pid}] when is_pid(child_pid) ->
        {:ok, server_pid, child_pid}

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :timeout
        else
          Process.sleep(10)
          do_wait_for_owner(registry, name, deadline)
        end
    end
  end

  describe "child_spec/1" do
    test "returns a permanent worker spec" do
      spec = Anchor.child_spec(registry: :r, name: :n, child_spec: {AnchorWorker, []})
      assert %{id: _, start: {Loam.Anchor, :start_link, [_]}, type: :worker, restart: :permanent} =
               spec
    end

    test "id is overridable" do
      spec = Anchor.child_spec(id: :custom, registry: :r, name: :n, child_spec: {AnchorWorker, []})
      assert spec.id == :custom
    end
  end

  describe "single-BEAM register-on-start" do
    setup :start_registry

    test "registers and starts the child", %{registry: r} do
      attach_telemetry([[:loam, :anchor, :registered], [:loam, :anchor, :child_started]])

      start_anchor(
        registry: r,
        name: :svc,
        child_spec: {AnchorWorker, [report_to: self()]},
        start_jitter_ms: 0,
        vacancy_debounce_ms: 0
      )

      assert {:ok, _server_pid, child_pid} = wait_for_owner(r, :svc)
      assert is_pid(child_pid)
      assert_receive {:anchor_worker_started, ^child_pid}, 500

      assert_receive {:telemetry, [:loam, :anchor, :registered], _, %{registry: ^r, name: :svc}}, 500
      assert_receive {:telemetry, [:loam, :anchor, :child_started], _,
                      %{registry: ^r, name: :svc, child_pid: ^child_pid}}, 500
    end

    test "accepts {Module, args} child-spec shape", %{registry: r} do
      start_anchor(
        registry: r,
        name: :svc,
        child_spec: {AnchorWorker, [report_to: self()]},
        start_jitter_ms: 0
      )

      assert {:ok, _, _} = wait_for_owner(r, :svc)
    end

    test "accepts full %{id, start, ...} child-spec map", %{registry: r} do
      child_spec = %{
        id: AnchorWorker,
        start: {AnchorWorker, :start_link, [[report_to: self()]]},
        restart: :permanent,
        type: :worker
      }

      start_anchor(registry: r, name: :svc, child_spec: child_spec, start_jitter_ms: 0)
      assert {:ok, _, _} = wait_for_owner(r, :svc)
    end
  end

  describe "local crash and restart" do
    setup :start_registry

    test "child crash is restarted by LocalSup; name stays registered", %{registry: r} do
      attach_telemetry([[:loam, :anchor, :child_started]])

      start_anchor(
        registry: r,
        name: :svc,
        child_spec: {AnchorWorker, [report_to: self()]},
        start_jitter_ms: 0,
        max_restarts: 5,
        max_seconds: 5
      )

      assert {:ok, server_pid, pid1} = wait_for_owner(r, :svc)
      assert_receive {:telemetry, [:loam, :anchor, :child_started], _, %{child_pid: ^pid1}}, 500

      Process.exit(pid1, :kill)

      assert_receive {:telemetry, [:loam, :anchor, :child_started], _, %{child_pid: pid2}}, 1_000
      assert pid2 != pid1
      assert Process.alive?(pid2)

      # Server (the registered owner) is unchanged across child restart.
      assert [{^server_pid, _value}] = Registry.lookup(r, :svc)
    end
  end

  describe "max-restarts exhaustion" do
    setup :start_registry

    test "LocalSup gives up; anchor unregisters; name vacates", %{registry: r} do
      attach_telemetry([[:loam, :anchor, :evicted]])

      start_anchor(
        registry: r,
        name: :svc,
        child_spec: {AnchorWorker, [report_to: self()]},
        start_jitter_ms: 0,
        max_restarts: 0,
        max_seconds: 1
      )

      assert {:ok, _server_pid, pid1} = wait_for_owner(r, :svc)
      Process.exit(pid1, :kill)

      assert_receive {:telemetry, [:loam, :anchor, :evicted], _,
                      %{reason: :owner_lost_locally, registry: ^r, name: :svc}}, 2_000

      # Name vacates.
      Process.sleep(50)
      assert [] = Registry.lookup(r, :svc)
    end
  end
end
