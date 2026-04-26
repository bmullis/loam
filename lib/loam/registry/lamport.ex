defmodule Loam.Registry.Lamport do
  @moduledoc """
  Per-node Lamport counter for `Loam.Registry`.

  State is a non-negative integer. Two operations:

    * `tick/1` — record a local event. Returns `{ts, new_state}` where
      `ts == new_state == prev + 1`.
    * `observe/2` — incorporate a timestamp seen on the wire and record the
      receipt as a local event. Returns `{ts, new_state}` where
      `ts == new_state == max(prev, observed) + 1`.

  Both operations strictly advance the counter. The counter never moves
  backward.
  """

  @type t :: non_neg_integer()
  @type ts :: pos_integer()

  @spec new() :: t()
  def new, do: 0

  @spec tick(t()) :: {ts(), t()}
  def tick(state) when is_integer(state) and state >= 0 do
    next = state + 1
    {next, next}
  end

  @spec observe(t(), non_neg_integer()) :: {ts(), t()}
  def observe(state, observed)
      when is_integer(state) and state >= 0 and is_integer(observed) and observed >= 0 do
    next = max(state, observed) + 1
    {next, next}
  end
end
