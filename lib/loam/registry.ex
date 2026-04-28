defmodule Loam.Registry do
  @moduledoc """
  Distributed unique-name registry built on Zenoh.

  This module is the public surface. State is held by `Loam.Registry.Session`
  (one process per registry instance, named by the `:name` option). The mirror
  table that backs `lookup/2`, `keys/2`, and `count/1` is a `:set` ETS table
  owned by that process and read directly from any caller.

  ## Semantic summary

    * Unique-name registration only.
    * `lookup/2` is an ETS read of the local mirror — no network round-trip,
      eventually consistent during partition.
    * Cross-BEAM conflicts are resolved Last-Writer-Wins by `(lamport, zid)`.
      The losing pid receives `{:loam_registry, :evicted, name, winner_zid}`.
    * Names are arbitrary Erlang terms; `value` is any term and rides the
      wire alongside the registration.
    * `monitor/3` subscribes the calling pid to owned→vacant transitions on
      a name. The watcher receives
      `{:loam_registry, :name_vacant, registry, name}` on every transition
      observed by the local mirror — local unregister, remote unregister,
      peer-loss eviction, or LWW eviction of the last claimant. See PRD-0003
      and `docs/journal/2026-04-27-registry-monitor-as-deep-module-decision.md`.

  See `docs/prds/0002-registry-on-zenoh.md` for the full semantic.
  """

  alias Loam.Registry.{Mirror, Session}

  @type registry :: atom() | pid()
  @type name :: term()
  @type monitor_ref :: reference()

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Session.child_spec(opts)

  @spec register(registry(), name(), pid() | term()) ::
          :ok
          | {:error, {:already_registered, pid()} | :remote_pid | :no_such_registry}
  def register(registry, name, pid_or_value) do
    if is_pid(pid_or_value) do
      do_register(registry, name, pid_or_value, nil)
    else
      do_register(registry, name, self(), pid_or_value)
    end
  end

  @spec register(registry(), name(), pid(), term()) ::
          :ok
          | {:error, {:already_registered, pid()} | :remote_pid | :no_such_registry}
  def register(registry, name, pid, value) when is_pid(pid) do
    do_register(registry, name, pid, value)
  end

  @spec unregister(registry(), name()) ::
          :ok | {:error, :not_owner | :no_such_registry}
  def unregister(registry, name) do
    case resolve(registry) do
      {:ok, server} -> Session.unregister(server, name)
      :error -> {:error, :no_such_registry}
    end
  end

  @spec lookup(registry(), name()) :: [{pid(), term()}]
  def lookup(registry, name) do
    case resolve_table(registry) do
      {:ok, table} -> Mirror.lookup(table, name)
      :error -> []
    end
  end

  @spec keys(registry(), pid()) :: [name()]
  def keys(registry, pid) when is_pid(pid) do
    case resolve_table(registry) do
      {:ok, table} -> Mirror.keys_for_pid(table, pid)
      :error -> []
    end
  end

  @spec count(registry()) :: non_neg_integer()
  def count(registry) do
    case resolve_table(registry) do
      {:ok, table} -> Mirror.count(table)
      :error -> 0
    end
  end

  @doc """
  Subscribe the calling pid to owned→vacant transitions on `name`.

  Returns `{:ok, ref}`. The watcher pid receives
  `{:loam_registry, :name_vacant, registry, name}` on every owned→vacant
  transition observed by the local mirror — local unregister, remote
  unregister, peer-loss eviction, or LWW eviction of the last claimant.

  Options:

    * `:debounce_ms` (default `0`) — added in slice 0002. The PRD-0003
      vacancy debounce window. `0` means fire immediately.

  The watcher entry is removed automatically when the watcher pid dies.
  Notifications are not delivered for transitions that occurred before the
  monitor was installed.
  """
  @spec monitor(registry(), name(), keyword()) ::
          {:ok, monitor_ref()} | {:error, :no_such_registry}
  def monitor(registry, name, opts \\ []) do
    case resolve(registry) do
      {:ok, server} -> Session.monitor(server, name, self(), opts)
      :error -> {:error, :no_such_registry}
    end
  end

  @doc """
  Stop watching `name`. Idempotent on unknown refs.
  """
  @spec demonitor(registry(), monitor_ref()) :: :ok
  def demonitor(registry, ref) when is_reference(ref) do
    case resolve(registry) do
      {:ok, server} -> Session.demonitor(server, ref)
      :error -> :ok
    end
  end

  ## Internals

  defp do_register(registry, name, pid, value) do
    case resolve(registry) do
      {:ok, server} -> Session.register(server, name, pid, value)
      :error -> {:error, :no_such_registry}
    end
  end

  defp resolve(registry) when is_pid(registry) do
    if Process.alive?(registry), do: {:ok, registry}, else: :error
  end

  defp resolve(registry) when is_atom(registry) do
    case Process.whereis(registry) do
      nil -> :error
      pid -> {:ok, pid}
    end
  end

  defp resolve_table(registry) do
    with {:ok, server} <- resolve(registry) do
      {:ok, Session.table(server)}
    end
  end
end
