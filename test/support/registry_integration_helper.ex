defmodule Loam.Registry.IntegrationHelper do
  @moduledoc false

  # Functions invoked on a peer BEAM via :peer.call. Mirrors the shape of
  # Loam.Phoenix.IntegrationHelper. Lives under test/support/ so the module
  # is compiled to disk and visible on the peer's code path.
  #
  # The "anchor" helpers spawn a long-lived pid on the peer and register it.
  # Without this, a pid registered inside a :peer.call returning value would
  # die as the call exits, immediately removing the entry.

  alias Loam.Registry
  alias Loam.Registry.Session

  @doc """
  Start a `Loam.Registry.Session` with persistent process registration.
  Sleeps for the Zenoh handshake before returning.
  """
  def start_registry_persistent(cluster, listen_port, connect_port, opts \\ []) do
    Application.ensure_all_started(:zenohex)

    {:ok, sup} =
      Session.start_link(
        name: cluster,
        heartbeat_interval_ms: Keyword.get(opts, :heartbeat_interval_ms, 1_000),
        heartbeat_misses: Keyword.get(opts, :heartbeat_misses, 3),
        zenoh:
          [
            mode: :peer,
            listen: ["tcp/127.0.0.1:#{listen_port}"],
            connect: ["tcp/127.0.0.1:#{connect_port}"],
            multicast_scouting: false
          ] ++ Keyword.get(opts, :zenoh_extra, [])
      )

    Process.unlink(sup)
    Process.sleep(Keyword.get(opts, :handshake_ms, 1_500))
    :ok
  end

  @doc """
  Spawn a long-lived idle pid on this BEAM, register it under `name` with
  `value`, and return the pid (so the caller can match against it later).
  """
  def register_anchor(cluster, name, value) do
    pid = spawn(fn -> :timer.sleep(:infinity) end)
    :ok = Registry.register(cluster, name, pid, value)
    pid
  end

  @doc "Unregister a name from this peer's registry."
  def unregister_remote(cluster, name), do: Registry.unregister(cluster, name)

  @doc "Lookup a name in this peer's local mirror."
  def lookup_remote(cluster, name), do: Registry.lookup(cluster, name)

  @doc "Count entries in this peer's local mirror."
  def count_remote(cluster), do: Registry.count(cluster)

  @doc """
  Wait until `lookup_remote(cluster, name)` matches `expected` or
  `timeout_ms` elapses. Returns the final lookup result.
  """
  def wait_lookup(cluster, name, expected, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_lookup(cluster, name, expected, deadline)
  end

  defp poll_lookup(cluster, name, expected, deadline) do
    actual = Registry.lookup(cluster, name)

    cond do
      actual == expected ->
        actual

      System.monotonic_time(:millisecond) > deadline ->
        actual

      true ->
        Process.sleep(50)
        poll_lookup(cluster, name, expected, deadline)
    end
  end

  @doc """
  Spawn `count` long-lived idle pids on this BEAM. Returns the list. Used
  by the property test to keep an anchor pool alive across iterations.
  """
  def spawn_anchor_pool(count) do
    for _ <- 1..count, do: spawn(fn -> :timer.sleep(:infinity) end)
  end

  @doc """
  Apply a list of registry operations sequentially on this BEAM, where each
  op is one of:

    * `{:register, name, pid, value}`
    * `{:unregister, name}`

  Returns `:ok`. Errors from the underlying registry call are ignored — the
  property test asserts the *post-quiescence* mirror state, not the
  per-call return values.
  """
  def apply_ops(cluster, ops) do
    Enum.each(ops, fn
      {:register, name, pid, value} -> Registry.register(cluster, name, pid, value)
      {:unregister, name} -> Registry.unregister(cluster, name)
    end)

    :ok
  end

  @doc """
  Reset all entries owned by this peer on the given cluster: unregister
  every name in the local mirror that this Session owns. Used between
  property-test iterations to start each iteration from a clean slate
  without restarting the Session.
  """
  def reset_owned(cluster) do
    pid = Process.whereis(cluster)

    if pid do
      state = :sys.get_state(pid)
      table = state.table
      zid = state.zid

      table
      |> Loam.Registry.Mirror.entries_owned_by(zid)
      |> Enum.each(fn {name, _, _, _} -> Registry.unregister(cluster, name) end)
    end

    :ok
  end

  @doc """
  Snapshot the entire local mirror as a sorted list of `{name, pid, value}`
  tuples. Used to compare convergence across two BEAMs.
  """
  def snapshot(cluster) do
    pid = Process.whereis(cluster)

    if pid do
      table = :sys.get_state(pid).table

      :ets.tab2list(table)
      |> Enum.map(fn {name, {p, v, _l, _z}} -> {name, p, v} end)
      |> Enum.sort()
    else
      []
    end
  end

  @doc """
  Mailbox lengths for a list of pids. Returns `[non_neg_integer]` aligned
  with the input order.
  """
  def mailbox_lengths(pids) do
    Enum.map(pids, fn pid ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} -> n
        nil -> 0
      end
    end)
  end

  @doc """
  Read peers_zid from this peer's Session. Used by partition / peer-death
  tests to wait for substrate-level peer state changes.
  """
  def peers_zid(cluster) do
    pid = Process.whereis(cluster)

    if pid do
      sid = :sys.get_state(pid).session_id
      if sid, do: elem(Zenohex.Session.info(sid), 1).peers_zid, else: []
    else
      []
    end
  end
end
