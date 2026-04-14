defmodule Cortex.Memo do
  @moduledoc """
  Ecto schema for a single memo entry in the cognition tree.

  Each Worker appends one entry per plan execution. The Synthesizer reads
  the full set of entries for a given plan_id as its input. Memos accumulate
  in SQLite — one micro-transaction at a time, append-only, fully local.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime]

  schema "cortex_memos" do
    field :plan_id, :string
    field :worker_id, :string
    field :subtask, :string
    field :content, :string

    timestamps(updated_at: false)
  end

  def changeset(memo, attrs) do
    memo
    |> cast(attrs, [:plan_id, :worker_id, :subtask, :content])
    |> validate_required([:plan_id, :worker_id, :subtask, :content])
  end
end
