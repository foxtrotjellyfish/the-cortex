# Phase 6B+: Option-Shuffling Position Bias Validation
#
# Tests whether model accuracy is genuine knowledge or position artifact.
# For each question, deterministically shuffle A/B/C/D order, rebuild the
# MC prompt, and check if the model tracks the correct answer to its new
# position. Position-biased models collapse; genuine knowers hold.
#
# Targets: phi3:mini (53%), granite3.1-moe (50%), llama3.2:3b (39%, 80% A-bias),
#          gemma2:2b (26%, 78% A-bias), tinyllama (29%, 74% C-bias)
#
# 5 models × 100 questions × 1 trial = 500 calls (~3 min)
#
# Run: mix run priv/phase6b_option_shuffle.exs

alias Cortex.Benchmark.MedQALoader

test_models = [
  "phi3:mini",
  "granite3.1-moe:3b",
  "llama3.2:3b",
  "gemma2:2b",
  "tinyllama"
]

questions = MedQALoader.sample(100)

shuffle_seed = 99

shuffled_questions =
  questions
  |> Enum.with_index()
  |> Enum.map(fn {q, idx} ->
    original_keys = q.choices |> Enum.sort()
    shuffled_keys =
      original_keys
      |> Enum.with_index()
      |> Enum.sort_by(fn {_k, i} -> :erlang.phash2({shuffle_seed, q.id, i}) end)
      |> Enum.map(fn {k, _i} -> k end)

    mapping = Enum.zip(["A", "B", "C", "D"], shuffled_keys) |> Map.new()
    reverse_mapping = mapping |> Enum.map(fn {new, old} -> {old, new} end) |> Map.new()

    new_mc_lines =
      ["A", "B", "C", "D"]
      |> Enum.map(fn new_letter ->
        old_letter = mapping[new_letter]
        "#{new_letter}) #{q.options[old_letter]}"
      end)

    new_mc_prompt = "Q: #{q.question}\n#{Enum.join(new_mc_lines, "\n")}"
    new_correct = reverse_mapping[q.correct]

    %{
      id: q.id,
      question: q.question,
      mc_prompt: new_mc_prompt,
      correct: new_correct,
      original_correct: q.correct,
      choices: ["A", "B", "C", "D"],
      mapping: mapping,
      reverse_mapping: reverse_mapping
    }
  end)

position_changed = Enum.count(shuffled_questions, fn q -> q.correct != q.original_correct end)
IO.puts("========== PHASE 6B+: OPTION-SHUFFLING POSITION BIAS TEST ==========")
IO.puts("#{length(test_models)} models × #{length(questions)} questions × 1 trial = #{length(test_models) * length(questions)} calls")
IO.puts("Shuffle seed: #{shuffle_seed}")
IO.puts("Questions where correct answer changed position: #{position_changed}/#{length(questions)}")
IO.puts("")

t0 = System.monotonic_time(:millisecond)

all_results =
  for model <- test_models do
    model_t0 = System.monotonic_time(:millisecond)
    IO.puts("========== #{model} (SHUFFLED) ==========\n")

    model_results =
      for q <- shuffled_questions do
        prompt = "#{q.mc_prompt}\nAnswer:"
        config = %{model: model}

        case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
          {:ok, result} ->
            correct? = result.answer == q.correct
            marker = if correct?, do: "✓", else: "✗"

            IO.puts(
              "  #{q.id}: #{result.answer} (conf: #{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}, was: #{q.original_correct}]"
            )

            %{
              model: model,
              id: q.id,
              answer: result.answer,
              correct: q.correct,
              original_correct: q.original_correct,
              is_correct: correct?,
              probabilities: result.probabilities,
              confidence: result.confidence,
              mapping: q.mapping
            }

          {:error, reason} ->
            IO.puts("  #{q.id}: ERROR #{inspect(reason)}")

            %{
              model: model,
              id: q.id,
              answer: nil,
              correct: q.correct,
              original_correct: q.original_correct,
              is_correct: false,
              error: inspect(reason),
              mapping: q.mapping
            }
        end
      end

    model_elapsed = System.monotonic_time(:millisecond) - model_t0
    hits = Enum.count(model_results, & &1.is_correct)
    total = length(model_results)
    pct = if total > 0, do: Float.round(hits / total * 100, 1), else: 0.0

    IO.puts("\n  >> #{model} (shuffled): #{hits}/#{total} (#{pct}%) in #{Float.round(model_elapsed / 1000, 1)}s\n")

    model_results
  end
  |> List.flatten()

elapsed_ms = System.monotonic_time(:millisecond) - t0

# Baseline scores from 6B (hardcoded for comparison)
baseline = %{
  "phi3:mini" => 53.0,
  "granite3.1-moe:3b" => 50.0,
  "llama3.2:3b" => 39.0,
  "gemma2:2b" => 26.0,
  "tinyllama" => 29.0
}

IO.puts("\n========== OPTION-SHUFFLING COMPARISON ==========\n")
IO.puts("| Model | Baseline (6B) | Shuffled | Delta | Verdict |")
IO.puts("| --- | --- | --- | --- | --- |")

shuffle_summaries =
  for model <- test_models do
    model_results = Enum.filter(all_results, &(&1.model == model))
    hits = Enum.count(model_results, & &1.is_correct)
    total = length(model_results)
    shuffled_pct = if total > 0, do: Float.round(hits / total * 100, 1), else: 0.0
    base_pct = baseline[model]
    delta = Float.round(shuffled_pct - base_pct, 1)

    verdict = cond do
      abs(delta) <= 5.0 -> "✓ GENUINE (stable within 5pp)"
      delta < -5.0 -> "✗ POSITION BIAS (#{abs(delta)}pp drop)"
      delta > 5.0 -> "↑ SHUFFLE HELPS (+#{delta}pp)"
    end

    IO.puts("| #{model} | #{base_pct}% | #{shuffled_pct}% | #{if delta >= 0, do: "+", else: ""}#{delta}pp | #{verdict} |")

    %{model: model, baseline: base_pct, shuffled: shuffled_pct, delta: delta, hits: hits, total: total}
  end

# Answer distribution comparison
IO.puts("\n--- Answer Distribution: Shuffled vs Baseline ---\n")

for model <- test_models do
  model_results = Enum.filter(all_results, &(&1.model == model))
  dist = model_results |> Enum.map(& &1.answer) |> Enum.frequencies() |> Enum.sort()
  IO.puts("  #{model} (shuffled): #{inspect(dist)}")
end

IO.puts("\n  Baseline distributions (from 6B):")
IO.puts("  phi3:mini:          A=31, B=23, C=20, D=26")
IO.puts("  granite3.1-moe:3b:  A=25, B=23, C=33, D=19")
IO.puts("  llama3.2:3b:        A=80, B=8,  C=5,  D=7")
IO.puts("  gemma2:2b:          nil=20, A=78, D=2")
IO.puts("  tinyllama:          A=1,  B=25, C=74")

# Per-question flip analysis: which questions changed correctness?
IO.puts("\n--- Per-Question Flip Analysis ---\n")

for model <- test_models do
  model_shuffled = Enum.filter(all_results, &(&1.model == model))

  flips =
    model_shuffled
    |> Enum.map(fn r ->
      {r.id, r.is_correct, r.answer, r.correct, r.original_correct}
    end)

  gained = Enum.count(flips, fn {_id, correct?, _ans, new_correct, orig_correct} ->
    correct? and new_correct != orig_correct
  end)

  lost_count =
    model_shuffled
    |> Enum.count(fn r ->
      not r.is_correct and r.correct != r.original_correct
    end)

  IO.puts("  #{model}: questions where position changed AND result flipped: +#{gained} gained, -#{lost_count} context (of #{position_changed} shuffled)")
end

# Confidence calibration on shuffled
IO.puts("\n--- Confidence Calibration (Shuffled) ---\n")

for model <- test_models do
  model_results = Enum.filter(all_results, &(&1.model == model))

  avg_conf_correct =
    model_results
    |> Enum.filter(& &1.is_correct)
    |> Enum.map(& &1[:confidence])
    |> Enum.filter(&is_number/1)
    |> then(fn c -> if length(c) > 0, do: Float.round(Enum.sum(c) / length(c), 3), else: 0.0 end)

  avg_conf_wrong =
    model_results
    |> Enum.reject(& &1.is_correct)
    |> Enum.map(& &1[:confidence])
    |> Enum.filter(&is_number/1)
    |> then(fn c -> if length(c) > 0, do: Float.round(Enum.sum(c) / length(c), 3), else: 0.0 end)

  gap = Float.round(avg_conf_correct - avg_conf_wrong, 3)
  IO.puts("  #{model}: correct=#{avg_conf_correct} wrong=#{avg_conf_wrong} gap=#{gap}")
end

# Save trace
trace_dir = "priv/benchmark_traces/phase6b"
File.mkdir_p!(trace_dir)

trace = %{
  phase: "6B-shuffle",
  method: "option_shuffled_position_bias_test",
  description: "5 models × 100 MedQA questions with shuffled A/B/C/D order",
  shuffle_seed: shuffle_seed,
  models: test_models,
  questions: length(questions),
  position_changed: position_changed,
  elapsed_ms: elapsed_ms,
  summaries: shuffle_summaries,
  results: Enum.map(all_results, fn r ->
    %{
      model: r.model,
      id: r.id,
      answer: r.answer,
      correct: r.correct,
      original_correct: r.original_correct,
      is_correct: r.is_correct,
      probabilities: r[:probabilities],
      confidence: r[:confidence],
      mapping: r.mapping
    }
  end)
}

trace_path = Path.join(trace_dir, "phase6b-shuffle-summary.json")
File.write!(trace_path, Jason.encode!(trace, pretty: true))

IO.puts("\n========== OPTION-SHUFFLING TEST COMPLETE ==========")
IO.puts("#{length(all_results)} total calls in #{Float.round(elapsed_ms / 1000, 1)}s (#{Float.round(elapsed_ms / 60_000, 1)} min)")
IO.puts("Trace: #{trace_path}")
