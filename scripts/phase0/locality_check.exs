alias Zenohex.{Config, Publisher, Session}

defmodule LocalityCheck do
  @moduledoc false

  def run do
    config = make_config()
    {:ok, session} = Session.open(config)

    {:ok, sub_default} = Session.declare_subscriber(session, "demo/**", self())

    {:ok, sub_remote} =
      Session.declare_subscriber(session, "demo/**", self(), allowed_origin: :remote)

    {:ok, pub} = Session.declare_publisher(session, "demo/x")

    Process.sleep(100)
    :ok = Publisher.put(pub, "self-pub")
    Process.sleep(500)

    samples = drain([])
    IO.puts("samples received from a same-session publish: #{length(samples)}")
    Enum.each(samples, fn s -> IO.puts("  payload=#{inspect(s.payload)} key=#{s.key_expr}") end)
    IO.puts("(default subscriber id=#{inspect(sub_default)})")
    IO.puts("(allowed_origin: :remote subscriber id=#{inspect(sub_remote)})")

    IO.puts(
      "if count is 1 (not 2), default subscriber is :any but :remote suppressed self-publish — locality filter works"
    )

    IO.puts(
      "if count is 2, default subscriber is :any AND :remote did not suppress — investigate"
    )

    IO.puts("if count is 0, default subscriber is also :remote-ish — investigate")

    Session.close(session)
  end

  defp make_config do
    c = Config.default()
    {:ok, c} = Config.insert_json5(c, "mode", "peer")
    {:ok, c} = Config.insert_json5(c, "listen/endpoints", ~s(["tcp/127.0.0.1:17449"]))
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

LocalityCheck.run()
