defmodule Loam.Registry.MonitorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loam.Registry

  defp start_registry(ctx) do
    name = Module.concat(__MODULE__, "Reg#{System.unique_integer([:positive])}")
    start_supervised!({Loam.Registry.Session, name: name})
    Map.put(ctx, :registry, name)
  end

  defp spawn_idle do
    spawn(fn -> :timer.sleep(:infinity) end)
  end

  # Quiesce: any pending messages we sent the Session have been processed.
  defp drain(registry), do: _ = :sys.get_state(registry)

  describe "monitor/3 + demonitor/2 surface" do
    test "monitor on an unstarted registry returns :no_such_registry" do
      assert {:error, :no_such_registry} = Registry.monitor(:nope, :anything)
    end

    test "demonitor on an unstarted registry is :ok" do
      assert :ok = Registry.demonitor(:nope, make_ref())
    end

    setup :start_registry

    test "monitor returns {:ok, ref}", %{registry: r} do
      assert {:ok, ref} = Registry.monitor(r, :a)
      assert is_reference(ref)
    end

    test "demonitor on unknown ref is :ok (idempotent)", %{registry: r} do
      assert :ok = Registry.demonitor(r, make_ref())
    end

    test "demonitor of a real ref is :ok", %{registry: r} do
      {:ok, ref} = Registry.monitor(r, :a)
      assert :ok = Registry.demonitor(r, ref)
      # idempotent
      assert :ok = Registry.demonitor(r, ref)
    end
  end

  describe "fires :name_vacant on owned→vacant edges" do
    setup :start_registry

    test "local unregister fires", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, _ref} = Registry.monitor(r, :a)
      :ok = Registry.unregister(r, :a)
      assert_receive {:loam_registry, :name_vacant, ^r, :a}
    end

    test "registered pid exits → unregister fires :name_vacant", %{registry: r} do
      pid = spawn_idle()
      :ok = Registry.register(r, :a, pid, nil)
      {:ok, _ref} = Registry.monitor(r, :a)

      Process.exit(pid, :kill)
      drain(r)
      assert_receive {:loam_registry, :name_vacant, ^r, :a}
    end

    test "multiple watchers all receive the notification", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      parent = self()
      ref1 = make_ref()
      ref2 = make_ref()

      w1 =
        spawn_link(fn ->
          {:ok, _} = Registry.monitor(r, :a)
          send(parent, {:ready, ref1})
          receive do
            msg -> send(parent, {:got, ref1, msg})
          end
        end)

      w2 =
        spawn_link(fn ->
          {:ok, _} = Registry.monitor(r, :a)
          send(parent, {:ready, ref2})
          receive do
            msg -> send(parent, {:got, ref2, msg})
          end
        end)

      assert_receive {:ready, ^ref1}
      assert_receive {:ready, ^ref2}
      :ok = Registry.unregister(r, :a)

      assert_receive {:got, ^ref1, {:loam_registry, :name_vacant, ^r, :a}}
      assert_receive {:got, ^ref2, {:loam_registry, :name_vacant, ^r, :a}}

      _ = w1
      _ = w2
    end
  end

  describe "does not fire on non-vacancy edges" do
    setup :start_registry

    test "registering when no entry exists (vacant→owned) does not fire", %{registry: r} do
      {:ok, _ref} = Registry.monitor(r, :a)
      :ok = Registry.register(r, :a, self())
      drain(r)
      refute_received {:loam_registry, :name_vacant, _, :a}
    end

    test "monitor installed on already-owned name does not fire spuriously", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, _ref} = Registry.monitor(r, :a)
      drain(r)
      refute_received {:loam_registry, :name_vacant, _, :a}
    end

    test "monitor installed on vacant name does not fire", %{registry: r} do
      {:ok, _ref} = Registry.monitor(r, :a)
      drain(r)
      refute_received {:loam_registry, :name_vacant, _, :a}
    end

    test "unregister of an unknown name does not fire", %{registry: r} do
      {:ok, _ref} = Registry.monitor(r, :a)
      :ok = Registry.unregister(r, :a)
      drain(r)
      refute_received {:loam_registry, :name_vacant, _, :a}
    end

    test "watcher only sees vacancy on its own name, not others", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      :ok = Registry.register(r, :b, self())
      {:ok, _ref} = Registry.monitor(r, :a)

      :ok = Registry.unregister(r, :b)
      drain(r)
      refute_received {:loam_registry, :name_vacant, _, _}

      :ok = Registry.unregister(r, :a)
      assert_receive {:loam_registry, :name_vacant, ^r, :a}
    end
  end

  describe "demonitor stops notifications" do
    setup :start_registry

    test "demonitored watcher gets no notification", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, ref} = Registry.monitor(r, :a)
      :ok = Registry.demonitor(r, ref)
      :ok = Registry.unregister(r, :a)
      drain(r)
      refute_received {:loam_registry, :name_vacant, _, :a}
    end

    test "demonitoring one ref leaves the other firing", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, ref1} = Registry.monitor(r, :a)
      {:ok, _ref2} = Registry.monitor(r, :a)
      :ok = Registry.demonitor(r, ref1)

      :ok = Registry.unregister(r, :a)
      assert_receive {:loam_registry, :name_vacant, ^r, :a}
    end
  end

  describe "watcher pid death" do
    setup :start_registry

    test "watcher entry is removed when watcher pid dies", %{registry: r} do
      :ok = Registry.register(r, :a, self())

      parent = self()

      watcher =
        spawn(fn ->
          {:ok, _} = Registry.monitor(r, :a)
          send(parent, :ready)
          :timer.sleep(:infinity)
        end)

      assert_receive :ready
      Process.exit(watcher, :kill)
      drain(r)

      # Inspect Session state directly: no leaked entries.
      state = :sys.get_state(r)
      refute Map.has_key?(state.watcher_pids, watcher)
      assert state.watcher_meta == %{}
      assert state.watchers_by_name == %{}

      # Subsequent vacancies don't try to send to the dead pid.
      :ok = Registry.unregister(r, :a)
      drain(r)
    end
  end

  describe "peer-loss eviction path" do
    setup :start_registry

    test "peer-loss eviction fires :name_vacant for each evicted name owned by the lost peer",
         %{registry: r} do
      # Install a synthetic remote-owned entry in the mirror, mark its zid
      # as a known peer in Session state, then drive a :peer_check_tick.
      # In local-only mode current_peers_zid returns [], so the peer fails
      # the liveness check and its entries get evicted via apply_eviction.
      state = :sys.get_state(r)
      remote_zid = "remote-zid-#{System.unique_integer([:positive])}"

      {:applied, :new} =
        Loam.Registry.Mirror.apply_register(
          state.table,
          :remote_a,
          self(),
          nil,
          1,
          remote_zid
        )

      :sys.replace_state(r, fn st ->
        %{st | peers: Map.put(st.peers, remote_zid, %{last_heartbeat_ms: 0})}
      end)

      {:ok, _ref} = Registry.monitor(r, :remote_a)

      send(r, :peer_check_tick)
      drain(r)

      assert_receive {:loam_registry, :name_vacant, ^r, :remote_a}
      assert Registry.lookup(r, :remote_a) == []
    end
  end

  describe ":debounce_ms window" do
    setup :start_registry

    test "default 0 fires immediately (slice 0001 behavior preserved)", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, _} = Registry.monitor(r, :a)
      :ok = Registry.unregister(r, :a)
      assert_receive {:loam_registry, :name_vacant, ^r, :a}, 50
    end

    test "hostile handoff (no replacement) fires after the window", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, _} = Registry.monitor(r, :a, debounce_ms: 60)
      :ok = Registry.unregister(r, :a)

      # Should not have fired yet.
      refute_receive {:loam_registry, :name_vacant, _, :a}, 30

      # ...but should fire after the window completes.
      assert_receive {:loam_registry, :name_vacant, ^r, :a}, 200
    end

    test "peaceful handoff (register inside window) suppresses notification", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, _} = Registry.monitor(r, :a, debounce_ms: 100)
      :ok = Registry.unregister(r, :a)
      # Peaceful: a fresh owner appears within the window.
      :ok = Registry.register(r, :a, spawn_idle())

      refute_receive {:loam_registry, :name_vacant, _, :a}, 200
    end

    test "rapid churn fires exactly once per owned→vacant edge that exceeds window",
         %{registry: r} do
      pid1 = spawn_idle()
      :ok = Registry.register(r, :a, pid1, nil)
      {:ok, _} = Registry.monitor(r, :a, debounce_ms: 80)

      :ok = Registry.unregister(r, :a)
      Process.sleep(20)
      pid2 = spawn_idle()
      :ok = Registry.register(r, :a, pid2, nil)
      Process.sleep(20)
      :ok = Registry.unregister(r, :a)
      pid3 = spawn_idle()
      Process.sleep(20)
      :ok = Registry.register(r, :a, pid3, nil)

      # Final state: owned. No vacancy notification should ever fire.
      refute_receive {:loam_registry, :name_vacant, _, :a}, 200

      # Now go vacant for real and stay vacant: exactly one fire.
      :ok = Registry.unregister(r, :a)
      assert_receive {:loam_registry, :name_vacant, ^r, :a}, 250
      refute_receive {:loam_registry, :name_vacant, _, :a}, 200
    end

    test "watcher pid dying mid-debounce does not leak the timer or fire to a dead pid",
         %{registry: r} do
      parent = self()
      :ok = Registry.register(r, :a, self())

      watcher =
        spawn(fn ->
          {:ok, _} = Registry.monitor(r, :a, debounce_ms: 80)
          send(parent, :ready)
          :timer.sleep(:infinity)
        end)

      assert_receive :ready
      :ok = Registry.unregister(r, :a)
      # Mid-debounce, kill the watcher.
      Process.sleep(20)
      Process.exit(watcher, :kill)

      drain(r)
      state = :sys.get_state(r)
      assert state.watcher_meta == %{}
      assert state.watchers_by_name == %{}
      refute Map.has_key?(state.watcher_pids, watcher)

      # Wait past the debounce window — nothing should arrive in our
      # mailbox (we are not the watcher).
      refute_receive {:loam_registry, :name_vacant, _, _}, 150
    end

    test "demonitor mid-debounce cancels the pending notification", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      {:ok, ref} = Registry.monitor(r, :a, debounce_ms: 80)
      :ok = Registry.unregister(r, :a)
      Process.sleep(20)
      :ok = Registry.demonitor(r, ref)

      refute_receive {:loam_registry, :name_vacant, _, :a}, 200
    end

    test "two watchers with different debounce windows fire independently", %{registry: r} do
      parent = self()
      :ok = Registry.register(r, :a, self())

      tag_short = make_ref()
      tag_long = make_ref()

      short =
        spawn_link(fn ->
          {:ok, _} = Registry.monitor(r, :a, debounce_ms: 30)

          receive do
            msg -> send(parent, {tag_short, msg})
          end
        end)

      long =
        spawn_link(fn ->
          {:ok, _} = Registry.monitor(r, :a, debounce_ms: 200)

          receive do
            msg -> send(parent, {tag_long, msg})
          end
        end)

      drain(r)
      :ok = Registry.unregister(r, :a)

      # Short watcher fires soon, long does not yet.
      assert_receive {^tag_short, {:loam_registry, :name_vacant, ^r, :a}}, 150
      refute_received {^tag_long, _}

      # Long watcher fires later.
      assert_receive {^tag_long, {:loam_registry, :name_vacant, ^r, :a}}, 400

      _ = short
      _ = long
    end
  end

  describe "property: exactly one :name_vacant per debounce-exceeding edge" do
    # Apply a fast back-to-back sequence of register/unregister ops on a
    # single name with a debounce window much larger than the wall-clock
    # cost of the sequence itself. Each intermediate vacancy is shorter
    # than the debounce window, so it gets suppressed. After the sequence
    # settles past the window, the watcher should have received exactly 1
    # :name_vacant if the final state is vacant, and 0 otherwise.

    property "rapid sequences fire 1 iff final state is vacant" do
      check all ops <- list_of(member_of([:register, :unregister]), min_length: 0, max_length: 16),
                max_runs: 30 do
        name = Module.concat(__MODULE__, "PropReg#{System.unique_integer([:positive])}")
        {:ok, _} = start_supervised({Loam.Registry.Session, name: name}, id: name)

        debounce = 80
        {:ok, _} = Registry.monitor(name, :n, debounce_ms: debounce)

        Enum.reduce(ops, :vacant, fn
          :register, :vacant ->
            :ok = Registry.register(name, :n, spawn_idle())
            :owned

          :register, :owned ->
            # already owned — register would error; treat as no-op
            :owned

          :unregister, :owned ->
            :ok = Registry.unregister(name, :n)
            :vacant

          :unregister, :vacant ->
            :vacant
        end)

        final = if Registry.lookup(name, :n) == [], do: :vacant, else: :owned

        Process.sleep(debounce * 2 + 30)

        # A vacancy fires iff the watcher observed an owned→vacant edge
        # whose timer survived the rest of the sequence. That happens iff
        # the sequence contained at least one :register (so an
        # owned→vacant edge was possible) AND the final state is vacant
        # (so no later :register canceled the pending timer).
        had_register? = Enum.any?(ops, &(&1 == :register))
        expected = if had_register? and final == :vacant, do: 1, else: 0
        actual = drain_vacancies(name)

        assert actual == expected,
               "ops=#{inspect(ops)} final=#{inspect(final)} expected=#{expected} actual=#{actual}"

        stop_supervised!(name)
      end
    end
  end

  defp drain_vacancies(registry) do
    drain_vacancies(registry, 0)
  end

  defp drain_vacancies(registry, acc) do
    receive do
      {:loam_registry, :name_vacant, ^registry, :n} -> drain_vacancies(registry, acc + 1)
    after
      0 -> acc
    end
  end

  describe "remote unregister path (apply_inbound)" do
    # Drive apply_inbound directly by sending a synthesized Zenohex.Sample
    # to the Session. The Session is in local-only mode, but its
    # handle_info(%Zenohex.Sample{}, ...) clause runs unconditionally.
    setup :start_registry

    test "remote unregister of an owned name fires :name_vacant", %{registry: r} do
      state = :sys.get_state(r)
      remote_zid = "remote-zid-#{System.unique_integer([:positive])}"

      {:applied, :new} =
        Loam.Registry.Mirror.apply_register(
          state.table,
          :remote_b,
          self(),
          nil,
          1,
          remote_zid
        )

      {:ok, _ref} = Registry.monitor(r, :remote_b)

      payload = Loam.Registry.Announce.encode({:unregister, :remote_b, 2, remote_zid})

      send(r, %Zenohex.Sample{key_expr: "loam/reg/anything/announces", payload: payload})

      drain(r)
      assert_receive {:loam_registry, :name_vacant, ^r, :remote_b}
    end
  end
end
