defmodule Loam.Anchor.LocalSup do
  @moduledoc false

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    child_spec = Keyword.fetch!(opts, :child_spec)
    max_restarts = Keyword.fetch!(opts, :max_restarts)
    max_seconds = Keyword.fetch!(opts, :max_seconds)

    Supervisor.init([child_spec],
      strategy: :one_for_one,
      max_restarts: max_restarts,
      max_seconds: max_seconds
    )
  end

  @spec child_pid(pid()) :: pid() | nil
  def child_pid(sup) do
    case Supervisor.which_children(sup) do
      [{_id, pid, _type, _mods}] when is_pid(pid) -> pid
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end
end
