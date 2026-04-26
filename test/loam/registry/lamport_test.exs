defmodule Loam.Registry.LamportTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loam.Registry.Lamport

  describe "new/0" do
    test "starts at 0" do
      assert Lamport.new() == 0
    end
  end

  describe "tick/1" do
    test "advances by exactly one" do
      {ts, s} = Lamport.tick(0)
      assert ts == 1 and s == 1

      {ts2, s2} = Lamport.tick(s)
      assert ts2 == 2 and s2 == 2
    end

    property "tick is strictly increasing across repeated calls" do
      check all(n <- integer(1..200)) do
        {final_state, ts_seq} =
          Enum.reduce(1..n, {Lamport.new(), []}, fn _, {state, acc} ->
            {ts, state2} = Lamport.tick(state)
            {state2, [ts | acc]}
          end)

        ts_seq = Enum.reverse(ts_seq)
        assert ts_seq == Enum.sort(ts_seq)
        assert Enum.uniq(ts_seq) == ts_seq
        assert final_state == List.last(ts_seq)
        assert hd(ts_seq) == 1
      end
    end

    property "tick result is strictly greater than prior state" do
      check all(state <- integer(0..1_000_000)) do
        {ts, s2} = Lamport.tick(state)
        assert ts > state
        assert s2 == ts
      end
    end
  end

  describe "observe/2" do
    property "advances strictly past max(state, observed)" do
      check all(state <- integer(0..1_000_000), observed <- integer(0..1_000_000)) do
        {ts, s2} = Lamport.observe(state, observed)
        assert ts > state
        assert ts > observed
        assert ts == max(state, observed) + 1
        assert s2 == ts
      end
    end

    property "monotonicity: state never decreases under any sequence of tick/observe" do
      ops =
        one_of([
          tuple({constant(:tick)}),
          tuple({constant(:observe), integer(0..10_000)})
        ])

      check all(seq <- list_of(ops, max_length: 200)) do
        Enum.reduce(seq, Lamport.new(), fn op, state ->
          {ts, state2} =
            case op do
              {:tick} -> Lamport.tick(state)
              {:observe, m} -> Lamport.observe(state, m)
            end

          assert state2 >= state
          assert ts == state2
          state2
        end)
      end
    end
  end
end
