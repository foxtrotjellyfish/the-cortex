# Phase 6F: MedQA Full Scale-Up
#
# phi3:mini solo on ALL 1,270 clean MedQA questions.
# Same config as 6B baseline: flat /api/generate, no system message,
# logprobs MC scoring, temp=0, 1 trial (deterministic).
#
# Expected: ~1,270 calls, ~25 min wall time.
# Key question: does 53% (100-Q sample) hold at full scale?
#
# Run: mix run priv/phase6f_medqa_scaleup.exs

alias Cortex.Benchmark.MedQALoader

model = "phi3:mini"
questions = MedQALoader.load_all()
trials = 1

total_calls = length(questions) * trials
IO.puts("========== PHASE 6F: MedQA FULL SCALE-UP ==========")
IO.puts("Model: #{model}")
IO.puts("Questions: #{length(questions)} (full MedQA test set, 3 degenerate excluded)")
IO.puts("Trials: #{trials} (deterministic at temp=0)")
IO.puts("Expected calls: #{total_calls}")
IO.puts("Start: #{DateTime.utc_now() |> DateTime.to_iso8601()}\n")

t0 = System.monotonic_time(:millisecond)

results =
  for {q, idx} <- Enum.with_index(questions, 1), trial <- 1..trials do
    prompt = "#{q.mc_prompt}\nAnswer:"
    config = %{model: model}

    case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
      {:ok, result} ->
        correct? = result.answer == q.correct
        marker = if correct?, do: "✓", else: "✗"

        if rem(idx, 50) == 0 or idx == length(questions) do
          elapsed = (System.monotonic_time(:millisecond) - t0) / 1000
          hits_so_far =
            Process.get(:hits, 0) + if(correct?, do: 1, else: 0)
          Process.put(:hits, hits_so_far)
          pct = Float.round(hits_so_far / idx * 100, 1)
          IO.puts("  [#{idx}/#{length(questions)}] #{pct}% so far (#{hits_so_far}/#{idx}) — #{Float.round(elapsed, 1)}s elapsed")
        else
          if correct?, do: Process.put(:hits, Process.get(:hits, 0) + 1)
        end

        IO.puts("  #{q.id}: #{result.answer} (conf: #{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]")

        %{
          model: model,
          id: q.id,
          trial: trial,
          answer: result.answer,
          correct: q.correct,
          is_correct: correct?,
          probabilities: result.probabilities,
          confidence: result.confidence
        }

      {:error, reason} ->
        IO.puts("  #{q.id}: ERROR #{inspect(reason)}")

        %{
          model: model,
          id: q.id,
          trial: trial,
          answer: nil,
          correct: q.correct,
          is_correct: false,
          error: inspect(reason)
        }
    end
  end

elapsed_ms = System.monotonic_time(:millisecond) - t0

# === RESULTS ===

hits = Enum.count(results, & &1.is_correct)
errors = Enum.count(results, &(&1.answer == nil))
total = length(results)
pct = if total > 0, do: Float.round(hits / total * 100, 1), else: 0.0

IO.puts("\n========== PHASE 6F RESULTS ==========\n")
IO.puts("Model: #{model}")
IO.puts("Questions: #{total}")
IO.puts("Correct: #{hits}/#{total} (#{pct}%)")
IO.puts("Errors: #{errors}")
IO.puts("Wall time: #{Float.round(elapsed_ms / 1000, 1)}s (#{Float.round(elapsed_ms / 60_000, 1)} min)")
IO.puts("Avg latency: #{if total > 0, do: Float.round(elapsed_ms / total, 0) |> trunc, else: 0}ms/call")

# === CONFIDENCE CALIBRATION ===

correct_results = Enum.filter(results, & &1.is_correct)
wrong_results = results |> Enum.reject(& &1.is_correct) |> Enum.filter(&(&1.answer != nil))

avg_conf_correct =
  correct_results
  |> Enum.map(& &1.confidence)
  |> then(fn c -> if length(c) > 0, do: Float.round(Enum.sum(c) / length(c), 3), else: 0.0 end)

avg_conf_wrong =
  wrong_results
  |> Enum.map(& &1.confidence)
  |> then(fn c -> if length(c) > 0, do: Float.round(Enum.sum(c) / length(c), 3), else: 0.0 end)

IO.puts("\nConfidence calibration:")
IO.puts("  Correct: avg conf #{avg_conf_correct} (#{length(correct_results)} Qs)")
IO.puts("  Wrong:   avg conf #{avg_conf_wrong} (#{length(wrong_results)} Qs)")
IO.puts("  Gap:     #{Float.round(avg_conf_correct - avg_conf_wrong, 3)}")

# === ANSWER DISTRIBUTION ===

IO.puts("\n--- Answer Distribution ---\n")

answer_dist = results |> Enum.map(& &1.answer) |> Enum.frequencies() |> Enum.sort()
correct_dist = results |> Enum.map(& &1.correct) |> Enum.frequencies() |> Enum.sort()

IO.puts("  Model answers:   #{inspect(answer_dist)}")
IO.puts("  Correct answers: #{inspect(correct_dist)}")

# === PER-ANSWER-LETTER ACCURACY ===

IO.puts("\n--- Accuracy by Correct Answer Letter ---\n")

for letter <- ["A", "B", "C", "D"] do
  letter_qs = Enum.filter(results, &(&1.correct == letter))
  letter_hits = Enum.count(letter_qs, & &1.is_correct)
  letter_pct = if length(letter_qs) > 0, do: Float.round(letter_hits / length(letter_qs) * 100, 1), else: 0.0
  IO.puts("  #{letter}: #{letter_hits}/#{length(letter_qs)} (#{letter_pct}%)")
end

# === COMPARISON TO 100-Q SAMPLE ===

IO.puts("\n--- 100-Q Sample vs Full Scale ---\n")

sample_ids = MedQALoader.sample(100) |> Enum.map(& &1.id) |> MapSet.new()
sample_results = Enum.filter(results, &MapSet.member?(sample_ids, &1.id))
sample_hits = Enum.count(sample_results, & &1.is_correct)
sample_total = length(sample_results)
sample_pct = if sample_total > 0, do: Float.round(sample_hits / sample_total * 100, 1), else: 0.0

nonsample_results = Enum.reject(results, &MapSet.member?(sample_ids, &1.id))
nonsample_hits = Enum.count(nonsample_results, & &1.is_correct)
nonsample_total = length(nonsample_results)
nonsample_pct = if nonsample_total > 0, do: Float.round(nonsample_hits / nonsample_total * 100, 1), else: 0.0

IO.puts("  100-Q sample (seed=42): #{sample_hits}/#{sample_total} (#{sample_pct}%) — 6B was 53%")
IO.puts("  Remaining 1,170 Qs:     #{nonsample_hits}/#{nonsample_total} (#{nonsample_pct}%)")
IO.puts("  Full 1,270 Qs:          #{hits}/#{total} (#{pct}%)")
IO.puts("  Delta (full vs sample): #{Float.round(pct - 53.0, 1)}pp")

# === PUBLISHABLE COMPARISON ===

IO.puts("\n--- Dot on the Graph ---\n")
IO.puts("  GPT-3.5:                       60.2%")
IO.puts("  Phi-3-mini published baseline:  57.5%")
IO.puts("  Our phi3:mini (Ollama logprobs): #{pct}% (#{total} Qs)")
IO.puts("  Phi-4 (14B):                    77.8%")
IO.puts("  GPT-4:                          ~85.8%")

# === SAVE TRACES ===

trace_dir = "priv/benchmark_traces/phase6f"
File.mkdir_p!(trace_dir)

summary = %{
  phase: "6F",
  method: "solo_logprobs_mc_medqa_full_scaleup",
  description: "phi3:mini solo on full MedQA test set (#{total} questions, 1 trial, temp=0)",
  model: model,
  questions: total,
  trials: trials,
  total_calls: total,
  elapsed_ms: elapsed_ms,
  accuracy: pct,
  hits: hits,
  errors: errors,
  avg_conf_correct: avg_conf_correct,
  avg_conf_wrong: avg_conf_wrong,
  answer_distribution: Map.new(answer_dist),
  correct_distribution: Map.new(correct_dist),
  sample_accuracy: sample_pct,
  nonsample_accuracy: nonsample_pct,
  results: Enum.map(results, fn r ->
    %{
      id: r.id,
      answer: r.answer,
      correct: r.correct,
      is_correct: r.is_correct,
      probabilities: r[:probabilities],
      confidence: r[:confidence]
    }
  end)
}

summary_path = Path.join(trace_dir, "phase6f-scaleup-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("\n========== PHASE 6F COMPLETE ==========")
IO.puts("#{total} calls in #{Float.round(elapsed_ms / 1000, 1)}s (#{Float.round(elapsed_ms / 60_000, 1)} min)")
IO.puts("Trace: #{summary_path}")
IO.puts("End: #{DateTime.utc_now() |> DateTime.to_iso8601()}")
