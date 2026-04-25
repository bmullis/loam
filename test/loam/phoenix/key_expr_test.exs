defmodule Loam.Phoenix.KeyExprTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loam.Phoenix.KeyExpr

  @namespace "loam/phx"

  describe "encode/3 + decode/1" do
    property "round-trips arbitrary topic binaries" do
      check all(topic <- binary()) do
        encoded = KeyExpr.encode(@namespace, MyApp.PubSub, topic)
        assert {:ok, {"Elixir.MyApp.PubSub", ^topic}} = KeyExpr.decode(encoded)
      end
    end

    property "round-trips arbitrary pubsub names (string form)" do
      check all(name <- string(:printable, min_length: 1)) do
        encoded = KeyExpr.encode(@namespace, name, "topic")
        assert {:ok, {^name, "topic"}} = KeyExpr.decode(encoded)
      end
    end

    test "handles topics containing all the keyexpr-illegal characters" do
      tricky = "room:42/sub*x$y?z#frag\n\0"
      encoded = KeyExpr.encode(@namespace, "px", tricky)
      assert {:ok, {"px", ^tricky}} = KeyExpr.decode(encoded)
    end

    test "handles empty topic" do
      encoded = KeyExpr.encode(@namespace, "px", "")
      assert {:ok, {"px", ""}} = KeyExpr.decode(encoded)
    end

    test "topic segment contains no slashes even when topic does" do
      encoded = KeyExpr.encode(@namespace, "px", "a/b/c/d")
      topic_segment = encoded |> String.split("/") |> List.last()
      refute String.contains?(topic_segment, "/")
    end

    test "topic segment contains no Zenoh-illegal wildcards" do
      all_bytes = for byte <- 0..255, into: <<>>, do: <<byte>>
      encoded = KeyExpr.encode(@namespace, "px", all_bytes)
      topic_segment = encoded |> String.split("/") |> List.last()

      for c <- ["*", "$", "?", "#"] do
        refute String.contains?(topic_segment, c), "topic segment must not contain #{c}"
      end
    end

    test "encoded result starts with the namespace" do
      encoded = KeyExpr.encode(@namespace, "px", "x")
      assert String.starts_with?(encoded, @namespace <> "/")
    end
  end

  describe "decode/1 rejection paths" do
    test "rejects malformed shape" do
      assert {:error, :bad_shape} = KeyExpr.decode("toofewparts")
      assert {:error, :bad_shape} = KeyExpr.decode("only/two")
    end

    test "rejects bad base64 in pubsub segment" do
      assert {:error, :bad_pubsub_name} = KeyExpr.decode("ns/!!notbase64!!/abc")
    end

    test "rejects bad base64 in topic segment" do
      good_pubsub = Base.url_encode64("px", padding: false)
      assert {:error, :bad_topic} = KeyExpr.decode("ns/#{good_pubsub}/!!notbase64!!")
    end
  end
end
