defmodule Loam.Anchor.Server do
  @moduledoc false

  use GenServer

  alias Loam.Anchor.LocalSup
  alias Loam.Registry

  @default_max_restarts 3
  @default_max_seconds 5
  @default_start_jitter_ms 500
  @default_vacancy_debounce_ms 1_000

  # Backoff schedule (ms) for polling LocalSup.which_children after a child
  # :DOWN, while we wait for the supervisor to restart the child.
  @child_poll_schedule [10, 25, 50, 100, 200, 500]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if pn = Keyword.get(opts, :process_name), do: [name: pn], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    child_spec = Keyword.fetch!(opts, :child_spec)
    :ok = validate_child_spec!(child_spec)

    state = %{
      registry: Keyword.fetch!(opts, :registry),
      name: Keyword.fetch!(opts, :name),
      child_spec: child_spec,
      child_id: nil,
      max_restarts: Keyword.get(opts, :max_restarts, @default_max_restarts),
      max_seconds: Keyword.get(opts, :max_seconds, @default_max_seconds),
      start_jitter_ms: Keyword.get(opts, :start_jitter_ms, @default_start_jitter_ms),
      vacancy_debounce_ms:
        Keyword.get(opts, :vacancy_debounce_ms, @default_vacancy_debounce_ms),
      local_zid: nil,
      status: :starting,
      monitor_ref: nil,
      local_sup: nil,
      local_sup_ref: nil,
      child_pid: nil,
      child_ref: nil
    }

    Process.send_after(self(), :try_start, jitter(state.start_jitter_ms))
    {:ok, state}
  end

  # `Loam.Anchor` only supports `:permanent` restart with a single child spec.
  # See docs/journal/2026-04-28-anchor-permanent-only-decision.md.
  defp validate_child_spec!(spec) when is_list(spec) do
    raise ArgumentError,
          "Loam.Anchor accepts a single child_spec, not a list. Multi-child anchors are not supported; mount multiple Loam.Anchor instances."
  end

  defp validate_child_spec!(spec) do
    normalized = Supervisor.child_spec(spec, [])
    restart = Map.get(normalized, :restart, :permanent)

    case restart do
      :permanent ->
        :ok

      other ->
        raise ArgumentError,
              "Loam.Anchor requires :permanent restart semantics; got #{inspect(other)}. " <>
                "See docs/journal/2026-04-28-anchor-permanent-only-decision.md."
    end
  end

  @impl true
  def handle_info(:try_start, %{status: :starting} = state) do
    {:noreply, attempt_register(state)}
  end

  def handle_info({:loam_registry, :name_vacant, _registry, name}, %{name: name} = state) do
    case state.status do
      :standby -> {:noreply, attempt_register(state)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, pid, _reason},
        %{local_sup_ref: ref, local_sup: pid} = state
      ) do
    # LocalSup gave up (max-restarts exhausted) or otherwise died. Vacate.
    emit_telemetry(:evicted, state, %{reason: :owner_lost_locally})

    new_state = %{
      state
      | local_sup: nil,
        local_sup_ref: nil,
        child_pid: nil,
        child_ref: nil,
        status: :standby
    }

    _ = safe_unregister(new_state)
    {:noreply, install_monitor(new_state)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{child_ref: ref, child_pid: pid} = state) do
    # Child crashed. LocalSup will restart it on its own schedule. Poll.
    Process.send_after(self(), {:poll_child, pid, @child_poll_schedule}, hd(@child_poll_schedule))
    {:noreply, %{state | child_pid: nil, child_ref: nil}}
  end

  def handle_info({:poll_child, _old_pid, _schedule}, %{status: status} = state)
      when status != :owner do
    {:noreply, state}
  end

  def handle_info({:poll_child, old_pid, schedule}, state) do
    case is_pid(state.local_sup) and Process.alive?(state.local_sup) and
           LocalSup.child_pid(state.local_sup) do
      pid when is_pid(pid) and pid != old_pid ->
        ref = Process.monitor(pid)
        emit_telemetry(:child_started, state, %{child_pid: pid})
        {:noreply, %{state | child_pid: pid, child_ref: ref}}

      _ ->
        case schedule do
          [_, next | rest] ->
            Process.send_after(self(), {:poll_child, old_pid, [next | rest]}, next)
            {:noreply, state}

          _ ->
            # Gave up polling. LocalSup will :DOWN us soon if it has died.
            {:noreply, state}
        end
    end
  end

  def handle_info({:loam_registry, :evicted, name, winner_zid}, %{name: name} = state) do
    require Logger

    Logger.info(fn ->
      "Loam.Anchor evicted: registry=#{inspect(state.registry)} name=#{inspect(state.name)} " <>
        "local_zid=#{inspect(state.local_zid)} winner_zid=#{inspect(winner_zid)}"
    end)

    new_state = terminate_child_via_sup(state)

    emit_telemetry(:evicted, state, %{
      reason: :lww_lost,
      local_zid: state.local_zid,
      winner_zid: winner_zid
    })

    new_state = stop_local_sup_only(new_state)
    {:noreply, install_monitor(%{new_state | status: :standby})}
  end

  def handle_info({:EXIT, _from, _reason}, state) do
    # Trapped exit (LocalSup link). The :DOWN handler does the real work.
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = teardown_local_sup(state)
    :ok
  end

  ## Internals

  defp attempt_register(state) do
    case start_local_sup(state) do
      {:ok, sup_pid} ->
        case LocalSup.child_pid(sup_pid) do
          child_pid when is_pid(child_pid) ->
            register_with_child(state, sup_pid, child_pid)

          nil ->
            stop_local_sup(sup_pid)
            install_monitor(%{state | status: :standby})
        end

      {:error, reason} ->
        raise "Loam.Anchor failed to start LocalSup: #{inspect(reason)}"
    end
  end

  defp register_with_child(state, sup_pid, child_pid) do
    case Registry.register(state.registry, state.name, self(), child_pid) do
      :ok ->
        sup_ref = Process.monitor(sup_pid)
        child_ref = Process.monitor(child_pid)
        local_zid = capture_zid(state.registry) || state.local_zid
        child_id = LocalSup.child_id(sup_pid)
        emit_telemetry(:registered, state, %{local_zid: local_zid})
        emit_telemetry(:child_started, state, %{child_pid: child_pid})

        install_monitor(%{
          state
          | status: :owner,
            local_sup: sup_pid,
            local_sup_ref: sup_ref,
            child_pid: child_pid,
            child_ref: child_ref,
            child_id: child_id,
            local_zid: local_zid
        })

      {:error, {:already_registered, _pid}} ->
        stop_local_sup(sup_pid)
        install_monitor(%{state | status: :standby})

      {:error, reason} ->
        stop_local_sup(sup_pid)
        raise "Loam.Anchor registration failed: #{inspect(reason)}"
    end
  end

  defp capture_zid(registry) do
    Loam.Registry.Session.zid(registry)
  catch
    :exit, _ -> nil
  end

  defp terminate_child_via_sup(%{local_sup: nil} = state), do: state

  defp terminate_child_via_sup(%{local_sup: sup, child_id: id} = state) when is_pid(sup) do
    if is_reference(state.child_ref), do: Process.demonitor(state.child_ref, [:flush])

    if Process.alive?(sup) and not is_nil(id) do
      try do
        Supervisor.terminate_child(sup, id)
      catch
        :exit, _ -> :ok
      end
    end

    %{state | child_pid: nil, child_ref: nil}
  end

  defp stop_local_sup_only(%{local_sup: nil} = state), do: state

  defp stop_local_sup_only(%{local_sup: sup, local_sup_ref: ref} = state) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    stop_local_sup(sup)
    _ = safe_unregister(state)
    %{state | local_sup: nil, local_sup_ref: nil}
  end

  defp start_local_sup(state) do
    LocalSup.start_link(
      child_spec: state.child_spec,
      max_restarts: state.max_restarts,
      max_seconds: state.max_seconds
    )
  end

  defp stop_local_sup(sup) when is_pid(sup) do
    if Process.alive?(sup) do
      Process.unlink(sup)
      try do
        Supervisor.stop(sup, :shutdown)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp install_monitor(state) do
    if is_reference(state.monitor_ref) do
      state
    else
      case Registry.monitor(state.registry, state.name, debounce_ms: state.vacancy_debounce_ms) do
        {:ok, ref} -> %{state | monitor_ref: ref}
        {:error, _} -> state
      end
    end
  end

  defp teardown_local_sup(%{local_sup: nil} = state), do: state

  defp teardown_local_sup(%{local_sup: sup, local_sup_ref: ref} = state) do
    if is_reference(ref), do: Process.demonitor(ref, [:flush])
    if is_reference(state.child_ref), do: Process.demonitor(state.child_ref, [:flush])
    stop_local_sup(sup)
    _ = safe_unregister(state)
    %{state | local_sup: nil, local_sup_ref: nil, child_pid: nil, child_ref: nil}
  end

  defp safe_unregister(state) do
    Registry.unregister(state.registry, state.name)
  catch
    :exit, _ -> :ok
  end

  defp jitter(0), do: 0
  defp jitter(max) when is_integer(max) and max > 0, do: :rand.uniform(max + 1) - 1

  defp emit_telemetry(event, state, extra_meta) do
    :telemetry.execute(
      [:loam, :anchor, event],
      %{system_time: System.system_time()},
      Map.merge(%{registry: state.registry, name: state.name}, extra_meta)
    )
  end
end
