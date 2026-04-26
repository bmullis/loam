defmodule Loam.Phoenix.IntegrationHelper do
  @moduledoc false

  # Functions invoked on a peer BEAM via :peer.call. Lives under test/support/
  # so it's compiled to disk (standard test modules are compiled in-memory and
  # aren't visible to peer nodes).

  @doc """
  Start a pubsub, sleep for handshake, broadcast a list of `{topic, message}`
  pairs, then sleep briefly to let Zenoh flush before returning. Used for the
  peer-broadcasts-to-parent direction.
  """
  def broadcast_remote(pubsub_name, listen_port, connect_port, broadcasts)
      when is_list(broadcasts) do
    start_pubsub(pubsub_name, listen_port, connect_port)
    Process.sleep(1500)

    Enum.each(broadcasts, fn {topic, message} ->
      :ok = Phoenix.PubSub.broadcast(pubsub_name, topic, message)
    end)

    Process.sleep(500)
    :ok
  end

  @doc """
  Like `broadcast_remote/4` but assumes the pubsub is already running. No
  startup, no handshake sleep. Used by long-lived peers that handle multiple
  broadcast batches across iterations (e.g. property tests).
  """
  def broadcast_only(pubsub_name, broadcasts) when is_list(broadcasts) do
    Enum.each(broadcasts, fn {topic, message} ->
      :ok = Phoenix.PubSub.broadcast(pubsub_name, topic, message)
    end)

    :ok
  end

  @doc """
  Start a pubsub on the peer node and detach it from the calling :peer.call
  process so it survives across multiple :peer.calls. Sleeps for handshake.
  """
  def start_pubsub_persistent(pubsub_name, listen_port, connect_port) do
    Application.ensure_all_started(:phoenix_pubsub)
    Application.ensure_all_started(:zenohex)

    {:ok, sup} =
      Phoenix.PubSub.Supervisor.start_link(
        name: pubsub_name,
        adapter: Loam.Phoenix.Adapter,
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{listen_port}"],
          connect: ["tcp/127.0.0.1:#{connect_port}"],
          multicast_scouting: false
        ]
      )

    Process.unlink(sup)
    Process.sleep(1_500)
    :ok
  end

  @doc """
  Start a pubsub, subscribe to a topic, sleep for handshake, then collect up
  to `count` messages or stop on `timeout_ms`. Used for the parent-broadcasts-
  to-peer direction. Returns the list of messages received in arrival order.
  """
  def collect_remote(pubsub_name, listen_port, connect_port, topic, count, timeout_ms) do
    start_pubsub(pubsub_name, listen_port, connect_port)
    :ok = Phoenix.PubSub.subscribe(pubsub_name, topic)
    Process.sleep(1500)
    collect(count, timeout_ms, [])
  end

  defp start_pubsub(pubsub_name, listen_port, connect_port) do
    Application.ensure_all_started(:phoenix_pubsub)
    Application.ensure_all_started(:zenohex)

    {:ok, _sup} =
      Phoenix.PubSub.Supervisor.start_link(
        name: pubsub_name,
        adapter: Loam.Phoenix.Adapter,
        zenoh: [
          mode: :peer,
          listen: ["tcp/127.0.0.1:#{listen_port}"],
          connect: ["tcp/127.0.0.1:#{connect_port}"],
          multicast_scouting: false
        ]
      )

    :ok
  end

  defp collect(0, _timeout, acc), do: Enum.reverse(acc)

  defp collect(remaining, timeout, acc) do
    receive do
      msg -> collect(remaining - 1, timeout, [msg | acc])
    after
      timeout -> Enum.reverse(acc)
    end
  end
end
