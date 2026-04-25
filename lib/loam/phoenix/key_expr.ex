defmodule Loam.Phoenix.KeyExpr do
  @moduledoc """
  Topic ⇄ Zenoh key-expression translation for the `Phoenix.PubSub` adapter.

  A Phoenix topic is an opaque binary. We URL-safe-base64 it (no padding) into
  a single keyexpr chunk under a per-pubsub-instance namespace:

      <namespace>/<pubsub_name>/<urlsafe-base64-of-topic>

  Opaque encoding because Phoenix topics may contain any bytes — including
  characters that are not legal in a Zenoh keyexpr chunk (`/`, `*`, `$`, `?`,
  `#`). Inspecting the topic content would leak an assumption that breaks for
  some user. The price is debug readability; pay it with `decode/1`.
  """

  @spec encode(String.t(), atom() | String.t(), binary()) :: String.t()
  def encode(namespace, pubsub_name, topic)
      when is_binary(namespace) and is_binary(topic) do
    "#{prefix(namespace, pubsub_name)}/#{Base.url_encode64(topic, padding: false)}"
  end

  @doc """
  Returns the keyexpr prefix for a pubsub instance, without a topic segment.

  Used to declare the broad `<prefix>/**` subscription that catches every
  topic published to this pubsub instance.
  """
  @spec prefix(String.t(), atom() | String.t()) :: String.t()
  def prefix(namespace, pubsub_name) when is_binary(namespace) do
    pubsub_segment = pubsub_name |> to_string() |> Base.url_encode64(padding: false)
    "#{namespace}/#{pubsub_segment}"
  end

  @spec decode(String.t()) ::
          {:ok, {pubsub_name :: String.t(), topic :: binary()}}
          | {:error, :bad_shape | :bad_pubsub_name | :bad_topic}
  def decode(key_expr) when is_binary(key_expr) do
    case String.split(key_expr, "/") do
      parts when length(parts) >= 3 ->
        [encoded_topic, encoded_pubsub | _namespace_rev] = Enum.reverse(parts)

        with {:ok, pubsub_name} <- url_decode(encoded_pubsub, :bad_pubsub_name),
             {:ok, topic} <- url_decode(encoded_topic, :bad_topic) do
          {:ok, {pubsub_name, topic}}
        end

      _ ->
        {:error, :bad_shape}
    end
  end

  defp url_decode(segment, error_tag) do
    case Base.url_decode64(segment, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, error_tag}
    end
  end
end
