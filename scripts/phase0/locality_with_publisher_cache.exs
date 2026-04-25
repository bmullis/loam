alias Zenohex.{Config, Publisher, Session}

defmodule LocalityRepro do
  @moduledoc false

  def run do
    config = make_config()
    {:ok, session} = Session.open(config)

    # Mimic the adapter's pattern: one broad subscriber on a prefix with :remote.
    {:ok, _sub} =
      Session.declare_subscriber(session, "loam/phx/test/**", self(), allowed_origin: :remote)

    # Then declare a publisher on a SPECIFIC topic key under that prefix.
    {:ok, pub} = Session.declare_publisher(session, "loam/phx/test/topicA")

    Process.sleep(200)
    :ok = Publisher.put(pub, "hello")
    Process.sleep(500)

    samples = drain([])
    IO.puts("samples received: #{length(samples)}")
    Enum.each(samples, &IO.inspect/1)
    IO.puts("expected: 0  (subscriber is :remote, publisher is same session)")

    Session.close(session)
  end

  defp make_config do
    c = Config.default()
    {:ok, c} = Config.insert_json5(c, "mode", "peer")
    {:ok, c} = Config.insert_json5(c, "listen/endpoints", ~s(["tcp/127.0.0.1:17460"]))
    {:ok, c} = Config.insert_json5(c, "scouting/multicast/enabled", "false")
    c
  end

  defp drain(acc) do
    receive do
      %Zenohex.Sample{} = s -> drain([s | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

LocalityRepro.run()
