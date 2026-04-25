alias Zenohex.{Config, Publisher, Session}

defmodule TwoLocalSessions do
  @moduledoc false

  def run do
    port_a = 17447
    port_b = 17448
    config_a = make_config(port_a, port_b)
    config_b = make_config(port_b, port_a)

    {:ok, session_a} = Session.open(config_a)
    {:ok, session_b} = Session.open(config_b)

    {:ok, info_a} = Session.info(session_a)
    {:ok, info_b} = Session.info(session_b)

    IO.puts("session A zid: #{info_a.zid}  (listen tcp/127.0.0.1:#{port_a})")
    IO.puts("session B zid: #{info_b.zid}  (listen tcp/127.0.0.1:#{port_b})")

    {:ok, _sub} = Session.declare_subscriber(session_b, "demo/**", self())
    {:ok, pub} = Session.declare_publisher(session_a, "demo/example/test")

    Process.sleep(500)

    Enum.each(1..3, fn n ->
      payload = "hello #{n}"
      :ok = Publisher.put(pub, payload)
      IO.puts("[A] published #{inspect(payload)}")
    end)

    samples = receive_loop(3, [])
    IO.puts("[B] received #{length(samples)} sample(s):")
    Enum.each(samples, &IO.inspect/1)

    Session.close(session_a)
    Session.close(session_b)
  end

  defp make_config(listen_port, connect_port) do
    c = Config.default()
    {:ok, c} = Config.insert_json5(c, "mode", "peer")
    {:ok, c} = Config.insert_json5(c, "listen/endpoints", ~s(["tcp/127.0.0.1:#{listen_port}"]))
    {:ok, c} = Config.insert_json5(c, "connect/endpoints", ~s(["tcp/127.0.0.1:#{connect_port}"]))
    {:ok, c} = Config.insert_json5(c, "scouting/multicast/enabled", "false")
    c
  end

  defp receive_loop(0, acc), do: Enum.reverse(acc)

  defp receive_loop(remaining, acc) do
    receive do
      %Zenohex.Sample{} = sample -> receive_loop(remaining - 1, [sample | acc])
    after
      3000 -> Enum.reverse(acc)
    end
  end
end

TwoLocalSessions.run()
