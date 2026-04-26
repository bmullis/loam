defmodule Loam.Registry.Mirror do
  @moduledoc """
  Local ETS-backed view of the cluster's `Loam.Registry` registrations.

  One entry per name; conflict resolution is Last-Writer-Wins by
  `(lamport, zid)` lexicographic order. The table is a `:set` keyed by name,
  with values `{pid, value, lamport, zid}`.

  This module is the deterministic core of the Registry: every mutator is a
  pure function of the table state and the incoming announce. The owning
  `Loam.Registry.Session` translates wire announces into calls here.

  All mutators are idempotent: applying the same announce twice produces the
  same result and the same return tag (`:duplicate`).
  """

  @type table :: :ets.tid() | atom()
  @type name :: term()
  @type value :: term()
  @type lamport :: non_neg_integer()
  @type zid :: binary()

  @type entry :: {pid(), value(), lamport(), zid()}

  @type apply_register_result ::
          {:applied, :new}
          | {:applied, {:evicted, pid(), zid()}}
          | :rejected
          | :duplicate

  @type apply_unregister_result :: :applied | :rejected | :duplicate

  @doc """
  Create a new mirror table. Pass an atom for a named table or `nil` for an
  anonymous one. Returns the table id.
  """
  @spec new(atom() | nil) :: table()
  def new(name \\ nil) do
    base_opts = [:set, :public, read_concurrency: true, write_concurrency: true]

    case name do
      nil -> :ets.new(:loam_registry_mirror, base_opts)
      atom when is_atom(atom) -> :ets.new(atom, [:named_table | base_opts])
    end
  end

  @doc """
  Apply an incoming `:register` announce.

  LWW: incoming wins iff `(lamport, zid)` strictly greater than the stored
  entry's. Equal `(lamport, zid)` is treated as `:duplicate` (idempotent
  re-delivery).
  """
  @spec apply_register(table(), name(), pid(), value(), lamport(), zid()) ::
          apply_register_result()
  def apply_register(table, name, pid, value, lamport, zid)
      when is_pid(pid) and is_integer(lamport) and lamport >= 0 and is_binary(zid) do
    case :ets.lookup(table, name) do
      [] ->
        :ets.insert(table, {name, {pid, value, lamport, zid}})
        {:applied, :new}

      [{^name, {prev_pid, _prev_value, prev_lamport, prev_zid}}] ->
        cond do
          newer?(lamport, zid, prev_lamport, prev_zid) ->
            :ets.insert(table, {name, {pid, value, lamport, zid}})
            {:applied, {:evicted, prev_pid, prev_zid}}

          lamport == prev_lamport and zid == prev_zid ->
            :duplicate

          true ->
            :rejected
        end
    end
  end

  @doc """
  Apply an incoming `:unregister` announce.

  Only deletes if the current entry is owned by the same `zid` AND the
  unregister's `(lamport, zid)` is strictly newer than the stored entry's.
  Cross-ZID unregisters and stale (older) unregisters are rejected.
  """
  @spec apply_unregister(table(), name(), lamport(), zid()) :: apply_unregister_result()
  def apply_unregister(table, name, lamport, zid)
      when is_integer(lamport) and lamport >= 0 and is_binary(zid) do
    case :ets.lookup(table, name) do
      [] ->
        :duplicate

      [{^name, {_pid, _value, prev_lamport, prev_zid}}] ->
        cond do
          prev_zid != zid ->
            :rejected

          newer?(lamport, zid, prev_lamport, prev_zid) ->
            :ets.delete(table, name)
            :applied

          true ->
            :rejected
        end
    end
  end

  @doc """
  Evict every entry owned by `zid` (peer-loss path). Returns the list of
  evicted entries so the caller can notify monitored pids.
  """
  @spec apply_eviction(table(), zid()) :: [{name(), pid(), value(), lamport()}]
  def apply_eviction(table, zid) when is_binary(zid) do
    matches =
      :ets.match_object(table, {:_, {:_, :_, :_, zid}})

    Enum.map(matches, fn {name, {pid, value, lamport, ^zid}} ->
      :ets.delete(table, name)
      {name, pid, value, lamport}
    end)
  end

  @spec lookup(table(), name()) :: [{pid(), value()}]
  def lookup(table, name) do
    case :ets.lookup(table, name) do
      [] -> []
      [{^name, {pid, value, _lamport, _zid}}] -> [{pid, value}]
    end
  end

  @spec keys_for_pid(table(), pid()) :: [name()]
  def keys_for_pid(table, pid) when is_pid(pid) do
    :ets.match_object(table, {:_, {pid, :_, :_, :_}})
    |> Enum.map(fn {name, _} -> name end)
  end

  @spec count(table()) :: non_neg_integer()
  def count(table), do: :ets.info(table, :size)

  @spec entries_owned_by(table(), zid()) :: [{name(), pid(), value(), lamport()}]
  def entries_owned_by(table, zid) when is_binary(zid) do
    :ets.match_object(table, {:_, {:_, :_, :_, zid}})
    |> Enum.map(fn {name, {pid, value, lamport, ^zid}} -> {name, pid, value, lamport} end)
  end

  @compile {:inline, newer?: 4}
  defp newer?(la, za, lb, zb) do
    la > lb or (la == lb and za > zb)
  end
end
