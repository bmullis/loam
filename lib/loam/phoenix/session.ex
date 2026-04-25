defmodule Loam.Phoenix.Session do
  @moduledoc false

  # Owns the Zenohex.Session, declares the broad subscription, holds the
  # publisher reference, and dispatches received samples into the local
  # Phoenix.PubSub.

  use GenServer
  require Logger

  alias Loam.Phoenix.{Envelope, KeyExpr}

  @default_namespace "loam/phx"

  def start_link(opts) do
    adapter_name = Keyword.fetch!(opts, :adapter_name)
    GenServer.start_link(__MODULE__, opts, name: adapter_name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    pubsub_name = Keyword.fetch!(opts, :name)
    adapter_name = Keyword.fetch!(opts, :adapter_name)
    namespace = Keyword.get(opts, :namespace, @default_namespace)
    node_name_override = Keyword.get(opts, :node_name)
    zenoh_config = Keyword.get(opts, :zenoh, [])

    with {:ok, json5} <- build_zenoh_config(zenoh_config),
         {:ok, session_id} <- Zenohex.Session.open(json5),
         {:ok, info} <- Zenohex.Session.info(session_id),
         prefix = KeyExpr.prefix(namespace, pubsub_name),
         {:ok, sub_id} <-
           Zenohex.Session.declare_subscriber(session_id, "#{prefix}/**", self(),
             allowed_origin: :remote
           ),
         {:ok, pub_id} <-
           Zenohex.Session.declare_publisher(session_id, "#{prefix}/_") do
      node_name = node_name_override || info.zid

      :persistent_term.put(
        {__MODULE__, adapter_name},
        %{
          session_id: session_id,
          pubsub_name: pubsub_name,
          namespace: namespace,
          node_name: node_name
        }
      )

      state = %{
        adapter_name: adapter_name,
        pubsub_name: pubsub_name,
        namespace: namespace,
        node_name: node_name,
        session_id: session_id,
        sub_id: sub_id,
        pub_id: pub_id
      }

      {:ok, state}
    end
  end

  @impl true
  def handle_info(%Zenohex.Sample{} = sample, state) do
    with {:ok, {_pubsub_name, topic}} <- KeyExpr.decode(sample.key_expr),
         {:ok, {message, dispatcher}} <- Envelope.decode(sample.payload) do
      Phoenix.PubSub.local_broadcast(state.pubsub_name, topic, message, dispatcher)
    else
      {:error, reason} ->
        Logger.warning("loam: dropped malformed sample on #{sample.key_expr}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, state.adapter_name})
    Zenohex.Session.close(state.session_id)
    :ok
  end

  ## Public lookups for the Adapter behaviour callbacks

  @doc false
  def fetch!(adapter_name), do: :persistent_term.get({__MODULE__, adapter_name})

  @doc false
  def publish(adapter_name, topic, message, dispatcher) do
    %{session_id: session_id, namespace: ns, pubsub_name: name} = fetch!(adapter_name)
    key = KeyExpr.encode(ns, name, topic)
    payload = Envelope.encode({message, dispatcher})
    Zenohex.Session.put(session_id, key, payload)
  end

  ## Helpers

  defp build_zenoh_config(opts) do
    base = Zenohex.Config.default()

    Enum.reduce_while(opts, {:ok, base}, fn {key, value}, {:ok, acc} ->
      case Zenohex.Config.insert_json5(acc, json5_path(key), to_json5(value)) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, reason} -> {:halt, {:error, {:zenoh_config, key, reason}}}
      end
    end)
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
end
