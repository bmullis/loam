defmodule Loam.Phoenix.AdapterTest do
  use ExUnit.Case, async: false

  # Boot smoke test: a Phoenix.PubSub instance with the loam adapter starts,
  # node_name/1 returns the Zenoh ZID, direct_broadcast/5 raises, and a
  # local-only broadcast reaches a local subscriber via the adapter's
  # local_broadcast path.

  alias Loam.Phoenix.Adapter

  defp start_pubsub(name, port) do
    start_supervised!(
      {Phoenix.PubSub,
       name: name,
       adapter: Adapter,
       zenoh: [
         mode: :peer,
         listen: ["tcp/127.0.0.1:#{port}"],
         multicast_scouting: false
       ]}
    )

    Module.concat(name, "Adapter")
  end

  test "adapter boots, node_name returns a string ZID, direct_broadcast raises" do
    adapter_name = start_pubsub(:"loam_test_pubsub_#{:erlang.unique_integer([:positive])}", 27447)

    name = Adapter.node_name(adapter_name)
    assert is_binary(name)
    assert byte_size(name) == 32

    assert_raise ArgumentError, ~r/does not support direct_broadcast/, fn ->
      Adapter.direct_broadcast(adapter_name, "anywhere", "topic", :msg, Phoenix.PubSub)
    end
  end

  test "broadcast/4 delivers to a local subscriber on the same node" do
    pubsub = :"loam_test_pubsub_#{:erlang.unique_integer([:positive])}"
    _adapter_name = start_pubsub(pubsub, 27448)

    :ok = Phoenix.PubSub.subscribe(pubsub, "room:42")
    :ok = Phoenix.PubSub.broadcast(pubsub, "room:42", {:hello, "world"})

    assert_receive {:hello, "world"}, 1_000
  end
end
