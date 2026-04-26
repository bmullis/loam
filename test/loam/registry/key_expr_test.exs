defmodule Loam.Registry.KeyExprTest do
  use ExUnit.Case, async: true

  alias Loam.Registry.KeyExpr

  @ns "loam/reg"

  describe "announce_key/2 + classify/1" do
    test "round-trips to :announce" do
      key = KeyExpr.announce_key(@ns, MyReg)

      assert key ==
               "loam/reg/" <> Base.url_encode64("Elixir.MyReg", padding: false) <> "/announces"

      assert KeyExpr.classify(key) == :announce
    end

    test "registry name as a string also works" do
      assert KeyExpr.announce_key(@ns, "raw_name") =~ ~r/announces$/
    end
  end

  describe "classify/1 rejection" do
    test "non-loam keys are :ignore" do
      assert :ignore = KeyExpr.classify("totally/random/key")
      assert :ignore = KeyExpr.classify("loam/reg/MyReg/garbage")
    end

    test "old-style per-name keys are :ignore (collapsed in this revision)" do
      # Pre-collapse layout — confirms the old shape is no longer recognized
      # so a peer running mismatched versions just drops samples.
      old = "loam/reg/MyReg/name/abc123"
      assert :ignore = KeyExpr.classify(old)
    end
  end
end
