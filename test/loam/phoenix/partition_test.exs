defmodule Loam.Phoenix.PartitionTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Scripted partition test for the Loam.Phoenix.Adapter, exercising the
  *eventual delivery* semantic documented in PRD-0001 Solution item 2 and
  the journal at `docs/journal/2026-04-25-zenoh-lease-tuning-tcp.md`.

  The test asserts:

  - Pre-partition broadcasts arrive.
  - During-partition broadcasts return `:ok` and do not crash the publisher.
  - After heal, all during-partition broadcasts arrive in publish order,
    each exactly once, within a generous heal-timeout.

  The test does **not** assert message gaps on partition, because empirically
  Zenoh's session-level lease cannot declare peer-loss on a TCP-buffered
  partition (see the lease-tuning journal entry). The `:drop` regime is
  covered separately by the peer-death test (gate 4b).

  ## Running

  Tagged `:partition`; excluded from default `mix test`. Must run as root so
  the test can drive `pfctl` directly — `System.cmd` doesn't carry a tty, so
  cached `sudo` creds aren't visible from inside the test.

      sudo -E env "PATH=$PATH" mix test --only partition

  Auto-skips per-test if not running as root, so `mix test --only partition`
  without sudo produces a clean skip rather than a permission error.
  """

  @moduletag :partition

  alias Loam.Phoenix.IntegrationHelper

  @peer_call_timeout 30_000
  @anchor "loam_partition_test"

  setup_all do
    if :os.type() != {:unix, :darwin} do
      raise """
      Loam.Phoenix.PartitionTest currently implements pfctl (Darwin only).
      Linux iptables support is a follow-up.
      """
    end

    if System.cmd("id", ["-u"]) |> elem(0) |> String.trim() != "0" do
      raise """
      Loam.Phoenix.PartitionTest must run as root. See the moduledoc.

          sudo -E env "PATH=$PATH" mix test --only partition
      """
    end

    on_exit(fn -> partition_clear() end)
    :ok
  end

  setup do
    pubsub_name = :"loam_partition_pubsub_#{:erlang.unique_integer([:positive])}"
    {:ok, pubsub_name: pubsub_name}
  end

  test "eventual delivery: during-partition broadcasts arrive after heal, in order",
       %{pubsub_name: pubsub_name} do
    parent_port = unique_port()
    child_port = unique_port()

    {:ok, _sup} = start_local_pubsub(pubsub_name, parent_port, child_port)

    {:ok, peer, _node} =
      :peer.start_link(%{connection: :standard_io, args: build_args()})

    try do
      # Peer subscribes and waits for 3 messages with a generous heal-timeout.
      collector =
        Task.async(fn ->
          :peer.call(
            peer,
            IntegrationHelper,
            :collect_remote,
            [pubsub_name, child_port, parent_port, "p:test", 3, 20_000],
            @peer_call_timeout
          )
        end)

      # Allow peer to start, subscribe, complete handshake.
      Process.sleep(2_500)

      # 1. Pre-partition broadcast.
      assert :ok = Phoenix.PubSub.broadcast(pubsub_name, "p:test", "msg1_pre")

      # 2. Partition. Block both directions of the loopback flow on the peer's
      #    listen port so neither side can deliver.
      :ok = partition_apply(child_port)

      # 3. During-partition broadcasts. Must return :ok, no crash.
      assert :ok = Phoenix.PubSub.broadcast(pubsub_name, "p:test", "msg2_during")
      assert :ok = Phoenix.PubSub.broadcast(pubsub_name, "p:test", "msg3_during")

      # 4. Hold partition briefly, then heal.
      Process.sleep(3_000)
      :ok = partition_clear()

      # 5. Collect on peer side. Asserts the eventual-delivery shape: all 3
      #    messages, in publish order, no duplicates, within heal-timeout.
      assert ["msg1_pre", "msg2_during", "msg3_during"] =
               Task.await(collector, @peer_call_timeout)
    after
      :peer.stop(peer)
      partition_clear()
    end
  end

  ## Partition mechanism (Darwin pfctl). Linux iptables not yet implemented.

  defp partition_apply(port) do
    rule = "block drop quick proto tcp from any to 127.0.0.1 port #{port}\n"
    tmp = Path.join(System.tmp_dir!(), "loam_partition_#{port}.pf")
    File.write!(tmp, rule)

    try do
      {_, 0} =
        System.cmd("pfctl", ["-a", @anchor, "-f", tmp], stderr_to_stdout: true)

      {_, 0} = System.cmd("pfctl", ["-E"], stderr_to_stdout: true)
    after
      File.rm(tmp)
    end

    :ok
  end

  defp partition_clear do
    System.cmd("pfctl", ["-a", @anchor, "-F", "rules"], stderr_to_stdout: true)
    :ok
  end

  ## Two-process rig (mirrors integration_test.exs)

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
