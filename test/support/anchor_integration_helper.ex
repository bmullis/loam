defmodule Loam.Anchor.IntegrationHelper do
  @moduledoc false

  # Functions invoked on a peer BEAM via :peer.call. Mirrors the shape of
  # Loam.Registry.IntegrationHelper. Lives under test/support/ so the
  # module is compiled to disk and visible on the peer's code path.

  alias Loam.Anchor
  alias Loam.Registry
  alias Loam.Registry.Session

  @doc """
  Start a Registry Session and a single Loam.Anchor on this peer; return
  the anchor's pid. The pid is unlinked so it survives :peer.call exit.
  """
  def start_anchor_remote(cluster, listen_port, connect_port, anchor_name, opts \\ []) do
    Application.ensure_all_started(:zenohex)
    Application.ensure_all_started(:telemetry)

    {:ok, sess} =
      Session.start_link(
        name: cluster,
        heartbeat_interval_ms: Keyword.get(opts, :heartbeat_interval_ms, 1_000),
        heartbeat_misses: Keyword.get(opts, :heartbeat_misses, 3),
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{listen_port}"],
          connect: ["tcp/127.0.0.1:#{connect_port}"],
          multicast_scouting: false
        ]
      )

    Process.unlink(sess)
    Process.sleep(Keyword.get(opts, :handshake_ms, 1_500))

    {:ok, anchor} =
      Anchor.start_link(
        registry: cluster,
        name: anchor_name,
        child_spec: {Loam.Test.AnchorWorker, []},
        start_jitter_ms: Keyword.get(opts, :start_jitter_ms, 100),
        vacancy_debounce_ms: Keyword.get(opts, :vacancy_debounce_ms, 200)
      )

    Process.unlink(anchor)
    {:ok, anchor}
  end

  @doc "Look up the anchor's name on this peer's registry."
  def lookup_remote(cluster, name), do: Registry.lookup(cluster, name)

  @doc """
  Wait until `lookup_remote(cluster, name)` returns a single entry whose
  pid matches `expected_pid` (or any single entry if `expected_pid` is
  `:any`), or `timeout_ms` elapses. Returns the final lookup result.
  """
  def wait_lookup(cluster, name, expected_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_lookup(cluster, name, expected_pid, deadline)
  end

  defp do_wait_lookup(cluster, name, expected_pid, deadline) do
    case Registry.lookup(cluster, name) do
      [{pid, _}] when expected_pid == :any or pid == expected_pid ->
        Registry.lookup(cluster, name)

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          Registry.lookup(cluster, name)
        else
          Process.sleep(50)
          do_wait_lookup(cluster, name, expected_pid, deadline)
        end
    end
  end

  @doc """
  Anchor server state inspection (status, local_sup presence, child_pid).
  Used to assert that a peer is in :standby vs :owner.
  """
  def anchor_state(anchor_pid) do
    state = :sys.get_state(anchor_pid)

    %{
      status: state.status,
      local_sup_running?: is_pid(state.local_sup) and Process.alive?(state.local_sup),
      child_pid: state.child_pid
    }
  end
end
