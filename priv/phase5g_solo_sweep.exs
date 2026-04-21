# Phase 5G: Expanded Matrix Solo Sweep
#
# 8 models × 8 tests × 3 trials = 192 solo logprobs calls.
# No collective runs — solo baselines only. Establishes the knowledge map
# for the expanded panel before collective experiments.
#
# New models: qwen2.5:3b, stablelm2:1.6b, gemma3:4b, granite3.1-moe:3b
# New tests: A6 (Moses Illusion), A7 (Invalid Syllogism), A8 (Modified CRT)
#
# Run: mix run priv/phase5g_solo_sweep.exs

Code.require_file("priv/benchmark_suite_mc.exs")

alias Cortex.Benchmark.MCSuite

all_models = [
  "tinydolphin",
  "phi3:mini",
  "gemma2:2b",
  "llama3.2:3b",
  "qwen2.5:3b",
  "stablelm2:1.6b",
  "gemma3:4b",
  "granite3.1-moe:3b"
]

all_tests = MCSuite.test_ids()
trials = 3

IO.puts("========== PHASE 5G: EXPANDED MATRIX SOLO SWEEP ==========")
IO.puts("#{length(all_models)} models × #{length(all_tests)} tests × #{trials} trials = #{length(all_models) * length(all_tests) * trials} calls")
IO.puts("New models: qwen2.5:3b, stablelm2:1.6b, gemma3:4b, granite3.1-moe:3b")
IO.puts("New tests: A6 (Moses Illusion), A7 (Invalid Syllogism), A8 (Modified CRT)\n")

solo_results =
  for model <- all_models do
    IO.puts("---------- #{model} ----------\n")

    model_results =
      for test_id <- all_tests,
          trial <- 1..trials do
        mc = MCSuite.get(test_id)
        prompt = "#{mc.mc_prompt}\nAnswer:"
        config = %{model: model}

        case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config) do
          {:ok, result} ->
            correct = mc.correct
            is_correct = result.answer == correct
            marker = if is_correct, do: "✓", else: "✗"

            IO.puts(
              "  #{test_id}-T#{trial}: #{result.answer} (conf: #{Float.round(result.confidence, 3)}) #{marker}  [correct: #{correct}]"
            )

            %{
              model: model,
              test_id: test_id,
              trial: trial,
              answer: result.answer,
              correct: correct,
              is_correct: is_correct,
              probabilities: result.probabilities,
              confidence: result.confidence
            }

          {:error, reason} ->
            IO.puts("  #{test_id}-T#{trial}: ERROR #{inspect(reason)}")

            %{
              model: model,
              test_id: test_id,
              trial: trial,
              answer: nil,
              correct: mc.correct,
              is_correct: false,
              error: inspect(reason)
            }
        end
      end

    hits = Enum.count(model_results, & &1.is_correct)
    total = length(model_results)

    per_test =
      for test_id <- all_tests do
        test_results = Enum.filter(model_results, &(&1.test_id == test_id))
        test_hits = Enum.count(test_results, & &1.is_correct)
        "#{test_id}:#{test_hits}/#{length(test_results)}"
      end

    IO.puts("\n  >> #{model}: #{hits}/#{total} (#{Enum.join(per_test, " ")})\n")

    model_results
  end
  |> List.flatten()

# --- Summary Table ---

IO.puts("\n========== PHASE 5G SOLO RESULTS ==========\n")

IO.puts("| Model | #{Enum.join(all_tests, " | ")} | **Total** |")
IO.puts("| --- | #{Enum.map_join(all_tests, " | ", fn _ -> "---" end)} | --- |")

for model <- all_models do
  model_results = Enum.filter(solo_results, &(&1.model == model))
  total_hits = Enum.count(model_results, & &1.is_correct)
  total_count = length(model_results)

  per_test =
    for test_id <- all_tests do
      test_results = Enum.filter(model_results, &(&1.test_id == test_id))
      test_hits = Enum.count(test_results, & &1.is_correct)
      "#{test_hits}/#{length(test_results)}"
    end

  IO.puts("| #{model} | #{Enum.join(per_test, " | ")} | **#{total_hits}/#{total_count}** |")
end

# --- Per-test breakdown ---

IO.puts("\n--- Per-Test Model Rankings ---\n")

for test_id <- all_tests do
  mc = MCSuite.get(test_id)
  IO.puts("#{test_id} (correct: #{mc.correct}):")

  test_results = Enum.filter(solo_results, &(&1.test_id == test_id))

  for model <- all_models do
    model_test = Enum.filter(test_results, &(&1.model == model))
    hits = Enum.count(model_test, & &1.is_correct)

    avg_correct_prob =
      model_test
      |> Enum.map(fn r ->
        Map.get(r[:probabilities] || %{}, mc.correct, 0.0)
      end)
      |> then(fn probs ->
        if length(probs) > 0, do: Enum.sum(probs) / length(probs), else: 0.0
      end)

    IO.puts("  #{model}: #{hits}/#{length(model_test)} (avg P(#{mc.correct})=#{Float.round(avg_correct_prob, 3)})")
  end

  IO.puts("")
end

# --- Key metric: second-knower detection ---

IO.puts("--- Second-Knower Analysis (A3/A4 focus) ---\n")

for test_id <- ["A3", "A4", "A6", "A7", "A8"] do
  mc = MCSuite.get(test_id)
  IO.puts("#{test_id} (correct: #{mc.correct}):")

  test_results = Enum.filter(solo_results, &(&1.test_id == test_id))

  for model <- all_models do
    model_test = Enum.filter(test_results, &(&1.model == model))
    hits = Enum.count(model_test, & &1.is_correct)

    probs =
      model_test
      |> Enum.map(fn r ->
        Map.get(r[:probabilities] || %{}, mc.correct, 0.0)
      end)

    avg_p = if length(probs) > 0, do: Enum.sum(probs) / length(probs), else: 0.0
    marker = cond do
      hits == 3 -> "★ KNOWER"
      hits > 0 -> "◆ PARTIAL"
      avg_p > 0.2 -> "◇ SIGNAL (>20%)"
      true -> "  weak"
    end

    IO.puts("  #{model}: #{hits}/#{length(model_test)} avg_P=#{Float.round(avg_p, 3)} #{marker}")
  end

  IO.puts("")
end

# --- Traces ---

trace_dir = "priv/benchmark_traces/phase5g"
File.mkdir_p!(trace_dir)

summary = %{
  phase: "5G",
  method: "solo_logprobs_mc_expanded_matrix",
  description: "8 models × 8 tests × 3 trials solo sweep",
  models: all_models,
  tests: all_tests,
  solo: Enum.map(solo_results, fn r ->
    %{
      model: r.model,
      test_id: r.test_id,
      trial: r.trial,
      answer: r.answer,
      correct: r.correct,
      is_correct: r.is_correct,
      probabilities: r[:probabilities],
      confidence: r[:confidence]
    }
  end)
}

summary_path = Path.join(trace_dir, "phase5g-solo-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("========== PHASE 5G SOLO SWEEP COMPLETE ==========")
IO.puts("#{length(solo_results)} total calls")
IO.puts("Summary: #{summary_path}")
