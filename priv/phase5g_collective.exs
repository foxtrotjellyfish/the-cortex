# Phase 5G: Collective Runs — Expanded Matrix
#
# Two panels × 8 tests × 3 trials = 48 collective runs (312 Ollama calls).
# No viewpoints — logprobs mode, model diversity only.
#
# Panel 1 (curated 5-worker): phi3 + stablelm2 + granite + qwen2.5 + tinydolphin
#   Covers 8/8 tests with at least one knower per test.
#
# Panel 2 (full 8-worker): all 8 models from the solo sweep
#   Tests whether more workers helps or hurts (noise floor vs coverage).
#
# Pre-simulation predictions:
#   A7 cracked (PoE 94.7%), A3 flipped (Conf-Wt/MoE with granite as 2nd knower),
#   A8 cracked (PoE/LogOP), A1 still fails (stablelm2 outvoted).
#
# Run: mix run priv/phase5g_collective.exs

Code.require_file("priv/benchmark_suite_mc.exs")

alias Cortex.Benchmark
alias Cortex.Benchmark.MCSuite

configs = [
  %{
    name: "curated_5",
    label: "phi3/stablelm2/granite/qwen2.5/td (5-worker curated)",
    worker_adapter_configs: [
      "phi3:mini",
      "stablelm2:1.6b",
      "granite3.1-moe:3b",
      "qwen2.5:3b",
      "tinydolphin"
    ],
    workers: 5
  },
  %{
    name: "full_8",
    label: "all 8 models (full panel)",
    worker_adapter_configs: [
      "tinydolphin",
      "phi3:mini",
      "gemma2:2b",
      "llama3.2:3b",
      "qwen2.5:3b",
      "stablelm2:1.6b",
      "gemma3:4b",
      "granite3.1-moe:3b"
    ],
    workers: 8
  }
]

all_tests = MCSuite.test_ids()
trials = 3
start_run = 316

total_calls =
  configs
  |> Enum.map(fn c -> c.workers * length(all_tests) * trials end)
  |> Enum.sum()

IO.puts("========== PHASE 5G: COLLECTIVE RUNS — EXPANDED MATRIX ==========")
IO.puts("#{length(configs)} panels × #{length(all_tests)} tests × #{trials} trials = #{length(configs) * length(all_tests) * trials} runs (#{total_calls} Ollama calls)")
IO.puts("No viewpoints — logprobs mode, model diversity only\n")

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

IO.puts("\n\n========== PHASE 5G COLLECTIVE RESULTS ==========\n")

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
  IO.puts("| **TOTAL** | **#{total_maj}/#{length(config_results)}** | **#{total_wt}/#{length(config_results)}** | |")
  IO.puts("")
end

# --- Head-to-head: curated vs full panel ---

IO.puts("--- HEAD-TO-HEAD: Curated 5 vs Full 8 ---")
IO.puts("| Test | Curated Maj | Curated Wt | Full Maj | Full Wt |")
IO.puts("| --- | --- | --- | --- | --- |")

for test_id <- all_tests do
  c5 = Enum.filter(all_results, &(&1.config_name == "curated_5" and &1.test_id == test_id))
  f8 = Enum.filter(all_results, &(&1.config_name == "full_8" and &1.test_id == test_id))

  c5_maj = Enum.count(c5, & &1.majority_correct)
  c5_wt = Enum.count(c5, & &1.weighted_correct)
  f8_maj = Enum.count(f8, & &1.majority_correct)
  f8_wt = Enum.count(f8, & &1.weighted_correct)

  IO.puts("| #{test_id} | #{c5_maj}/3 | #{c5_wt}/3 | #{f8_maj}/3 | #{f8_wt}/3 |")
end

c5_total_maj = Enum.count(all_results, &(&1.config_name == "curated_5" and &1.majority_correct))
c5_total_wt = Enum.count(all_results, &(&1.config_name == "curated_5" and &1.weighted_correct))
f8_total_maj = Enum.count(all_results, &(&1.config_name == "full_8" and &1.majority_correct))
f8_total_wt = Enum.count(all_results, &(&1.config_name == "full_8" and &1.weighted_correct))
IO.puts("| **TOTAL** | **#{c5_total_maj}/24** | **#{c5_total_wt}/24** | **#{f8_total_maj}/24** | **#{f8_total_wt}/24** |")

# --- Pre-simulation check ---

IO.puts("\n--- PRE-SIMULATION VALIDATION ---")

checks = [
  {"A7 cracked? (PoE predicted 94.7%)", "A7"},
  {"A3 flipped? (granite as 2nd knower)", "A3"},
  {"A8 cracked? (PoE/LogOP predicted)", "A8"},
  {"A1 still fails? (stablelm2 outvoted)", "A1"},
  {"A6 strong? (4 knowers)", "A6"}
]

for {label, test_id} <- checks do
  c5 = Enum.filter(all_results, &(&1.config_name == "curated_5" and &1.test_id == test_id))
  f8 = Enum.filter(all_results, &(&1.config_name == "full_8" and &1.test_id == test_id))

  c5_maj = Enum.count(c5, & &1.majority_correct)
  f8_maj = Enum.count(f8, & &1.majority_correct)

  mark = if c5_maj > 0 or f8_maj > 0, do: "✅", else: "❌"
  IO.puts("  #{mark} #{label} — curated: #{c5_maj}/3 maj, full: #{f8_maj}/3 maj")
end

# --- Traces ---

trace_dir = "priv/benchmark_traces/phase5g"
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
  phase: "5G",
  method: "logprobs_mc_no_viewpoints_expanded_matrix",
  description: "Two panels (curated 5, full 8) × 8 tests × 3 trials collective runs",
  panels: Enum.map(configs, fn c -> %{name: c.name, label: c.label, models: c.worker_adapter_configs, workers: c.workers} end),
  tests: all_tests,
  collective: collective_summary
}

summary_path = Path.join(trace_dir, "phase5g-collective-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("\n========== PHASE 5G COLLECTIVE COMPLETE ==========")
IO.puts("#{length(all_results)} collective runs (RUN-#{start_run} – RUN-#{start_run + length(all_results) - 1})")
IO.puts("#{total_calls} total Ollama calls")
IO.puts("Wall time: #{wall_time}ms (#{Float.round(wall_time / 1000, 1)}s)")
IO.puts("Summary: #{summary_path}")
IO.puts("Traces: #{trace_dir}/")
