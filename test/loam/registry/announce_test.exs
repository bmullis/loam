defmodule Loam.Registry.AnnounceTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loam.Phoenix.Envelope
  alias Loam.Registry.Announce

  defp zid_gen, do: binary(min_length: 1, max_length: 32)
  defp lamport_gen, do: integer(0..1_000_000)
  defp name_gen, do: term()
  defp value_gen, do: term()

  defp register_gen do
    gen all(name <- name_gen(), value <- value_gen(), l <- lamport_gen(), z <- zid_gen()) do
      {:register, name, self(), value, l, z}
    end
  end

  defp unregister_gen do
    gen all(name <- name_gen(), l <- lamport_gen(), z <- zid_gen()) do
      {:unregister, name, l, z}
    end
  end

  defp heartbeat_gen do
    gen all(z <- zid_gen(), l <- lamport_gen()) do
      {:heartbeat, z, l}
    end
  end

  defp snapshot_request_gen do
    gen all(z <- zid_gen()) do
      {:snapshot_request, z}
    end
  end

  defp snapshot_gen do
    entry =
      gen all(name <- name_gen(), value <- value_gen(), l <- lamport_gen()) do
        {name, self(), value, l}
      end

    gen all(z <- zid_gen(), entries <- list_of(entry, max_length: 8)) do
      {:snapshot, z, entries}
    end
  end

  defp payload_gen do
    one_of([
      register_gen(),
      unregister_gen(),
      heartbeat_gen(),
      snapshot_request_gen(),
      snapshot_gen()
    ])
  end

  describe "encode/1 + decode/1" do
    property "round-trips every payload shape" do
      check all(payload <- payload_gen()) do
        assert {:ok, ^payload} = payload |> Announce.encode() |> Announce.decode()
      end
    end

    test "explicit register round-trip" do
      p = {:register, {:user, 42}, self(), %{node: :a}, 7, "zid-abc"}
      assert {:ok, ^p} = p |> Announce.encode() |> Announce.decode()
    end

    test "explicit snapshot with multiple entries round-trips" do
      p =
        {:snapshot, "zid-x",
         [
           {:name1, self(), nil, 3},
           {{:complex, "name"}, self(), %{v: 1}, 4}
         ]}

      assert {:ok, ^p} = p |> Announce.encode() |> Announce.decode()
    end
  end

  describe "encode/1 rejection paths" do
    test "raises on unknown tag" do
      assert_raise ArgumentError, fn -> Announce.encode({:bogus, 1, 2}) end
    end

    test "raises on malformed register (non-pid)" do
      assert_raise ArgumentError, fn ->
        Announce.encode({:register, :n, :not_a_pid, nil, 1, "z"})
      end
    end

    test "raises on negative lamport" do
      assert_raise ArgumentError, fn ->
        Announce.encode({:unregister, :n, -1, "z"})
      end
    end

    test "raises on non-binary zid" do
      assert_raise ArgumentError, fn -> Announce.encode({:heartbeat, :not_binary, 0}) end
    end
  end

  describe "decode/1 rejection paths" do
    test "envelope-level errors propagate" do
      assert {:error, :bad_magic} = Announce.decode("not an envelope")
      assert {:error, {:bad_version, 9}} = Announce.decode(<<"LOAM", 9, "x">>)
    end

    test "unknown tag inside a valid envelope" do
      bin = Envelope.encode({:bogus_tag, 1, 2, 3})
      assert {:error, {:unknown_tag, :bogus_tag}} = Announce.decode(bin)
    end

    test "known tag with wrong arity is malformed" do
      bin = Envelope.encode({:register, :n, self()})
      assert {:error, :malformed} = Announce.decode(bin)
    end

    test "known tag with wrong types is malformed" do
      bin = Envelope.encode({:heartbeat, :not_binary_zid, 0})
      assert {:error, :malformed} = Announce.decode(bin)
    end

    test "snapshot with malformed entry is malformed" do
      bin = Envelope.encode({:snapshot, "zid", [{:n, :not_pid, nil, 0}]})
      assert {:error, :malformed} = Announce.decode(bin)
    end

    test "non-tuple payload is malformed" do
      bin = Envelope.encode("just a string")
      assert {:error, :malformed} = Announce.decode(bin)
    end

    test "decode never raises on garbage bytes" do
      check_inputs = [
        <<>>,
        <<0>>,
        :crypto.strong_rand_bytes(64),
        <<"LOAM", 1, 0, 0, 0>>
      ]

      for input <- check_inputs do
        assert match?({:error, _}, Announce.decode(input))
      end
    end
  end
end
