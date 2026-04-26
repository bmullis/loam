defmodule Loam.RegistryTest do
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

  describe "lookup/2 and count/1 on an unstarted registry" do
    test "lookup returns []" do
      assert Registry.lookup(:nope, :anything) == []
    end

    test "count returns 0" do
      assert Registry.count(:nope) == 0
    end

    test "register returns :no_such_registry" do
      assert {:error, :no_such_registry} =
               Registry.register(:nope, :name, self())
    end

    test "unregister returns :no_such_registry" do
      assert {:error, :no_such_registry} = Registry.unregister(:nope, :name)
    end
  end

  describe "register/3 success paths" do
    setup :start_registry

    test "registering self via 3-arity (pid form)", %{registry: r} do
      assert :ok = Registry.register(r, :a, self())
      assert Registry.lookup(r, :a) == [{self(), nil}]
    end

    test "registering self via 3-arity with a value", %{registry: r} do
      assert :ok = Registry.register(r, :a, %{port: 9000})
      assert Registry.lookup(r, :a) == [{self(), %{port: 9000}}]
    end

    test "registering an explicit pid via 4-arity", %{registry: r} do
      pid = spawn_idle()
      assert :ok = Registry.register(r, :a, pid, :metadata)
      assert Registry.lookup(r, :a) == [{pid, :metadata}]
    end

    test "count and keys reflect the registration", %{registry: r} do
      pid = spawn_idle()
      Registry.register(r, :a, pid, nil)
      Registry.register(r, :b, pid, nil)
      assert Registry.count(r) == 2
      assert Enum.sort(Registry.keys(r, pid)) == [:a, :b]
    end
  end

  describe "register/3 error paths" do
    setup :start_registry

    test "rejects double-claim from same BEAM", %{registry: r} do
      pid = spawn_idle()
      assert :ok = Registry.register(r, :a, pid, nil)
      other = spawn_idle()

      assert {:error, {:already_registered, ^pid}} =
               Registry.register(r, :a, other, nil)
    end

    test "rejects remote pid", %{registry: r} do
      # Build a syntactically remote pid by deserializing one with a
      # synthetic node tag. Cheaper than spinning up a peer node.
      remote_pid = remote_pid(:fake@nohost, 0, 100, 0)
      assert node(remote_pid) != node()

      assert {:error, :remote_pid} =
               Registry.register(r, :a, remote_pid, nil)
    end
  end

  describe "unregister/2" do
    setup :start_registry

    test "owner can unregister their own entry", %{registry: r} do
      :ok = Registry.register(r, :a, self())
      assert :ok = Registry.unregister(r, :a)
      assert Registry.lookup(r, :a) == []
    end

    test "unregister of a missing name is :ok (idempotent)", %{registry: r} do
      assert :ok = Registry.unregister(r, :missing)
    end
  end

  describe "automatic cleanup on pid exit" do
    setup :start_registry

    test "registrations are removed when the registered pid exits", %{registry: r} do
      pid = spawn_idle()
      :ok = Registry.register(r, :a, pid, nil)
      :ok = Registry.register(r, :b, pid, nil)
      assert Registry.count(r) == 2

      Process.exit(pid, :kill)
      # Wait for the Server to process the :DOWN.
      _ = :sys.get_state(r)

      assert Registry.lookup(r, :a) == []
      assert Registry.lookup(r, :b) == []
      assert Registry.count(r) == 0
    end
  end

  # Build a remote-looking pid via the external term format. Deserialized
  # with [:safe] so we never invent atoms; the node atom must already exist.
  defp remote_pid(node_atom, id, serial, creation) do
    _ = node_atom

    bin =
      <<131, 88, 119, byte_size(Atom.to_string(node_atom))::8, Atom.to_string(node_atom)::binary,
        id::32, serial::32, creation::32>>

    :erlang.binary_to_term(bin)
  end
end
