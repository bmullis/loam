defmodule Loam.Phoenix.Envelope do
  @moduledoc """
  Wire format for cross-node `Phoenix.PubSub` payloads carried over Zenoh.

  An envelope is `<<"LOAM", version, term_to_binary(payload)::binary>>`. The
  prefix lets us drop foreign or future-version traffic on the adapter's
  keyexpr namespace without crashing the decoder. The payload is decoded with
  `[:safe]` since both ends are BEAMs we control.
  """

  @magic "LOAM"
  @version 1

  @spec encode(term()) :: binary()
  def encode(term) do
    @magic <> <<@version>> <> :erlang.term_to_binary(term)
  end

  @spec decode(binary()) ::
          {:ok, term()}
          | {:error, :bad_magic | {:bad_version, byte()} | :unsafe_term | :truncated}
  def decode(<<@magic, @version, rest::binary>>) when byte_size(rest) > 0 do
    try do
      {:ok, :erlang.binary_to_term(rest, [:safe])}
    rescue
      ArgumentError -> {:error, :unsafe_term}
    end
  end

  def decode(<<@magic, @version>>), do: {:error, :truncated}
  def decode(<<@magic, version, _::binary>>), do: {:error, {:bad_version, version}}
  def decode(_), do: {:error, :bad_magic}
end
