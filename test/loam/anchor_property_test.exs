defmodule Loam.AnchorPropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduledoc """
  Cross-Session property test for `Loam.Anchor`.

  Generates sequences of `{:start, side}`, `{:stop, side}`, and
  `{:crash, side}` events across two `Loam.Registry.Session` instances
  peering over Zenoh in one BEAM. After each generated sequence, waits
  for quiescence and asserts the convergence invariants:

    * Cluster eventually has at most one live owner of the name.
    * Both sides' `Registry.lookup/2` agree on the result.
    * If any anchor is alive and registered, it agrees with the lookup.
    * Every received `[:loam, :anchor, :evicted]` telemetry event has a
      well-formed shape.

  ### Event vocabulary

  Six event kinds are described in the parent task. Three (`partition`,
  `heal`, `peer_kill`) require root-level network manipulation or OS
  process kill; those are exercised in the targeted `:partition` and
  `:peer_death` tests. This property test covers the three event kinds
  (`anchor_start`, `anchor_stop`, `child_crash`) that interact with the
  same Server state machine and Registry monitor + LWW + jitter, run in
  combinations the targeted tests do not cover.
  """

  @moduletag :integration
  @moduletag timeout: 240_000

  alias Loam.Anchor
  alias Loam.Registry
  alias Loam.Registry.Session
  alias Loam.Test.AnchorWorker

  @name :svc
  @max_ops 8
  @settle_ms 1_500
  @vacancy_debounce_ms 200
  @start_jitter_ms 0

  setup_all do
    cluster = :"loam_anchor_prop_#{:erlang.unique_integer([:positive])}"
    proc_a = :"#{cluster}_a"
    proc_b = :"#{cluster}_b"

    port_a = unique_port()
    port_b = unique_port()

    {:ok, sess_a} = start_session(cluster, proc_a, port_a, [port_b])
    {:ok, sess_b} = start_session(cluster, proc_b, port_b, [port_a])
    Process.unlink(sess_a)
    Process.unlink(sess_b)

    Process.sleep(1_500)

    on_exit(fn ->
      for s <- [sess_a, sess_b] do
        try do
          if Process.alive?(s), do: GenServer.stop(s, :normal, 5_000)
        catch
          _, _ -> :ok
        end
      end
    end)

    {:ok, proc_a: proc_a, proc_b: proc_b}
  end

  property "post-quiescence: at most one owner; both sides agree",
           %{proc_a: proc_a, proc_b: proc_b} do
    parent = self()
    handler_id = {__MODULE__, System.unique_integer([:positive])}

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:loam, :anchor, :evicted]],
        fn event, measurements, metadata, _config ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    check all(plan <- plan_gen(), max_runs: 12) do
      drain_telemetry()
      reset(proc_a, proc_b)

      anchors = apply_plan(plan, %{a: nil, b: nil}, proc_a: proc_a, proc_b: proc_b)

      Process.sleep(@settle_ms)

      lookup_a = Registry.lookup(proc_a, @name)
      lookup_b = Registry.lookup(proc_b, @name)

      assert lookup_a == lookup_b, """
      Sides did not converge.
        plan:    #{inspect(plan)}
        a:       #{inspect(lookup_a)}
        b:       #{inspect(lookup_b)}
      """

      assert match?([] when true, lookup_a) or match?([{_, _}], lookup_a), """
      More than one entry for #{inspect(@name)}.
        plan:   #{inspect(plan)}
        lookup: #{inspect(lookup_a)}
      """

      # If an entry exists, the owner pid must match a live anchor on one side.
      case lookup_a do
        [] ->
          :ok

        [{owner_pid, child_pid}] ->
          assert is_pid(child_pid)
          live_anchors = anchors |> Map.values() |> Enum.filter(&is_pid_alive?/1)

          assert owner_pid in live_anchors, """
          Owner pid does not match a live anchor.
            plan:         #{inspect(plan)}
            owner:        #{inspect(owner_pid)}
            live_anchors: #{inspect(live_anchors)}
          """
      end

      # All collected :evicted events have the documented metadata shape.
      collect_telemetry()
      |> Enum.each(fn {event, _measurements, meta} ->
        assert event == [:loam, :anchor, :evicted]
        assert is_atom(meta.registry)
        assert meta.name == @name
        assert meta.reason in [:lww_lost, :owner_lost_locally]
      end)

      stop_anchors(anchors)
    end
  end

  ## Plan application

  defp apply_plan([], state, _opts), do: state

  defp apply_plan([{:start, side} | rest], state, opts) do
    case Map.fetch!(state, side) do
      nil ->
        registry = Keyword.fetch!(opts, side_to_proc(side, opts))

        {:ok, anchor} =
          Anchor.start_link(
            registry: registry,
            name: @name,
            child_spec: {AnchorWorker, []},
            start_jitter_ms: @start_jitter_ms,
            vacancy_debounce_ms: @vacancy_debounce_ms,
            max_restarts: 3,
            max_seconds: 5
          )

        Process.unlink(anchor)
        # Brief settle so the start race resolves before the next op.
        Process.sleep(50)
        apply_plan(rest, Map.put(state, side, anchor), opts)

      _alive ->
        apply_plan(rest, state, opts)
    end
  end

  defp apply_plan([{:stop, side} | rest], state, opts) do
    case Map.fetch!(state, side) do
      nil ->
        apply_plan(rest, state, opts)

      pid when is_pid(pid) ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
        catch
          _, _ -> :ok
        end

        Process.sleep(50)
        apply_plan(rest, Map.put(state, side, nil), opts)
    end
  end

  defp apply_plan([{:crash, side} | rest], state, opts) do
    proc_atom = Keyword.fetch!(opts, side_to_proc(side, opts))

    case Registry.lookup(proc_atom, @name) do
      [{_owner, child_pid}] when is_pid(child_pid) ->
        anchor_pid = Map.get(state, side)

        if is_pid_alive?(anchor_pid) and Process.info(anchor_pid, :registered_name) do
          # Only crash if our local anchor on this side is the registered owner.
          [{owner, _}] = Registry.lookup(proc_atom, @name)

          if owner == anchor_pid do
            Process.exit(child_pid, :kill)
            Process.sleep(50)
          end
        end

        apply_plan(rest, state, opts)

      _ ->
        apply_plan(rest, state, opts)
    end
  end

  defp side_to_proc(:a, _opts), do: :proc_a
  defp side_to_proc(:b, _opts), do: :proc_b

  defp is_pid_alive?(nil), do: false
  defp is_pid_alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  defp stop_anchors(anchors) do
    for {_side, pid} <- anchors, is_pid(pid) do
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
      catch
        _, _ -> :ok
      end
    end
  end

  ## Generators

  defp event_gen do
    one_of([
      {:start, member_of([:a, :b])},
      {:stop, member_of([:a, :b])},
      {:crash, member_of([:a, :b])}
    ])
    |> bind(fn
      {kind, side_gen} ->
        gen all(side <- side_gen, do: {kind, side})
    end)
  end

  defp plan_gen do
    list_of(event_gen(), min_length: 1, max_length: @max_ops)
  end

  ## Helpers

  defp reset(proc_a, proc_b) do
    # Make sure no anchors are leftover registered.
    _ = safe_unregister(proc_a, @name)
    _ = safe_unregister(proc_b, @name)
    Process.sleep(300)
  end

  defp safe_unregister(registry, name) do
    Registry.unregister(registry, name)
  catch
    _, _ -> :ok
  end

  defp drain_telemetry do
    receive do
      {:telemetry, _, _, _} -> drain_telemetry()
    after
      0 -> :ok
    end
  end

  defp collect_telemetry(acc \\ []) do
    receive do
      {:telemetry, e, m, md} -> collect_telemetry([{e, m, md} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp start_session(cluster, proc, listen_port, connect_ports) do
    Session.start_link(
      name: cluster,
      process_name: proc,
      heartbeat_interval_ms: 1_000,
      heartbeat_misses: 3,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: Enum.map(connect_ports, fn p -> "tcp/127.0.0.1:#{p}" end),
        multicast_scouting: false
      ]
    )
  end

  defp unique_port, do: 29_000 + :erlang.unique_integer([:positive, :monotonic])
end
