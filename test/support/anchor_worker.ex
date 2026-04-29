defmodule Loam.Test.AnchorWorker do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    if reporter = Keyword.get(opts, :report_to) do
      send(reporter, {:anchor_worker_started, self()})
    end

    Process.flag(:trap_exit, true)
    {:ok, %{opts: opts, report_to: Keyword.get(opts, :report_to)}}
  end

  @impl true
  def handle_call(:crash, _from, _state), do: exit(:bang)

  @impl true
  def terminate(reason, %{report_to: reporter}) when is_pid(reporter) do
    send(reporter, {:anchor_worker_terminated, self(), reason})
    :ok
  end

  def terminate(_reason, _state), do: :ok

  def crash(pid), do: GenServer.call(pid, :crash, 100)
end
