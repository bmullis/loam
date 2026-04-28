defmodule Loam.Registry.Session do
  @moduledoc """
  Per-instance owner of one `Loam.Registry`'s state and Zenoh wiring.

  Holds:

    * the mirror table (`Loam.Registry.Mirror`),
    * the Lamport counter,
    * the local ZID,
    * the per-pid monitor map for cleaning up registrations on pid exit,
    * optionally, a Zenohex session, broad subscriber, and per-key publishers.

  ## Naming

  `:name` (atom) is the *cluster identity* of this registry — it is the
  segment of the Zenoh keyexpr that all peers share. Two BEAMs that want to
  participate in the same registry must pass the same `:name`.

  `:process_name` (atom, optional) is the local Erlang process registration
  name. It defaults to `:name`, which is the right choice in production
  (one registry instance per BEAM). For tests that run two Sessions in the
  same BEAM, set distinct `:process_name`s while keeping `:name` shared.

  When started without a `:zenoh` option the Session runs in *local-only*
  mode: register/unregister mutate the mirror but no announces are
  published. This is the mode used by the public-API smoke tests.

  When started with `:zenoh: [...]`, the Session opens a Zenohex session,
  declares a broad subscription on `<namespace>/<registry_name>/**`, and
  publishes every successful register/unregister as an `Announce` payload.
  Inbound samples are decoded and applied via the same Mirror calls, with
  Lamport observe-on-receive bookkeeping.

  ## Liveness and bootstrap

    * Each Session emits a `:heartbeat` to `_meta/heartbeat` every
      `:heartbeat_interval_ms` (default 5_000).
    * Each Session periodically (~half the heartbeat interval) reads
      `Zenohex.Session.info.peers_zid` and the per-peer last-heartbeat
      timestamp. A peer is *alive* iff its ZID is in `peers_zid` AND its
      last heartbeat is within `heartbeat_interval_ms * heartbeat_misses`
      (default 3, so 15s). Otherwise its entries are evicted from the
      mirror.
    * On the first heartbeat received from a peer we have not seen before,
      this Session publishes a `:snapshot_request`. Existing peers reply
      with a `:snapshot` of their owned entries. New entries that arrive
      during this window are LWW-merged idempotently with the snapshot.
  """

  use GenServer
  require Logger

  alias Loam.Registry.{Announce, KeyExpr, Lamport, Mirror}

  @default_namespace "loam/reg"
  @default_heartbeat_interval_ms 5_000
  @default_heartbeat_misses 3

  @type name :: term()

  ## Public API used by Loam.Registry facade

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    process_name = Keyword.get(opts, :process_name) || Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: process_name)
  end

  def child_spec(opts) do
    process_name = Keyword.get(opts, :process_name) || Keyword.fetch!(opts, :name)

    %{
      id: process_name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @spec zid(GenServer.server()) :: binary()
  def zid(server), do: GenServer.call(server, :zid)

  @spec table(GenServer.server()) :: :ets.tid() | atom()
  def table(server), do: GenServer.call(server, :table)

  @spec register(GenServer.server(), name(), pid(), term()) ::
          :ok | {:error, {:already_registered, pid()} | :remote_pid}
  def register(server, name, pid, value) when is_pid(pid) do
    GenServer.call(server, {:register, name, pid, value})
  end

  @spec unregister(GenServer.server(), name()) :: :ok | {:error, :not_owner}
  def unregister(server, name) do
    GenServer.call(server, {:unregister, name})
  end

  @spec monitor(GenServer.server(), name(), pid(), keyword()) :: {:ok, reference()}
  def monitor(server, name, watcher_pid, opts) when is_pid(watcher_pid) do
    GenServer.call(server, {:monitor, name, watcher_pid, opts})
  end

  @spec demonitor(GenServer.server(), reference()) :: :ok
  def demonitor(server, ref) when is_reference(ref) do
    GenServer.call(server, {:demonitor, ref})
  end

  ## GenServer

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    zenoh_config = Keyword.get(opts, :zenoh)
    zid_override = Keyword.get(opts, :zid)

    heartbeat_interval_ms =
      Keyword.get(opts, :heartbeat_interval_ms, @default_heartbeat_interval_ms)

    heartbeat_misses = Keyword.get(opts, :heartbeat_misses, @default_heartbeat_misses)

    base_state = %{
      name: name,
      namespace: namespace,
      table: Mirror.new(),
      zid: nil,
      lamport: Lamport.new(),
      monitors: %{},
      peers: %{},
      watchers_by_name: %{},
      watcher_meta: %{},
      watcher_pids: %{},
      heartbeat_interval_ms: heartbeat_interval_ms,
      heartbeat_misses: heartbeat_misses,
      session_id: nil,
      sub_id: nil,
      announce_pub_id: nil
    }

    case open_zenoh(zenoh_config, namespace, name) do
      {:ok, %{session_id: nil}} ->
        zid = zid_override || synthesize_local_zid(name)
        {:ok, %{base_state | zid: zid}}

      {:ok, %{session_id: sid, sub_id: sub_id, info_zid: info_zid, pub_id: pub_id}} ->
        zid = zid_override || info_zid
        state = %{base_state | zid: zid, session_id: sid, sub_id: sub_id, announce_pub_id: pub_id}
        schedule_heartbeat(state)
        schedule_peer_check(state)
        {:ok, state}

      {:error, reason} ->
        {:stop, {:zenoh_init_failed, reason}}
    end
  end

  @impl true
  def handle_call(:zid, _from, state), do: {:reply, state.zid, state}
  def handle_call(:table, _from, state), do: {:reply, state.table, state}

  def handle_call({:register, _name, pid, _value}, _from, state)
      when node(pid) != node() do
    {:reply, {:error, :remote_pid}, state}
  end

  def handle_call({:register, name, pid, value}, _from, state) do
    case Mirror.lookup(state.table, name) do
      [{existing_pid, _v}] ->
        {:reply, {:error, {:already_registered, existing_pid}}, state}

      [] ->
        {ts, lamport} = Lamport.tick(state.lamport)
        state = %{state | lamport: lamport}

        case Mirror.apply_register(state.table, name, pid, value, ts, state.zid) do
          {:applied, :new} ->
            state = track(state, pid, name)
            state = publish_register(state, name, pid, value, ts)
            state = notify_owned(state, name)
            {:reply, :ok, state}

          other ->
            {:reply, {:error, {:mirror_unexpected, other}}, state}
        end
    end
  end

  def handle_call({:unregister, name}, _from, state) do
    case Mirror.lookup(state.table, name) do
      [] ->
        {:reply, :ok, state}

      [{pid, _value}] ->
        {ts, lamport} = Lamport.tick(state.lamport)
        state = %{state | lamport: lamport}

        case Mirror.apply_unregister(state.table, name, ts, state.zid) do
          :applied ->
            state = untrack(state, pid, name)
            state = publish_unregister(state, name, ts)
            state = notify_vacant(state, name)
            {:reply, :ok, state}

          :rejected ->
            {:reply, {:error, :not_owner}, state}

          :duplicate ->
            {:reply, :ok, state}
        end
    end
  end

  def handle_call({:monitor, name, watcher_pid, opts}, _from, state) do
    {ref, state} = install_watcher(state, name, watcher_pid, opts)
    {:reply, {:ok, ref}, state}
  end

  def handle_call({:demonitor, ref}, _from, state) do
    {:reply, :ok, remove_watcher(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, mref, :process, pid, _reason}, state) do
    state = drop_watchers_for_dead_pid(state, mref, pid)
    state = drop_registrations_for_dead_pid(state, pid)
    {:noreply, state}
  end

  def handle_info({:debounce_fire, ref}, state) do
    state = handle_debounce_fire(state, ref)
    {:noreply, state}
  end

  def handle_info(%Zenohex.Sample{} = sample, state) do
    state = handle_sample(sample, state)
    {:noreply, state}
  end

  def handle_info(:heartbeat_tick, state) do
    state = publish_heartbeat(state)
    schedule_heartbeat(state)
    {:noreply, state}
  end

  def handle_info(:peer_check_tick, state) do
    state = check_peers(state)
    schedule_peer_check(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.session_id, do: Zenohex.Session.close(state.session_id)
    :ok
  end

  ## Inbound dispatch

  defp handle_sample(%Zenohex.Sample{key_expr: key, payload: payload}, state) do
    case KeyExpr.classify(key) do
      :announce ->
        case Announce.decode(payload) do
          {:ok, decoded} ->
            apply_inbound(decoded, state)

          {:error, reason} ->
            Logger.warning(
              "loam.registry: dropped malformed sample on #{key}: #{inspect(reason)}"
            )

            state
        end

      :ignore ->
        state
    end
  end

  defp apply_inbound({:register, name, pid, value, lamport, sender_zid}, state) do
    state = observe(state, lamport)

    case Mirror.apply_register(state.table, name, pid, value, lamport, sender_zid) do
      {:applied, {:evicted, evicted_pid, _evicted_zid}} ->
        send_eviction(evicted_pid, name, sender_zid)
        notify_owned(state, name)

      {:applied, :new} ->
        notify_owned(state, name)

      _ ->
        state
    end
  end

  defp apply_inbound({:unregister, name, lamport, sender_zid}, state) do
    state = observe(state, lamport)

    case Mirror.apply_unregister(state.table, name, lamport, sender_zid) do
      :applied -> notify_vacant(state, name)
      _ -> state
    end
  end

  defp apply_inbound({:heartbeat, sender_zid, lamport}, state) do
    state = observe(state, lamport)
    {is_new, state} = touch_peer(state, sender_zid)
    if is_new, do: publish_snapshot_request(state), else: state
  end

  defp apply_inbound({:snapshot_request, requester_zid}, state) do
    # Reply with our owned entries so the requester can bootstrap.
    {_is_new, state} = touch_peer(state, requester_zid)
    publish_snapshot(state)
  end

  defp apply_inbound({:snapshot, sender_zid, entries}, state) do
    {_is_new, state} = touch_peer(state, sender_zid)

    Enum.reduce(entries, state, fn {name, pid, value, lamport}, st ->
      st = observe(st, lamport)

      case Mirror.apply_register(st.table, name, pid, value, lamport, sender_zid) do
        {:applied, _} -> notify_owned(st, name)
        _ -> st
      end
    end)
  end

  defp apply_inbound(_other, state), do: state

  defp touch_peer(state, zid) when zid == state.zid, do: {false, state}

  defp touch_peer(state, zid) do
    now = System.monotonic_time(:millisecond)
    is_new = not Map.has_key?(state.peers, zid)
    peers = Map.put(state.peers, zid, %{last_heartbeat_ms: now})
    {is_new, %{state | peers: peers}}
  end

  defp observe(state, lamport) do
    {_ts, l2} = Lamport.observe(state.lamport, lamport)
    %{state | lamport: l2}
  end

  defp send_eviction(pid, name, winner_zid) do
    send(pid, {:loam_registry, :evicted, name, winner_zid})
  end

  ## Outbound publishing

  defp publish_register(state, _name, _pid, _value, _ts) when state.session_id == nil, do: state

  defp publish_register(state, name, pid, value, ts) do
    payload = Announce.encode({:register, name, pid, value, ts, state.zid})
    publish(state, payload)
  end

  defp publish_unregister(state, _name, _ts) when state.session_id == nil, do: state

  defp publish_unregister(state, name, ts) do
    payload = Announce.encode({:unregister, name, ts, state.zid})
    publish(state, payload)
  end

  defp publish_heartbeat(state) when state.session_id == nil, do: state

  defp publish_heartbeat(state) do
    {ts, lamport} = Lamport.tick(state.lamport)
    state = %{state | lamport: lamport}
    payload = Announce.encode({:heartbeat, state.zid, ts})
    publish(state, payload)
  end

  defp publish_snapshot_request(state) when state.session_id == nil, do: state

  defp publish_snapshot_request(state) do
    payload = Announce.encode({:snapshot_request, state.zid})
    publish(state, payload)
  end

  defp publish_snapshot(state) when state.session_id == nil, do: state

  defp publish_snapshot(state) do
    entries = Mirror.entries_owned_by(state.table, state.zid)

    if entries == [] do
      state
    else
      payload = Announce.encode({:snapshot, state.zid, entries})
      publish(state, payload)
    end
  end

  # All Registry traffic goes through the single announce publisher declared
  # at init time. Reusing one publisher avoids the per-name discovery race
  # documented in the Mac↔Pi journal entry.
  defp publish(state, payload) do
    _ = Zenohex.Publisher.put(state.announce_pub_id, payload)
    state
  end

  ## Init helpers

  defp open_zenoh(nil, _ns, _name), do: {:ok, %{session_id: nil}}

  defp open_zenoh(zenoh_opts, namespace, registry_name) do
    with {:ok, json5} <- build_zenoh_config(zenoh_opts),
         {:ok, session_id} <- Zenohex.Session.open(json5),
         {:ok, info} <- Zenohex.Session.info(session_id),
         prefix = KeyExpr.prefix(namespace, registry_name),
         {:ok, sub_id} <-
           Zenohex.Session.declare_subscriber(session_id, "#{prefix}/**", self(),
             allowed_origin: :remote
           ),
         announce = KeyExpr.announce_key(namespace, registry_name),
         {:ok, pub_id} <- Zenohex.Session.declare_publisher(session_id, announce) do
      {:ok, %{session_id: session_id, sub_id: sub_id, info_zid: info.zid, pub_id: pub_id}}
    end
  end

  defp build_zenoh_config(opts) do
    {raw, opts} = Keyword.pop(opts, :raw, [])
    base = Zenohex.Config.default()

    with {:ok, after_named} <-
           Enum.reduce_while(opts, {:ok, base}, fn {key, value}, {:ok, acc} ->
             case Zenohex.Config.insert_json5(acc, json5_path(key), to_json5(value)) do
               {:ok, updated} -> {:cont, {:ok, updated}}
               {:error, reason} -> {:halt, {:error, {:zenoh_config, key, reason}}}
             end
           end) do
      Enum.reduce_while(raw, {:ok, after_named}, fn {path, value}, {:ok, acc} ->
        case Zenohex.Config.insert_json5(acc, path, value) do
          {:ok, updated} -> {:cont, {:ok, updated}}
          {:error, reason} -> {:halt, {:error, {:zenoh_config_raw, path, reason}}}
        end
      end)
    end
  end

  defp json5_path(:mode), do: "mode"
  defp json5_path(:listen), do: "listen/endpoints"
  defp json5_path(:connect), do: "connect/endpoints"
  defp json5_path(:multicast_scouting), do: "scouting/multicast/enabled"

  defp to_json5(value) when is_boolean(value), do: to_string(value)
  defp to_json5(value) when is_atom(value), do: ~s("#{value}")
  defp to_json5(value) when is_binary(value), do: ~s("#{value}")

  defp to_json5(value) when is_list(value) do
    inner = value |> Enum.map(&~s("#{&1}")) |> Enum.join(",")
    "[#{inner}]"
  end

  ## Monitor bookkeeping

  defp track(state, pid, name) do
    {ref, names} =
      case Map.fetch(state.monitors, pid) do
        {:ok, {existing_ref, names}} -> {existing_ref, MapSet.put(names, name)}
        :error -> {Process.monitor(pid), MapSet.new([name])}
      end

    %{state | monitors: Map.put(state.monitors, pid, {ref, names})}
  end

  defp untrack(state, pid, name) do
    case Map.fetch(state.monitors, pid) do
      :error ->
        state

      {:ok, {ref, names}} ->
        names = MapSet.delete(names, name)

        if MapSet.size(names) == 0 do
          Process.demonitor(ref, [:flush])
          %{state | monitors: Map.delete(state.monitors, pid)}
        else
          %{state | monitors: Map.put(state.monitors, pid, {ref, names})}
        end
    end
  end

  defp drop_registrations_for_dead_pid(state, pid) do
    case Map.fetch(state.monitors, pid) do
      :error ->
        state

      {:ok, {_ref, names}} ->
        state =
          Enum.reduce(names, state, fn name, st ->
            {ts, lamport} = Lamport.tick(st.lamport)
            st = %{st | lamport: lamport}

            case Mirror.apply_unregister(st.table, name, ts, st.zid) do
              :applied ->
                st = publish_unregister(st, name, ts)
                notify_vacant(st, name)

              _ ->
                st
            end
          end)

        %{state | monitors: Map.delete(state.monitors, pid)}
    end
  end

  ## Watcher bookkeeping (monitor/2)
  #
  # State shape:
  #   watchers_by_name :: %{name => MapSet.t(ref)}
  #   watcher_meta     :: %{ref => %{pid: pid, name: term, debounce_ms: int, timer: tref | nil}}
  #   watcher_pids     :: %{watcher_pid => {monitor_ref, MapSet.t(ref)}}
  #
  # Debounce semantic: when an owned->vacant edge is observed for `name`, each
  # watcher of that name with `debounce_ms > 0` schedules a timer; the
  # `:name_vacant` message is sent only when the timer fires AND the name is
  # still vacant in the local mirror at fire time. If a new owner appears
  # before the timer fires, `notify_owned/2` cancels the pending timer.

  defp install_watcher(state, name, watcher_pid, opts) do
    ref = make_ref()
    debounce_ms = validate_debounce(Keyword.get(opts, :debounce_ms, 0))

    watcher_pids =
      case Map.fetch(state.watcher_pids, watcher_pid) do
        {:ok, {mref, refs}} ->
          Map.put(state.watcher_pids, watcher_pid, {mref, MapSet.put(refs, ref)})

        :error ->
          mref = Process.monitor(watcher_pid)
          Map.put(state.watcher_pids, watcher_pid, {mref, MapSet.new([ref])})
      end

    watchers_by_name =
      Map.update(state.watchers_by_name, name, MapSet.new([ref]), &MapSet.put(&1, ref))

    watcher_meta =
      Map.put(state.watcher_meta, ref, %{
        pid: watcher_pid,
        name: name,
        debounce_ms: debounce_ms,
        timer: nil
      })

    {ref,
     %{
       state
       | watchers_by_name: watchers_by_name,
         watcher_meta: watcher_meta,
         watcher_pids: watcher_pids
     }}
  end

  defp validate_debounce(ms) when is_integer(ms) and ms >= 0, do: ms
  defp validate_debounce(_), do: 0

  defp remove_watcher(state, ref) do
    case Map.fetch(state.watcher_meta, ref) do
      :error ->
        state

      {:ok, %{pid: watcher_pid, name: name, timer: timer}} ->
        cancel_timer(timer)
        state = drop_ref_from_name_index(state, ref, name)
        state = %{state | watcher_meta: Map.delete(state.watcher_meta, ref)}

        watcher_pids =
          case Map.fetch(state.watcher_pids, watcher_pid) do
            {:ok, {mref, refs}} ->
              refs = MapSet.delete(refs, ref)

              if MapSet.size(refs) == 0 do
                Process.demonitor(mref, [:flush])
                Map.delete(state.watcher_pids, watcher_pid)
              else
                Map.put(state.watcher_pids, watcher_pid, {mref, refs})
              end

            :error ->
              state.watcher_pids
          end

        %{state | watcher_pids: watcher_pids}
    end
  end

  defp drop_watchers_for_dead_pid(state, mref, pid) do
    case Map.fetch(state.watcher_pids, pid) do
      {:ok, {^mref, refs}} ->
        state = %{state | watcher_pids: Map.delete(state.watcher_pids, pid)}

        Enum.reduce(refs, state, fn ref, st ->
          # Skip Process.demonitor (the monitor already fired) and skip
          # touching watcher_pids again — we cleared it above.
          remove_watcher_entry(st, ref)
        end)

      _ ->
        state
    end
  end

  defp remove_watcher_entry(state, ref) do
    case Map.fetch(state.watcher_meta, ref) do
      :error ->
        state

      {:ok, %{name: name, timer: timer}} ->
        cancel_timer(timer)
        state = drop_ref_from_name_index(state, ref, name)
        %{state | watcher_meta: Map.delete(state.watcher_meta, ref)}
    end
  end

  defp drop_ref_from_name_index(state, ref, name) do
    watchers_by_name =
      case Map.fetch(state.watchers_by_name, name) do
        {:ok, refs} ->
          refs = MapSet.delete(refs, ref)

          if MapSet.size(refs) == 0,
            do: Map.delete(state.watchers_by_name, name),
            else: Map.put(state.watchers_by_name, name, refs)

        :error ->
          state.watchers_by_name
      end

    %{state | watchers_by_name: watchers_by_name}
  end

  defp notify_vacant(state, name) do
    case Map.fetch(state.watchers_by_name, name) do
      :error ->
        state

      {:ok, refs} ->
        Enum.reduce(refs, state, fn ref, st -> schedule_or_send_vacant(st, ref, name) end)
    end
  end

  defp schedule_or_send_vacant(state, ref, name) do
    case Map.fetch(state.watcher_meta, ref) do
      :error ->
        state

      {:ok, %{debounce_ms: 0, pid: pid}} ->
        send(pid, {:loam_registry, :name_vacant, state.name, name})
        state

      {:ok, %{timer: tref}} when tref != nil ->
        # Already pending — preserve the original edge's schedule (rapid
        # vacant→owned→vacant churn does not extend or duplicate).
        state

      {:ok, %{debounce_ms: ms} = meta} ->
        tref = Process.send_after(self(), {:debounce_fire, ref}, ms)
        meta = Map.put(meta, :timer, tref)
        %{state | watcher_meta: Map.put(state.watcher_meta, ref, meta)}
    end
  end

  defp notify_owned(state, name) do
    case Map.fetch(state.watchers_by_name, name) do
      :error ->
        state

      {:ok, refs} ->
        Enum.reduce(refs, state, fn ref, st ->
          case Map.fetch(st.watcher_meta, ref) do
            {:ok, %{timer: tref} = meta} when tref != nil ->
              cancel_timer(tref)
              meta = Map.put(meta, :timer, nil)
              %{st | watcher_meta: Map.put(st.watcher_meta, ref, meta)}

            _ ->
              st
          end
        end)
    end
  end

  defp handle_debounce_fire(state, ref) do
    case Map.fetch(state.watcher_meta, ref) do
      {:ok, %{pid: pid, name: name, timer: tref} = meta} when tref != nil ->
        meta = Map.put(meta, :timer, nil)
        state = %{state | watcher_meta: Map.put(state.watcher_meta, ref, meta)}

        case Mirror.lookup(state.table, name) do
          [] -> send(pid, {:loam_registry, :name_vacant, state.name, name})
          _ -> :ok
        end

        state

      _ ->
        state
    end
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(tref) do
    _ = Process.cancel_timer(tref, async: true, info: false)
    :ok
  end

  defp synthesize_local_zid(name) do
    "local-" <>
      to_string(name) <> "-" <> Integer.to_string(:erlang.unique_integer([:positive]))
  end

  ## Timers + peer liveness

  defp schedule_heartbeat(state) when state.session_id == nil, do: :ok

  defp schedule_heartbeat(state) do
    Process.send_after(self(), :heartbeat_tick, state.heartbeat_interval_ms)
    :ok
  end

  defp schedule_peer_check(state) when state.session_id == nil, do: :ok

  defp schedule_peer_check(state) do
    interval = max(div(state.heartbeat_interval_ms, 2), 50)
    Process.send_after(self(), :peer_check_tick, interval)
    :ok
  end

  # Combine Zenoh's substrate-level peers_zid with our heartbeat freshness
  # check. A peer is alive iff it appears in peers_zid AND its last
  # heartbeat is within the configured liveness window. Drop everything
  # else: evict their owned entries from the mirror, forget the peer.
  defp check_peers(state) do
    zenoh_peers = current_peers_zid(state) |> MapSet.new()
    now = System.monotonic_time(:millisecond)
    window = state.heartbeat_interval_ms * state.heartbeat_misses

    {alive, dead} =
      Enum.split_with(state.peers, fn {zid, %{last_heartbeat_ms: last}} ->
        MapSet.member?(zenoh_peers, zid) and now - last <= window
      end)

    state =
      Enum.reduce(dead, state, fn {zid, _}, st ->
        evicted = Mirror.apply_eviction(st.table, zid)
        Enum.reduce(evicted, st, fn {name, _pid, _v, _l}, st2 -> notify_vacant(st2, name) end)
      end)

    %{state | peers: Map.new(alive)}
  end

  defp current_peers_zid(%{session_id: nil}), do: []

  defp current_peers_zid(state) do
    case Zenohex.Session.info(state.session_id) do
      {:ok, info} -> info.peers_zid || []
      _ -> []
    end
  end
end
