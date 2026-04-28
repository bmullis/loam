defmodule Loam.Registry.MonitorTest do
  use ExUnit.Case, async: true

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
