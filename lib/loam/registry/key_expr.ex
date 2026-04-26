defmodule Loam.Registry.KeyExpr do
  @moduledoc """
  Keyexpr layout for `Loam.Registry`.

      <namespace>/<registry_name>/announces

  All Registry traffic — register, unregister, heartbeat, snapshot_request,
  snapshot — publishes through a single key per cluster. The payload (a
  `Loam.Registry.Announce` tagged tuple) carries the operation kind; the
  receiver dispatches on the tag.

  ## Why one key per cluster

  Per-name keyexprs would let external Zenoh subscribers filter by name,
  but PRD-0002 explicitly defers per-name external subscription. The
  practical cost of per-name keys is real: each new name declares a new
  Zenoh publisher, and on real networks the publisher's matching status
  takes nontrivial wall-clock time to propagate. With
  `congestion_control: :drop` (which the PRD wants for partition-tolerance),
  the first `put` on a fresh publisher silently drops if matching hasn't
  reached the publisher's cache yet. Loopback testing didn't surface this
  because matching propagation is sub-millisecond locally; real Wi-Fi made
  it fatal — see `docs/journal/2026-04-26-registry-mac-pi-real-hardware-run.md`
  and the decision entry on this collapse.

  One publisher per Session, declared at init, warmed by the first
  heartbeat tick, then reused for every subsequent publish: no per-name
  discovery race, no first-put loss.
  """

  @type namespace :: String.t()

  @spec prefix(namespace(), atom() | String.t()) :: String.t()
  def prefix(namespace, registry_name) when is_binary(namespace) do
    seg = registry_name |> to_string() |> Base.url_encode64(padding: false)
    "#{namespace}/#{seg}"
  end

  @spec announce_key(namespace(), atom() | String.t()) :: String.t()
  def announce_key(namespace, registry_name) do
    "#{prefix(namespace, registry_name)}/announces"
  end

  @doc """
  Classify an inbound key_expr. Returns `:announce` for the single
  announces key, `:ignore` for anything else.
  """
  @spec classify(String.t()) :: :announce | :ignore
  def classify(key_expr) when is_binary(key_expr) do
    case String.split(key_expr, "/") |> Enum.reverse() do
      ["announces" | _] -> :announce
      _ -> :ignore
    end
  end
end
