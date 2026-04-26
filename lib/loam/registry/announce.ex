defmodule Loam.Registry.Announce do
  @moduledoc """
  Encode/decode of `Loam.Registry` wire payloads, wrapped in
  `Loam.Phoenix.Envelope`.

  Five tagged payloads:

    * `{:register, name, pid, value, lamport, zid}` — name claim
    * `{:unregister, name, lamport, zid}` — release
    * `{:heartbeat, zid, lamport}` — liveness ping
    * `{:snapshot_request, zid}` — late-joiner asking for owned-entries replay
    * `{:snapshot, zid, entries}` where `entries :: [{name, pid, value, lamport}]`

  `name` and `value` are arbitrary Erlang terms. `lamport` is a non-negative
  integer. `zid` is a binary (Zenoh peer identifier).

  This module is pure: encode/decode only. Routing, mirroring, and clock
  bookkeeping live elsewhere.
  """

  alias Loam.Phoenix.Envelope

  @magic "LOAM"
  @version 1

  @type zid :: binary()
  @type lamport :: non_neg_integer()
  @type name :: term()
  @type value :: term()

  @type entry :: {name(), pid(), value(), lamport()}

  @type payload ::
          {:register, name(), pid(), value(), lamport(), zid()}
          | {:unregister, name(), lamport(), zid()}
          | {:heartbeat, zid(), lamport()}
          | {:snapshot_request, zid()}
          | {:snapshot, zid(), [entry()]}

  @type decode_error ::
          :bad_magic
          | {:bad_version, byte()}
          | :unsafe_term
          | :truncated
          | {:unknown_tag, term()}
          | :malformed

  @spec encode(payload()) :: binary()
  def encode(payload) do
    payload
    |> validate!()
    |> Envelope.encode()
  end

  # Unsafe (non-`[:safe]`) ETF decode is intentional. Registry payloads
  # carry user-defined atoms (in `name` and `value`) and pid terms (which
  # embed the originating node atom). Both are precluded by `:safe`. We
  # accept the atom-table risk because the substrate has no auth: anyone
  # who can publish to our keyexpr can already DoS us. See the decision
  # journal entry on this.
  @spec decode(binary()) :: {:ok, payload()} | {:error, decode_error()}
  def decode(<<@magic, @version, rest::binary>>) when byte_size(rest) > 0 do
    try do
      validate(:erlang.binary_to_term(rest))
    rescue
      ArgumentError -> {:error, :unsafe_term}
    end
  end

  def decode(<<@magic, @version>>), do: {:error, :truncated}
  def decode(<<@magic, version, _::binary>>), do: {:error, {:bad_version, version}}
  def decode(_), do: {:error, :bad_magic}

  defp validate({:register, _name, pid, _value, lamport, zid} = p)
       when is_pid(pid) and is_integer(lamport) and lamport >= 0 and is_binary(zid),
       do: {:ok, p}

  defp validate({:unregister, _name, lamport, zid} = p)
       when is_integer(lamport) and lamport >= 0 and is_binary(zid),
       do: {:ok, p}

  defp validate({:heartbeat, zid, lamport} = p)
       when is_binary(zid) and is_integer(lamport) and lamport >= 0,
       do: {:ok, p}

  defp validate({:snapshot_request, zid} = p) when is_binary(zid), do: {:ok, p}

  defp validate({:snapshot, zid, entries} = p) when is_binary(zid) and is_list(entries) do
    if Enum.all?(entries, &valid_entry?/1), do: {:ok, p}, else: {:error, :malformed}
  end

  defp validate(t) when is_tuple(t) and tuple_size(t) > 0 do
    case elem(t, 0) do
      tag
      when tag in [:register, :unregister, :heartbeat, :snapshot_request, :snapshot] ->
        {:error, :malformed}

      tag ->
        {:error, {:unknown_tag, tag}}
    end
  end

  defp validate(_), do: {:error, :malformed}

  defp valid_entry?({_name, pid, _value, lamport})
       when is_pid(pid) and is_integer(lamport) and lamport >= 0,
       do: true

  defp valid_entry?(_), do: false

  defp validate!(payload) do
    case validate(payload) do
      {:ok, p} -> p
      {:error, reason} -> raise ArgumentError, "invalid Announce payload: #{inspect(reason)}"
    end
  end
end
