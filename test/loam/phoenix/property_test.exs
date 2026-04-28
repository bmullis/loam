defmodule Loam.Phoenix.PropertyTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduledoc """
  Cross-BEAM property test for `Loam.Phoenix.Adapter` (PRD-0001 gate item 5).

  Asserts three invariants under the no-partition case, with a single peer
  publisher and a fixed pool of subscriber pids on the parent BEAM:

  - **Delivery.** Every publish is delivered to every subscriber currently
    subscribed to the publish's topic.
  - **No duplicates.** No subscriber pid receives the same publish twice.
  - **Order.** For a given subscriber and topic, deliveries from the same
    publisher arrive in publish order.

  Generators produce a list of `{:pub, topic_idx, payload}` publish events
  dispatched from the peer BEAM. Subscriptions are static per iteration
  (each subscriber pid subscribes to a fixed subset of topics for the run).
  Dynamic subscribe/unsubscribe interleaving is a follow-up — see PRD
  Solution item 7 (broad subscription) and the deferred Phase-2 Registry
  PRD; a property covering dynamic interleaving needs careful handling of
  subscribe-race semantics that this PRD explicitly declines to answer.
  """

  alias Loam.Phoenix.IntegrationHelper

  @peer_call_timeout 30_000
  @quiescence_ms 400
  @drain_max_ms 30_000
  @poll_ms 50
  @topics ["px:a", "px:b", "px:c"]

  @moduletag timeout: 180_000

  setup_all do
    pubsub_name = :"loam_property_pubsub_#{:erlang.unique_integer([:positive])}"
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, sup} = start_local_pubsub(pubsub_name, parent_port, child_port)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    # Bring up the peer's pubsub once, detached from the :peer.call process,
    # so it survives across iterations.
    :ok =
      :peer.call(
        peer,
        IntegrationHelper,
        :start_pubsub_persistent,
        [pubsub_name, child_port, parent_port],
        @peer_call_timeout
      )

    on_exit(fn ->
      try do
        :peer.stop(peer)
      catch
        _, _ -> :ok
      end

      if Process.alive?(sup), do: Process.exit(sup, :normal)
    end)

    {:ok, pubsub_name: pubsub_name, peer: peer}
  end

  property "delivery, no-duplicates, order across cross-BEAM publishes",
           %{pubsub_name: pubsub_name, peer: peer} do
    check all(plan <- generator(), max_runs: 10) do
      %{subs: subs, pubs: pubs} = plan

      collectors = start_collectors(pubsub_name, subs)

      expected_counts =
        Enum.with_index(subs)
        |> Enum.map(fn {sub_topics, idx} ->
          {idx, Enum.count(pubs, fn {topic, _p} -> topic in sub_topics end)}
        end)
        |> Map.new()

      :ok =
        :peer.call(
          peer,
          IntegrationHelper,
          :broadcast_only,
          [pubsub_name, pubs],
          @peer_call_timeout
        )

      wait_for_quiescence(collectors, expected_counts)
      received = drain_collectors(collectors)

      for {sub_idx, sub_topics} <- Enum.with_index(subs) |> Enum.map(fn {t, i} -> {i, t} end) do
        expected =
          pubs
          |> Enum.filter(fn {topic, _payload} -> topic in sub_topics end)
          |> Enum.map(&elem(&1, 1))

        actual = Map.fetch!(received, sub_idx)

        # Delivery + order: actual matches expected exactly.
        assert actual == expected,
               """
               subscriber #{sub_idx} subscribed to #{inspect(sub_topics)}
               expected: #{inspect(expected)}
               actual:   #{inspect(actual)}
               full plan: #{inspect(plan)}
               """

        # No duplicates: equivalent to length(actual) == length(Enum.uniq(actual))
        # but only meaningful if payloads are unique; the generator guarantees
        # unique payloads.
        assert actual == Enum.uniq(actual),
               "subscriber #{sub_idx} received a duplicate: #{inspect(actual)}"
      end
    end
  end

  ## Generators

  defp generator do
    gen all(
          subs <-
            list_of(list_of(member_of(@topics), max_length: 3), min_length: 1, max_length: 3),
          pubs_count <- integer(0..6),
          pubs <-
            list_of(
              tuple({member_of(@topics), binary(min_length: 1, max_length: 8)}),
              length: pubs_count
            )
        ) do
      # Dedupe topics per subscriber: Phoenix.PubSub delivers once per
      # subscription, so duplicate subscriptions would yield duplicate
      # deliveries (correct Phoenix.PubSub behavior, not a loam invariant).
      subs_unique = Enum.map(subs, &Enum.uniq/1)

      # Dedupe payloads so the no-duplicates invariant is well-defined.
      pubs_unique =
        pubs
        |> Enum.with_index()
        |> Enum.map(fn {{topic, p}, i} -> {topic, "#{i}:" <> p} end)

      %{subs: subs_unique, pubs: pubs_unique}
    end
  end

  ## Collectors — one process per subscriber, accumulates received payloads.

  defp start_collectors(pubsub_name, subs) do
    parent = self()

    subs
    |> Enum.with_index()
    |> Enum.map(fn {topics, idx} ->
      ready = make_ref()

      pid =
        spawn_link(fn ->
          Enum.each(topics, fn t -> :ok = Phoenix.PubSub.subscribe(pubsub_name, t) end)
          send(parent, {ready, :subscribed})
          # Park forever; let pubsub deliveries pile up in the mailbox so
          # the test can poll message_queue_len for quiescence without
          # racing with a draining receive loop.
          park_for_drain()
        end)

      receive do
        {^ready, :subscribed} -> :ok
      after
        2_000 -> flunk("collector #{idx} did not subscribe in time")
      end

      {idx, pid, topics}
    end)
  end

  # Park until told to drain. The receive selectively matches `:__drain__`
  # so pubsub messages stay in the mailbox accumulating, observable via
  # Process.info(:message_queue_len). On drain, scan the whole mailbox via
  # Process.info(:messages) — peeking, not receiving, so we don't reorder.
  defp park_for_drain do
    receive do
      {:__drain__, from, ref} ->
        {:messages, msgs} = Process.info(self(), :messages)
        # Filter out the drain marker that just landed.
        payloads = Enum.reject(msgs, &match?({:__drain__, _, _}, &1))
        send(from, {ref, payloads})
    end
  end

  defp drain_collectors(collectors) do
    Map.new(collectors, fn {idx, pid, _topics} ->
      ref = make_ref()
      send(pid, {:__drain__, self(), ref})

      received =
        receive do
          {^ref, msgs} -> msgs
        after
          5_000 -> flunk("collector #{idx} did not drain in time")
        end

      {idx, received}
    end)
  end

  # Wait until every collector has received at least its expected number
  # of messages AND the total mailbox count has been stable for
  # `@quiescence_ms`. The two conditions together close both directions of
  # the flake:
  #
  #   * Without the count check: a single inter-message gap longer than
  #     `@quiescence_ms` looks like quiescence and the test asserts on a
  #     short drain.
  #   * Without the quiescence check: late duplicates would not be
  #     observed before the assert ran.
  #
  # If `@drain_max_ms` is exhausted before both conditions hold, fall
  # through. The assert that follows will fail with a real diff — that's
  # the right outcome under genuine load: better a failed test than a
  # silently-truncated one.
  defp wait_for_quiescence(collectors, expected_counts) do
    deadline = System.monotonic_time(:millisecond) + @drain_max_ms
    poll_quiescence(collectors, expected_counts, -1, 0, deadline)
  end

  defp poll_quiescence(collectors, expected_counts, last_total, quiet_for, deadline) do
    Process.sleep(@poll_ms)
    counts = mailbox_counts(collectors)
    total = Enum.reduce(counts, 0, fn {_, n}, acc -> acc + n end)
    enough? = Enum.all?(expected_counts, fn {idx, want} -> Map.get(counts, idx, 0) >= want end)

    cond do
      enough? and total == last_total and quiet_for + @poll_ms >= @quiescence_ms ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :ok

      total == last_total ->
        poll_quiescence(collectors, expected_counts, total, quiet_for + @poll_ms, deadline)

      true ->
        poll_quiescence(collectors, expected_counts, total, 0, deadline)
    end
  end

  defp mailbox_counts(collectors) do
    Map.new(collectors, fn {idx, pid, _topics} ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, n} -> {idx, n}
        nil -> {idx, 0}
      end
    end)
  end

  ## Setup helpers

  defp start_local_pubsub(name, listen_port, connect_port) do
    Phoenix.PubSub.Supervisor.start_link(
      name: name,
      adapter: Loam.Phoenix.Adapter,
      zenoh: [
        mode: :peer,
        listen: ["tcp/127.0.0.1:#{listen_port}"],
        connect: ["tcp/127.0.0.1:#{connect_port}"],
        multicast_scouting: false
      ]
    )
  end

  defp unique_port, do: 28_000 + :erlang.unique_integer([:positive, :monotonic])

  defp build_args do
    Enum.flat_map(:code.get_path(), fn path -> [~c"-pa", path] end)
  end
end
