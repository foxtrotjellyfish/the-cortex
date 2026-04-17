defmodule Cortex.Memos do
  @moduledoc """
  Context for the shared Memo store.

  Workers append one entry per sub-task. The Synthesizer reads the full
  memo for a given plan_id as its input context.

  Backed by SQLite via Ecto — entries survive restarts, are inspectable
  at the SQL level, and accumulate across plan executions. Append-only
  by design: there is no update or delete path.
  """

  import Ecto.Query
  alias Cortex.{Memo, Repo}

  @doc """
  Append a worker's output to the memo store.

  Returns `{:ok, memo}` on success, `{:error, changeset}` on failure.
  """
  def append(plan_id, worker_id, subtask, content) do
    %Memo{}
    |> Memo.changeset(%{
      plan_id: plan_id,
      worker_id: worker_id,
      subtask: subtask,
      content: content
    })
    |> Repo.insert()
  end

  @doc """
  Return all memo entries for a plan, ordered by insertion time.
  """
  def list_by_plan(plan_id) do
    Repo.all(
      from m in Memo,
        where: m.plan_id == ^plan_id,
        order_by: [asc: m.inserted_at]
    )
  end

  @doc """
  Format memo entries for Synthesizer input — each entry as a labelled block.
  """
  def to_synthesis_input(entries) do
    entries
    |> Enum.map_join("\n\n", fn entry ->
      "[#{entry.subtask}]\n#{entry.content}"
    end)
  end

  @doc """
  Format memo entries with viewpoint labels for debate-mode synthesis.

  `viewpoint_map` is a `%{worker_id => "LABEL"}` map built by Graph from
  the debate plan state. Each block is tagged with the worker's role so the
  synthesizer can weigh perspectives.
  """
  def to_synthesis_input(entries, viewpoint_map) when is_map(viewpoint_map) do
    entries
    |> Enum.with_index(1)
    |> Enum.map_join("\n\n", fn {entry, idx} ->
      label = Map.get(viewpoint_map, entry.worker_id, "Worker #{idx}")
      "[Worker #{idx} — #{label}]\n#{entry.content}"
    end)
  end
end
