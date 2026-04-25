defmodule Loam.Phoenix.EnvelopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loam.Phoenix.Envelope

  describe "encode/1 + decode/1" do
    property "round-trips arbitrary terms" do
      check all(term <- term()) do
        assert {:ok, ^term} = term |> Envelope.encode() |> Envelope.decode()
      end
    end

    test "round-trips a Phoenix.Socket.Broadcast-shaped struct" do
      msg = %{__struct__: SomeFakeBroadcast, topic: "room:42", event: "msg", payload: %{a: 1}}
      assert {:ok, ^msg} = msg |> Envelope.encode() |> Envelope.decode()
    end
  end

  describe "decode/1 rejection paths" do
    test "rejects missing magic" do
      assert {:error, :bad_magic} = Envelope.decode(<<0, 0, 0, 0>>)
      assert {:error, :bad_magic} = Envelope.decode("")
      assert {:error, :bad_magic} = Envelope.decode("LOA")
    end

    test "rejects unknown version" do
      assert {:error, {:bad_version, 2}} = Envelope.decode(<<"LOAM", 2, "anything">>)
      assert {:error, {:bad_version, 99}} = Envelope.decode(<<"LOAM", 99, "x">>)
    end

    test "rejects truncated envelope (magic + version, no payload)" do
      assert {:error, :truncated} = Envelope.decode(<<"LOAM", 1>>)
    end

    test "rejects unsafe payload bytes" do
      assert {:error, :unsafe_term} = Envelope.decode(<<"LOAM", 1, 0, 0, 0>>)
    end

    test "decode/1 never raises" do
      for bin <- [<<>>, <<0>>, <<"LOAM">>, <<"LOAM", 1>>, <<"LOAM", 1, 1, 2, 3>>, "garbage"] do
        assert match?({:error, _}, Envelope.decode(bin))
      end
    end
  end
end
