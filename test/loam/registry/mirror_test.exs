defmodule Loam.Registry.MirrorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Loam.Registry.Mirror

  defp fresh_table, do: Mirror.new()

  defp pid_pool(n) do
    for _ <- 1..n, do: spawn(fn -> :timer.sleep(:infinity) end)
  end

  describe "apply_register/6" do
    test "first register on a name applies as :new" do
      t = fresh_table()
      [p] = pid_pool(1)
      assert {:applied, :new} = Mirror.apply_register(t, :n, p, :v, 1, "z1")
      assert Mirror.lookup(t, :n) == [{p, :v}]
    end

    test "higher lamport from a different zid evicts the prior entry" do
      t = fresh_table()
      [p1, p2] = pid_pool(2)
      assert {:applied, :new} = Mirror.apply_register(t, :n, p1, :v1, 1, "zA")

      assert {:applied, {:evicted, ^p1, "zA"}} =
               Mirror.apply_register(t, :n, p2, :v2, 2, "zB")

      assert Mirror.lookup(t, :n) == [{p2, :v2}]
    end

    test "lower lamport is rejected" do
      t = fresh_table()
      [p1, p2] = pid_pool(2)
      Mirror.apply_register(t, :n, p1, :v1, 5, "zA")
      assert :rejected = Mirror.apply_register(t, :n, p2, :v2, 4, "zB")
      assert Mirror.lookup(t, :n) == [{p1, :v1}]
    end

    test "ZID lexicographic tiebreak on equal lamport" do
      t = fresh_table()
      [p1, p2] = pid_pool(2)
      Mirror.apply_register(t, :n, p1, :v1, 5, "zA")

      assert {:applied, {:evicted, ^p1, "zA"}} =
               Mirror.apply_register(t, :n, p2, :v2, 5, "zB")

      [p3] = pid_pool(1)
      assert :rejected = Mirror.apply_register(t, :n, p3, :v3, 5, "zA")
    end

    test "exact-duplicate (same lamport+zid) re-application is idempotent" do
      t = fresh_table()
      [p1] = pid_pool(1)
      Mirror.apply_register(t, :n, p1, :v, 3, "zA")
      assert :duplicate = Mirror.apply_register(t, :n, p1, :v, 3, "zA")
      assert Mirror.lookup(t, :n) == [{p1, :v}]
    end
  end

  describe "apply_unregister/4" do
    test "owner can unregister with strictly newer lamport" do
      t = fresh_table()
      [p] = pid_pool(1)
      Mirror.apply_register(t, :n, p, :v, 1, "zA")
      assert :applied = Mirror.apply_unregister(t, :n, 2, "zA")
      assert Mirror.lookup(t, :n) == []
    end

    test "non-owner cannot unregister" do
      t = fresh_table()
      [p] = pid_pool(1)
      Mirror.apply_register(t, :n, p, :v, 1, "zA")
      assert :rejected = Mirror.apply_unregister(t, :n, 99, "zB")
      assert Mirror.lookup(t, :n) == [{p, :v}]
    end

    test "stale unregister from owner is rejected" do
      t = fresh_table()
      [p] = pid_pool(1)
      Mirror.apply_register(t, :n, p, :v, 5, "zA")
      assert :rejected = Mirror.apply_unregister(t, :n, 5, "zA")
      assert :rejected = Mirror.apply_unregister(t, :n, 4, "zA")
    end

    test "unregister of a missing name is :duplicate (idempotent)" do
      t = fresh_table()
      assert :duplicate = Mirror.apply_unregister(t, :n, 1, "zA")
    end
  end

  describe "apply_eviction/2" do
    test "evicts every entry owned by the given zid" do
      t = fresh_table()
      [p1, p2, p3] = pid_pool(3)
      Mirror.apply_register(t, :a, p1, :v1, 1, "zA")
      Mirror.apply_register(t, :b, p2, :v2, 1, "zA")
      Mirror.apply_register(t, :c, p3, :v3, 1, "zB")

      evicted = Mirror.apply_eviction(t, "zA")
      assert Enum.sort(evicted) == Enum.sort([{:a, p1, :v1, 1}, {:b, p2, :v2, 1}])
      assert Mirror.lookup(t, :a) == []
      assert Mirror.lookup(t, :b) == []
      assert Mirror.lookup(t, :c) == [{p3, :v3}]
    end

    test "no-op when no entries match the zid" do
      t = fresh_table()
      assert [] = Mirror.apply_eviction(t, "zNobody")
    end
  end

  describe "lookup/2, keys_for_pid/2, count/1, entries_owned_by/2" do
    test "all four agree on a small populated table" do
      t = fresh_table()
      [p1, p2] = pid_pool(2)
      Mirror.apply_register(t, :a, p1, :va, 1, "zA")
      Mirror.apply_register(t, {:complex, "b"}, p1, :vb, 2, "zA")
      Mirror.apply_register(t, :c, p2, :vc, 1, "zB")

      assert Mirror.lookup(t, :a) == [{p1, :va}]
      assert Mirror.lookup(t, :missing) == []
      assert Enum.sort(Mirror.keys_for_pid(t, p1)) == Enum.sort([:a, {:complex, "b"}])
      assert Mirror.count(t) == 3

      owned = Mirror.entries_owned_by(t, "zA") |> Enum.sort()

      assert owned ==
               Enum.sort([{:a, p1, :va, 1}, {{:complex, "b"}, p1, :vb, 2}])
    end
  end

  describe "property: invariants over arbitrary event sequences" do
    @max_names 4
    @max_zids 3

    defp event_gen do
      one_of([
        tuple({
          constant(:register),
          integer(0..(@max_names - 1)),
          integer(0..(@max_zids - 1)),
          integer(0..50),
          integer(0..(@max_zids - 1))
        }),
        tuple({
          constant(:unregister),
          integer(0..(@max_names - 1)),
          integer(0..50),
          integer(0..(@max_zids - 1))
        })
      ])
    end

    property "uniqueness, LWW agreement, and idempotence hold for any sequence" do
      check all(seq <- list_of(event_gen(), max_length: 60)) do
        t = fresh_table()
        pids = pid_pool(@max_zids)
        zids = for i <- 0..(@max_zids - 1), do: "zid-#{i}"

        # Track per-name max (lamport, zid) ever applied as a winning register
        # or unregister, so we can independently check LWW.
        Enum.reduce(seq, %{}, fn ev, max_seen ->
          case ev do
            {:register, n, pid_idx, l, z_idx} ->
              z = Enum.at(zids, z_idx)
              p = Enum.at(pids, pid_idx)
              result = Mirror.apply_register(t, n, p, {:val, n, l, z}, l, z)
              snapshot = :ets.lookup(t, n)

              # Idempotence: replaying the exact same event leaves the table
              # unchanged. The second result is :duplicate when the first won
              # (the entry is now its own twin) and :rejected when the first
              # lost (the table still holds the prior winner).
              second = Mirror.apply_register(t, n, p, {:val, n, l, z}, l, z)
              assert :ets.lookup(t, n) == snapshot

              case result do
                {:applied, _} -> assert second == :duplicate
                :rejected -> assert second == :rejected
                :duplicate -> assert second == :duplicate
              end

              expected_winner = winner(max_seen[n], {l, z})

              new_max =
                case result do
                  {:applied, _} ->
                    assert expected_winner == {l, z}
                    Map.put(max_seen, n, {l, z})

                  :rejected ->
                    refute expected_winner == {l, z}
                    max_seen

                  :duplicate ->
                    max_seen
                end

              # Uniqueness: at most one entry per name.
              assert length(:ets.lookup(t, n)) <= 1
              new_max

            {:unregister, n, l, z_idx} ->
              z = Enum.at(zids, z_idx)
              first = Mirror.apply_unregister(t, n, l, z)
              snapshot = :ets.lookup(t, n)
              second = Mirror.apply_unregister(t, n, l, z)
              assert :ets.lookup(t, n) == snapshot

              case first do
                :applied -> assert second == :duplicate
                :rejected -> assert second == :rejected
                :duplicate -> assert second == :duplicate
              end

              assert length(:ets.lookup(t, n)) <= 1

              # Mirror is no-tombstone: a successful unregister clears the
              # slot, so the LWW high-water mark is reset for that name.
              if first == :applied, do: Map.delete(max_seen, n), else: max_seen
          end
        end)
      end
    end

    defp winner(nil, b), do: b

    defp winner({la, za}, {lb, zb}) do
      if la > lb or (la == lb and za > zb), do: {la, za}, else: {lb, zb}
    end
  end
end
