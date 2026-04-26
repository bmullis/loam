defmodule Loam.Registry.PropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduledoc """
  Cross-BEAM property test for `Loam.Registry` (PRD-0002 gate item 6).

  Generates sequences of `{:register, name, pid_idx, value}` and
  `{:unregister, name}` ops, randomly assigned to either the parent BEAM
  or the peer BEAM. After applying the full sequence on both sides, waits
  for convergence and asserts:

    * **Convergence.** Both BEAMs' mirrors agree on every name's
      `{pid, value}` after a settle window.
    * **Uniqueness.** At most one entry per name on each side. (Mirror's
      `:set` table guarantees this; we re-assert as a smoke check.)

  Partition + heal interleaving is the next slice — gate 4 demonstrates
  the LWW semantic in isolation; bringing it into the property generator
  needs `pfctl` (root) and is built on top of this scaffold.
  """

  @moduletag :integration
  @moduletag timeout: 240_000

  alias Loam.Registry.IntegrationHelper

  @peer_call_timeout 30_000
  @anchor_pool_size 4
  @name_pool ["n0", "n1", "n2", "n3"]
  @max_ops 12
  @settle_ms 1_500

  setup_all do
    cluster = :"loam_property_reg_#{:erlang.unique_integer([:positive])}"
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, parent_session} = start_local(cluster, parent_port, child_port)
    Process.unlink(parent_session)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    :ok =
      :peer.call(
        peer,
        IntegrationHelper,
        :start_registry_persistent,
        [cluster, child_port, parent_port],
        @peer_call_timeout
      )

    parent_pool = IntegrationHelper.spawn_anchor_pool(@anchor_pool_size)

    peer_pool =
      :peer.call(
        peer,
        IntegrationHelper,
        :spawn_anchor_pool,
        [@anchor_pool_size],
        @peer_call_timeout
      )

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end

      try do
        if Process.alive?(parent_session),
          do: GenServer.stop(parent_session, :normal, 5_000)
      catch
        _, _ -> :ok
      end
    end)

    {:ok, cluster: cluster, peer: peer, parent_pool: parent_pool, peer_pool: peer_pool}
  end

  property "post-quiescence convergence and uniqueness across the rig",
           %{
             cluster: cluster,
             peer: peer,
             parent_pool: parent_pool,
             peer_pool: peer_pool
           } do
    check all(plan <- plan_gen(), max_runs: 8) do
      reset(cluster, peer)

      {parent_ops, peer_ops} = split_plan(plan, parent_pool, peer_pool)

      # Apply on both sides. Peer call is sequential; parent ops happen
      # in this process. The order they interleave on the wire is the
      # property's whole point — convergence must hold regardless.
      task =
        Task.async(fn ->
          :peer.call(
            peer,
            IntegrationHelper,
            :apply_ops,
            [cluster, peer_ops],
            @peer_call_timeout
          )
        end)

      :ok = IntegrationHelper.apply_ops(cluster, parent_ops)
      :ok = Task.await(task, @peer_call_timeout)

      Process.sleep(@settle_ms)

      parent_snap = IntegrationHelper.snapshot(cluster)

      peer_snap =
        :peer.call(peer, IntegrationHelper, :snapshot, [cluster], @peer_call_timeout)

      # Convergence: both sides see the same mirror.
      assert parent_snap == peer_snap, """
      Sides did not converge.
        plan:  #{inspect(plan)}
        parent_ops: #{inspect(parent_ops)}
        peer_ops:   #{inspect(peer_ops)}
        parent_snap: #{inspect(parent_snap)}
        peer_snap:   #{inspect(peer_snap)}
      """

      # Uniqueness: at most one entry per name (the snapshot is a sorted
      # list with name as the first tuple element; check no consecutive
      # duplicates).
      names = Enum.map(parent_snap, &elem(&1, 0))
      assert names == Enum.uniq(names), "duplicate name in mirror: #{inspect(names)}"
    end
  end

  ## Generators

  defp register_gen do
    gen all(
          name <- member_of(@name_pool),
          pid_idx <- integer(0..(@anchor_pool_size - 1)),
          value <- one_of([constant(nil), binary(min_length: 1, max_length: 4)]),
          side <- member_of([:parent, :peer])
        ) do
      {side, {:register, name, pid_idx, value}}
    end
  end

  defp unregister_gen do
    gen all(name <- member_of(@name_pool), side <- member_of([:parent, :peer])) do
      {side, {:unregister, name}}
    end
  end

  defp plan_gen do
    list_of(one_of([register_gen(), unregister_gen()]), max_length: @max_ops)
  end

  defp split_plan(plan, parent_pool, peer_pool) do
    Enum.reduce(plan, {[], []}, fn
      {:parent, op}, {p, q} -> {p ++ [resolve(op, parent_pool)], q}
      {:peer, op}, {p, q} -> {p, q ++ [resolve(op, peer_pool)]}
    end)
  end

  defp resolve({:register, name, pid_idx, value}, pool) do
    {:register, name, Enum.at(pool, pid_idx), value}
  end

  defp resolve({:unregister, name}, _pool), do: {:unregister, name}

  ## Helpers

  defp reset(cluster, peer) do
    IntegrationHelper.reset_owned(cluster)

    :peer.call(peer, IntegrationHelper, :reset_owned, [cluster], @peer_call_timeout)

    Process.sleep(500)
  end

  defp start_local(cluster, listen_port, connect_port) do
    Loam.Registry.Session.start_link(
      name: cluster,
      heartbeat_interval_ms: 500,
      heartbeat_misses: 5,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: ["tcp/127.0.0.1:#{connect_port}"],
        multicast_scouting: false
      ]
    )
  end

  defp unique_port, do: 28_900 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
