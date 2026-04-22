# Phase 6A: MedQA Solo Feasibility Gate
#
# phi3:mini solo on 20 MedQA questions (first 20 from the 100-Q sample).
# Constrained MC, logprobs, 3 trials each = 60 Ollama calls.
# Gate: >= 40% (8/20) GREEN, 25-39% YELLOW, < 25% RED.
#
# Run: mix run priv/phase6a_medqa_feasibility.exs

alias Cortex.Benchmark.MedQALoader

model = "phi3:mini"
trials = 3

sample_20 = MedQALoader.sample(100) |> Enum.take(20)

total_calls = length(sample_20) * trials
IO.puts("========== PHASE 6A: MedQA SOLO FEASIBILITY GATE ==========")
IO.puts("Model: #{model}")
IO.puts("Questions: #{length(sample_20)} (first 20 from 100-Q sample, seed=42)")
IO.puts("Trials: #{trials}")
IO.puts("Total calls: #{total_calls}")
IO.puts("")

t0 = System.monotonic_time(:millisecond)

results =
  for q <- sample_20 do
    IO.puts("--- #{q.id} [correct: #{q.correct}] ---")
    IO.puts("  #{String.slice(q.question, 0, 100)}...")

    trial_results =
      for trial <- 1..trials do
        prompt = "#{q.mc_prompt}\nAnswer:"
        config = %{model: model}

        case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
          {:ok, result} ->
            correct? = result.answer == q.correct
            marker = if correct?, do: "✓", else: "✗"

            IO.puts(
              "  T#{trial}: #{result.answer} (conf: #{Float.round(result.confidence, 3)}) #{marker}"
            )

            %{
              id: q.id,
              trial: trial,
              answer: result.answer,
              correct: q.correct,
              is_correct: correct?,
              probabilities: result.probabilities,
              confidence: result.confidence
            }

          {:error, reason} ->
            IO.puts("  T#{trial}: ERROR #{inspect(reason)}")

            %{
              id: q.id,
              trial: trial,
              answer: nil,
              correct: q.correct,
              is_correct: false,
              error: inspect(reason)
            }
        end
      end

    hits = Enum.count(trial_results, & &1.is_correct)
    IO.puts("  >> #{hits}/#{trials}\n")

    trial_results
  end
  |> List.flatten()

elapsed_ms = System.monotonic_time(:millisecond) - t0

# --- Summary ---

total_correct = Enum.count(results, & &1.is_correct)
total_results = length(results)
per_question_correct = div(total_correct, trials)
per_question_total = length(sample_20)
pct = Float.round(per_question_correct / per_question_total * 100, 1)

IO.puts("========== PHASE 6A RESULTS ==========\n")
IO.puts("Raw: #{total_correct}/#{total_results} trial-level correct")
IO.puts("Per-question (majority of #{trials} trials): #{per_question_correct}/#{per_question_total} (#{pct}%)")
IO.puts("Wall time: #{Float.round(elapsed_ms / 1000, 1)}s")
IO.puts("")

# Per-question breakdown
IO.puts("| Question ID | T1 | T2 | T3 | Correct | Result |")
IO.puts("| --- | --- | --- | --- | --- | --- |")

for q <- sample_20 do
  q_results = Enum.filter(results, &(&1.id == q.id)) |> Enum.sort_by(& &1.trial)
  hits = Enum.count(q_results, & &1.is_correct)

  trial_cells =
    Enum.map(q_results, fn r ->
      marker = if r.is_correct, do: "✓#{r.answer}", else: "✗#{r.answer}"
      "#{marker}"
    end)

  result = if hits >= 2, do: "**PASS**", else: "FAIL"
  IO.puts("| #{q.id} | #{Enum.join(trial_cells, " | ")} | #{q.correct} | #{result} |")
end

# Confidence analysis
avg_conf_correct =
  results
  |> Enum.filter(& &1.is_correct)
  |> Enum.map(& &1[:confidence])
  |> Enum.filter(&is_number/1)
  |> then(fn confs ->
    if length(confs) > 0, do: Float.round(Enum.sum(confs) / length(confs), 3), else: 0.0
  end)

avg_conf_wrong =
  results
  |> Enum.reject(& &1.is_correct)
  |> Enum.map(& &1[:confidence])
  |> Enum.filter(&is_number/1)
  |> then(fn confs ->
    if length(confs) > 0, do: Float.round(Enum.sum(confs) / length(confs), 3), else: 0.0
  end)

IO.puts("\nConfidence analysis:")
IO.puts("  Avg confidence when correct: #{avg_conf_correct}")
IO.puts("  Avg confidence when wrong:   #{avg_conf_wrong}")

# Gate decision
IO.puts("\n========== GATE DECISION ==========")

cond do
  pct >= 40.0 ->
    IO.puts("🟢 GREEN (#{pct}% >= 40%) — phi3 has medical signal. Proceed to 6B.")

  pct >= 25.0 ->
    IO.puts("🟡 YELLOW (#{pct}% in 25-39%) — proceed with caution. Ensemble may not save this.")

  true ->
    IO.puts("🔴 RED (#{pct}% < 25%) — models lack domain knowledge. Pivot A: document the boundary.")
end

# Save trace
trace_dir = "priv/benchmark_traces/phase6a"
File.mkdir_p!(trace_dir)

trace = %{
  phase: "6A",
  method: "solo_logprobs_mc_medqa_feasibility",
  model: model,
  questions: length(sample_20),
  trials: trials,
  total_calls: total_calls,
  elapsed_ms: elapsed_ms,
  per_question_accuracy: "#{per_question_correct}/#{per_question_total}",
  accuracy_pct: pct,
  results:
    Enum.map(results, fn r ->
      %{
        id: r.id,
        trial: r.trial,
        answer: r.answer,
        correct: r.correct,
        is_correct: r.is_correct,
        probabilities: r[:probabilities],
        confidence: r[:confidence]
      }
    end)
}

trace_path = Path.join(trace_dir, "phase6a-phi3-feasibility.json")
File.write!(trace_path, Jason.encode!(trace, pretty: true))
IO.puts("\nTrace saved: #{trace_path}")
IO.puts("========== PHASE 6A COMPLETE ==========")
