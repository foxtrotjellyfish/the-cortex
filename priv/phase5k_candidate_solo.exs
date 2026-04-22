# Phase 5K: Model Safari Candidate Solo Sweep
#
# Tests new candidate models from the SRC-022 model safari against all 8 gotcha tests.
# Same methodology as 5G: solo logprobs scoring, 3 trials per test, no viewpoints.
#
# Usage: CANDIDATE_MODELS=falcon3:3b mix run priv/phase5k_candidate_solo.exs
#   Or edit the models list below.

Code.require_file("priv/benchmark_suite_mc.exs")

alias Cortex.Benchmark.MCSuite

default_models = System.get_env("CANDIDATE_MODELS", "falcon3:3b")

candidate_models =
  default_models
  |> String.split(",")
  |> Enum.map(&String.trim/1)

all_tests = MCSuite.test_ids()
trials = 3

IO.puts("========== PHASE 5K: MODEL SAFARI CANDIDATE SWEEP ==========")
IO.puts("#{length(candidate_models)} model(s) × #{length(all_tests)} tests × #{trials} trials = #{length(candidate_models) * length(all_tests) * trials} calls")
IO.puts("Candidates: #{Enum.join(candidate_models, ", ")}\n")

solo_results =
  for model <- candidate_models do
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

            probs_str =
              result.probabilities
              |> Enum.sort_by(fn {_k, v} -> -v end)
              |> Enum.map_join(" ", fn {k, v} -> "#{k}:#{Float.round(v * 100, 1)}%" end)

            IO.puts(
              "  #{test_id}-T#{trial}: #{result.answer} (conf: #{Float.round(result.confidence, 3)}) #{marker}  [correct: #{correct}]  {#{probs_str}}"
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

IO.puts("\n========== RESULTS SUMMARY ==========\n")

IO.puts("| Model | #{Enum.join(all_tests, " | ")} | **Total** |")
IO.puts("| --- | #{Enum.map_join(all_tests, " | ", fn _ -> "---" end)} | --- |")

for model <- candidate_models do
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

# --- A1 Focus (the whole reason we're here) ---

IO.puts("\n--- A1 (Car Wash) FOCUS — Second-Knower Hunt ---\n")

for model <- candidate_models do
  mc = MCSuite.get("A1")
  model_a1 = Enum.filter(solo_results, &(&1.model == model and &1.test_id == "A1"))
  hits = Enum.count(model_a1, & &1.is_correct)

  probs =
    model_a1
    |> Enum.map(fn r -> r[:probabilities] || %{} end)

  avg_b = probs |> Enum.map(&Map.get(&1, "B", 0.0)) |> then(fn ps -> Enum.sum(ps) / max(length(ps), 1) end)
  avg_a = probs |> Enum.map(&Map.get(&1, "A", 0.0)) |> then(fn ps -> Enum.sum(ps) / max(length(ps), 1) end)

  marker = cond do
    hits == 3 -> "★★★ SECOND KNOWER FOUND!"
    hits > 0 -> "◆ PARTIAL — worth deeper investigation"
    avg_b > 0.20 -> "◇ SIGNAL (avg B > 20%) — run 10+ trials"
    avg_b > 0.10 -> "△ WEAK SIGNAL (avg B > 10%)"
    true -> "✗ No signal"
  end

  IO.puts("#{model}: #{hits}/3 correct  avg_P(B)=#{Float.round(avg_b, 3)}  avg_P(A)=#{Float.round(avg_a, 3)}  #{marker}")

  for {p, i} <- Enum.with_index(probs, 1) do
    sorted = p |> Enum.sort_by(fn {_k, v} -> -v end) |> Enum.map_join(" ", fn {k, v} -> "#{k}:#{Float.round(v * 100, 1)}%" end)
    IO.puts("  T#{i}: #{sorted}")
  end

  IO.puts("")
end

# --- Second-knower analysis for all tests ---

IO.puts("--- Second-Knower Analysis (all tests) ---\n")

for test_id <- all_tests do
  mc = MCSuite.get(test_id)
  IO.puts("#{test_id} (correct: #{mc.correct}):")

  for model <- candidate_models do
    model_test = Enum.filter(solo_results, &(&1.model == model and &1.test_id == test_id))
    hits = Enum.count(model_test, & &1.is_correct)

    avg_correct_prob =
      model_test
      |> Enum.map(fn r -> Map.get(r[:probabilities] || %{}, mc.correct, 0.0) end)
      |> then(fn ps -> if length(ps) > 0, do: Enum.sum(ps) / length(ps), else: 0.0 end)

    marker = cond do
      hits == 3 -> "★ KNOWER"
      hits > 0 -> "◆ PARTIAL"
      avg_correct_prob > 0.2 -> "◇ SIGNAL (>20%)"
      true -> "  weak"
    end

    IO.puts("  #{model}: #{hits}/#{length(model_test)} avg_P(#{mc.correct})=#{Float.round(avg_correct_prob, 3)} #{marker}")
  end

  IO.puts("")
end

# --- Save traces ---

trace_dir = "priv/benchmark_traces/phase5k"
File.mkdir_p!(trace_dir)

summary = %{
  phase: "5K",
  method: "solo_logprobs_mc_candidate_sweep",
  description: "Model safari candidate sweep — #{length(candidate_models)} models × 8 tests × 3 trials",
  models: candidate_models,
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

timestamp = DateTime.utc_now() |> DateTime.to_iso8601() |> String.replace(~r/[:\.]/, "-")
summary_path = Path.join(trace_dir, "phase5k-#{Enum.join(candidate_models, "_") |> String.replace(":", "-") |> String.replace("/", "-")}-#{timestamp}.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("========== PHASE 5K CANDIDATE SWEEP COMPLETE ==========")
IO.puts("#{length(solo_results)} total calls")
IO.puts("Trace: #{summary_path}")
