# Phase 5L: Panel Recomposition Collective Sweep
#
# Tests new panels incorporating 5K knower discoveries against the full 8-test
# gotcha battery. Same methodology as 5G collective: logprobs scoring, no
# viewpoints, 3 trials per test per panel.
#
# New knowers from 5K:
#   tinyllama — A8 second knower (52.3%), A3 knower, A4 knower
#   falcon3:3b — A7 at 98.9%, A3 knower, A6 knower
#   smollm2:1.7b — A4 second knower (48.7%), A3 knower, A2 knower
#
# Panel designs:
#   Curated 6 = curated 5 + tinyllama (A8 crack attempt)
#   Power 7   = curated 6 + falcon3 (A7 reinforcement)
#   Coverage 8 = power 7 + smollm2 (A4 reinforcement)
#
# Run: mix run priv/phase5l_recomposition.exs

Code.require_file("priv/benchmark_suite_mc.exs")

alias Cortex.Benchmark
alias Cortex.Benchmark.MCSuite

configs = [
  %{
    name: "curated_6",
    label: "curated 5 + tinyllama (6-worker, A8 crack)",
    worker_adapter_configs: [
      "phi3:mini",
      "stablelm2:1.6b",
      "granite3.1-moe:3b",
      "qwen2.5:3b",
      "tinydolphin",
      "tinyllama"
    ],
    workers: 6
  },
  %{
    name: "power_7",
    label: "curated 5 + tinyllama + falcon3 (7-worker, A7+A8)",
    worker_adapter_configs: [
      "phi3:mini",
      "stablelm2:1.6b",
      "granite3.1-moe:3b",
      "qwen2.5:3b",
      "tinydolphin",
      "tinyllama",
      "falcon3:3b"
    ],
    workers: 7
  },
  %{
    name: "coverage_8",
    label: "curated 5 + tinyllama + falcon3 + smollm2 (8-worker, max coverage)",
    worker_adapter_configs: [
      "phi3:mini",
      "stablelm2:1.6b",
      "granite3.1-moe:3b",
      "qwen2.5:3b",
      "tinydolphin",
      "tinyllama",
      "falcon3:3b",
      "smollm2:1.7b"
    ],
    workers: 8
  }
]

all_tests = MCSuite.test_ids()
trials = 3
start_run = 580

total_calls =
  configs
  |> Enum.map(fn c -> c.workers * length(all_tests) * trials end)
  |> Enum.sum()

IO.puts("========== PHASE 5L: PANEL RECOMPOSITION COLLECTIVE SWEEP ==========")
IO.puts("#{length(configs)} panels × #{length(all_tests)} tests × #{trials} trials = #{length(configs) * length(all_tests) * trials} runs (#{total_calls} Ollama calls)")
IO.puts("No viewpoints — logprobs mode, model diversity only\n")

for config <- configs do
  IO.puts("  #{config.name}: #{Enum.join(config.worker_adapter_configs, ", ")}")
end

IO.puts("")

labels =
  for config <- configs,
      test_id <- all_tests,
      trial <- 1..trials,
      do: {config, test_id, trial}

t_start = System.monotonic_time(:millisecond)

all_results =
  Enum.map(Enum.with_index(labels, start_run), fn {{config, test_id, trial}, run_num} ->
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"
    mc = MCSuite.get(test_id)

    IO.puts("---------- #{run_id} #{test_id}-T#{trial} [#{config.name}] ----------")

    opts = [
      test_id: test_id,
      mc_prompt: "#{mc.mc_prompt}\nAnswer:",
      workers: config.workers,
      viewpoints: :none,
      worker_adapter_configs: config.worker_adapter_configs
    ]

    result = Benchmark.run_constrained(mc.question, opts)

    correct = mc.correct
    maj_correct = result.majority_answer == correct
    wt_correct = result.weighted_answer == correct
    maj_mark = if maj_correct, do: "✓", else: "✗"
    wt_mark = if wt_correct, do: "✓", else: "✗"

    IO.puts(
      "  Majority: #{result.majority_answer} (#{result.majority_votes}/#{result.majority_total}) #{maj_mark}"
    )

    IO.puts("  Weighted: #{result.weighted_answer} #{wt_mark}")

    per_w =
      Enum.map_join(result.per_worker, " ", fn w ->
        conf = if is_float(w.confidence), do: Float.round(w.confidence, 3), else: w.confidence
        "#{w.model}=#{w.answer}(#{conf})"
      end)

    IO.puts("  Workers:  #{per_w}")
    IO.puts("  Latency:  #{result.total_latency_ms}ms\n")

    result
    |> Map.put(:run_id, run_id)
    |> Map.put(:trial, trial)
    |> Map.put(:config_name, config.name)
    |> Map.put(:config_label, config.label)
    |> Map.put(:correct_answer, correct)
    |> Map.put(:majority_correct, maj_correct)
    |> Map.put(:weighted_correct, wt_correct)
  end)

wall_time = System.monotonic_time(:millisecond) - t_start

# --- Summary tables ---

IO.puts("\n\n========== PHASE 5L RECOMPOSITION RESULTS ==========\n")

for config <- configs do
  config_results = Enum.filter(all_results, &(&1.config_name == config.name))

  IO.puts("--- #{config.label} ---")
  IO.puts("| Test | Majority | Weighted | Details |")
  IO.puts("| --- | --- | --- | --- |")

  for test_id <- all_tests do
    test_results = Enum.filter(config_results, &(&1.test_id == test_id))
    maj_hits = Enum.count(test_results, & &1.majority_correct)
    wt_hits = Enum.count(test_results, & &1.weighted_correct)

    detail =
      test_results
      |> Enum.map(fn r ->
        maj_m = if r.majority_correct, do: "✓", else: "✗"
        wt_m = if r.weighted_correct, do: "✓", else: "✗"
        "T#{r.trial}:#{r.majority_answer}#{maj_m}/#{r.weighted_answer}#{wt_m}"
      end)
      |> Enum.join(" ")

    IO.puts("| #{test_id} | #{maj_hits}/#{length(test_results)} | #{wt_hits}/#{length(test_results)} | #{detail} |")
  end

  total_maj = Enum.count(config_results, & &1.majority_correct)
  total_wt = Enum.count(config_results, & &1.weighted_correct)
  pct_maj = Float.round(total_maj / length(config_results) * 100, 1)
  pct_wt = Float.round(total_wt / length(config_results) * 100, 1)
  IO.puts("| **TOTAL** | **#{total_maj}/#{length(config_results)} (#{pct_maj}%)** | **#{total_wt}/#{length(config_results)} (#{pct_wt}%)** | |")
  IO.puts("")
end

# --- Cross-panel comparison ---

IO.puts("--- CROSS-PANEL COMPARISON (weighted) ---")
IO.puts("| Test | Curated 6 | Power 7 | Coverage 8 | 5G Curated 5 (ref) |")
IO.puts("| --- | --- | --- | --- | --- |")

for test_id <- all_tests do
  c6 = Enum.filter(all_results, &(&1.config_name == "curated_6" and &1.test_id == test_id))
  p7 = Enum.filter(all_results, &(&1.config_name == "power_7" and &1.test_id == test_id))
  cv8 = Enum.filter(all_results, &(&1.config_name == "coverage_8" and &1.test_id == test_id))

  c6_wt = Enum.count(c6, & &1.weighted_correct)
  p7_wt = Enum.count(p7, & &1.weighted_correct)
  cv8_wt = Enum.count(cv8, & &1.weighted_correct)

  ref = case test_id do
    "A2" -> "3/3"
    "A3" -> "3/3"
    "A5" -> "3/3"
    "A6" -> "3/3"
    "A7" -> "3/3"
    _ -> "0/3"
  end

  IO.puts("| #{test_id} | #{c6_wt}/3 | #{p7_wt}/3 | #{cv8_wt}/3 | #{ref} |")
end

c6_total = Enum.count(all_results, &(&1.config_name == "curated_6" and &1.weighted_correct))
p7_total = Enum.count(all_results, &(&1.config_name == "power_7" and &1.weighted_correct))
cv8_total = Enum.count(all_results, &(&1.config_name == "coverage_8" and &1.weighted_correct))
IO.puts("| **TOTAL** | **#{c6_total}/24** | **#{p7_total}/24** | **#{cv8_total}/24** | **15/24** |")

# --- A8 focus (the whole reason we're here) ---

IO.puts("\n--- A8 (Modified CRT) FOCUS — Did tinyllama crack it? ---\n")

for config <- configs do
  a8_results = Enum.filter(all_results, &(&1.config_name == config.name and &1.test_id == "A8"))

  for r <- a8_results do
    per_w =
      r.per_worker
      |> Enum.map(fn w ->
        p_b = Map.get(w.probabilities, "B", 0.0)
        "#{w.model}=#{w.answer}(P(B)=#{Float.round(p_b, 3)})"
      end)
      |> Enum.join(" ")

    wt_mark = if r.weighted_correct, do: "✓ CRACKED", else: "✗"
    IO.puts("  #{config.name} T#{r.trial}: weighted=#{r.weighted_answer} #{wt_mark}")
    IO.puts("    #{per_w}")
  end

  IO.puts("")
end

# --- Traces ---

trace_dir = "priv/benchmark_traces/phase5l"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-#{result.config_name}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Benchmark.export_trace(result, path: path)
end

collective_summary =
  all_results
  |> Enum.map(fn r ->
    %{
      run_id: r.run_id,
      test_id: r.test_id,
      trial: r.trial,
      config: r.config_name,
      config_label: r.config_label,
      correct_answer: r.correct_answer,
      majority_answer: r.majority_answer,
      majority_votes: r.majority_votes,
      majority_correct: r.majority_correct,
      weighted_answer: r.weighted_answer,
      weighted_correct: r.weighted_correct,
      per_worker:
        Enum.map(r.per_worker, fn w ->
          %{
            model: w.model,
            viewpoint: w[:viewpoint],
            answer: w.answer,
            confidence: w.confidence,
            probabilities: w.probabilities
          }
        end),
      total_latency_ms: r.total_latency_ms
    }
  end)

summary = %{
  phase: "5L",
  method: "logprobs_mc_no_viewpoints_recomposed_panels",
  description: "Panel recomposition with 5K knowers — 3 panels × 8 tests × 3 trials",
  panels: Enum.map(configs, fn c ->
    %{name: c.name, label: c.label, models: c.worker_adapter_configs, workers: c.workers}
  end),
  tests: all_tests,
  collective: collective_summary
}

summary_path = Path.join(trace_dir, "phase5l-recomposition-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("\n========== PHASE 5L RECOMPOSITION COMPLETE ==========")
IO.puts("#{length(all_results)} collective runs (RUN-#{start_run} – RUN-#{start_run + length(all_results) - 1})")
IO.puts("#{total_calls} total Ollama calls")
IO.puts("Wall time: #{wall_time}ms (#{Float.round(wall_time / 1000, 1)}s)")
IO.puts("Summary: #{summary_path}")
IO.puts("Traces: #{trace_dir}/")
