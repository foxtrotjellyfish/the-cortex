defmodule Cortex.Benchmark.MedQALoader do
  @moduledoc """
  Loads MedQA USMLE 4-option test set and emits maps compatible with
  the benchmark harness (same shape as MCSuite.get/1).

  Data: priv/data/medqa/medqa_usmle_4opt_test.json (1,273 questions).
  Three degenerate items excluded (reference missing abstracts).
  """

  @data_path "priv/data/medqa/medqa_usmle_4opt_test.json"
  @degenerate_ids MapSet.new(["test-00192", "test-00535", "test-01129"])

  @type question :: %{
          id: String.t(),
          question: String.t(),
          mc_prompt: String.t(),
          correct: String.t(),
          choices: [String.t()],
          options: %{String.t() => String.t()}
        }

  @doc """
  Load all clean questions (1,270 after degenerate exclusion).
  """
  @spec load_all() :: [question()]
  def load_all do
    @data_path
    |> File.read!()
    |> Jason.decode!()
    |> Enum.reject(&MapSet.member?(@degenerate_ids, &1["id"]))
    |> Enum.map(&format_question/1)
  end

  @doc """
  Deterministic sample of N questions using the given seed.
  Returns the sampled list sorted by original ID for reproducibility.
  """
  @spec sample(pos_integer(), non_neg_integer()) :: [question()]
  def sample(n, seed \\ 42) do
    all = load_all()

    all
    |> Enum.with_index()
    |> Enum.sort_by(fn {_q, idx} -> :erlang.phash2({seed, idx}) end)
    |> Enum.take(n)
    |> Enum.map(fn {q, _idx} -> q end)
    |> Enum.sort_by(& &1.id)
  end

  @doc """
  Get a single question by ID (e.g. "test-00000").
  """
  @spec get(String.t()) :: question()
  def get(id) do
    load_all()
    |> Enum.find(&(&1.id == id))
    |> case do
      nil -> raise "MedQA question #{id} not found"
      q -> q
    end
  end

  @doc """
  Total clean question count.
  """
  @spec count() :: non_neg_integer()
  def count, do: length(load_all())

  defp format_question(%{"id" => id, "question" => question, "options" => options, "answer" => answer}) do
    sorted_keys = options |> Map.keys() |> Enum.sort()

    mc_lines =
      Enum.map(sorted_keys, fn key ->
        "#{key}) #{options[key]}"
      end)

    mc_prompt = "Q: #{question}\n#{Enum.join(mc_lines, "\n")}"

    %{
      id: id,
      question: question,
      mc_prompt: mc_prompt,
      correct: answer,
      choices: sorted_keys,
      options: options
    }
  end
end
