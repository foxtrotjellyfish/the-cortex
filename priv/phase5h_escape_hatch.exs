# Phase 5H: Escape Hatch Removal Test
#
# Remove hedging/non-committal MC options from A1, A2, and A4.
# Models must commit to a definitive answer — no "it depends" or
# "cannot be determined." Tests whether hedge options suppress
# latent knowledge or reflect genuine uncertainty.
#
# Modified tests (3 options instead of 4):
#   A1: removed D="It depends on the weather"
#   A2: removed D="She won't look for it"
#   A4: removed D="Cannot be determined"
#
# Unmodified tests (A3, A5, A6, A7, A8) use standard MCSuite prompts
# as control — should produce identical results to 5G at temp=0.
#
# Two panels × 8 tests × 3 trials = 48 collective runs.
#
# Run: mix run priv/phase5h_escape_hatch.exs

Code.require_file("priv/benchmark_suite_mc.exs")

alias Cortex.Benchmark
alias Cortex.Benchmark.MCSuite

# --- Modified MC prompts: hedge options removed ---

modified_prompts = %{
  "A1" => %{
    mc_prompt: """
    Q: I need a car wash. The car wash is 50 meters away. Should I walk?
    A) Yes, it's only 50 meters — just walk there
    B) No, you need to drive your car there to get it washed
    C) Take a taxi instead
    """,
    choices: ~w(A B C)
  },
  "A2" => %{
    mc_prompt: """
    Q: Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?
    A) The basket (where she left it)
    B) The box (where Anne moved it)
    C) She will look in both places
    """,
    choices: ~w(A B C)
  },
  "A4" => %{
    mc_prompt: """
    Q: A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?
    A) Brown
    B) Black
    C) White
    """,
    choices: ~w(A B C)
  }
}

modified_test_ids = Map.keys(modified_prompts) |> Enum.sort()

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
start_run = 364

total_calls =
  configs
  |> Enum.map(fn c -> c.workers * length(all_tests) * trials end)
  |> Enum.sum()

IO.puts("========== PHASE 5H: ESCAPE HATCH REMOVAL TEST ==========")
IO.puts("Modified: #{Enum.join(modified_test_ids, ", ")} (hedge options removed)")
IO.puts("Control: #{Enum.join(all_tests -- modified_test_ids, ", ")} (unchanged from 5G)")
IO.puts("#{length(configs)} panels × #{length(all_tests)} tests × #{trials} trials = #{length(configs) * length(all_tests) * trials} runs (#{total_calls} Ollama calls)")
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

    {prompt, choices, modified?} =
      case Map.get(modified_prompts, test_id) do
        nil ->
          {"#{mc.mc_prompt}\nAnswer:", ~w(A B C D), false}

        override ->
          {"#{override.mc_prompt}\nAnswer:", override.choices, true}
      end

    mod_tag = if modified?, do: " [MODIFIED]", else: " [control]"
    IO.puts("---------- #{run_id} #{test_id}-T#{trial} [#{config.name}]#{mod_tag} ----------")

    opts = [
      test_id: test_id,
      mc_prompt: prompt,
      choices: choices,
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
    |> Map.put(:modified, modified?)
    |> Map.put(:choices, choices)
  end)

wall_time = System.monotonic_time(:millisecond) - t_start

# --- Summary tables ---

IO.puts("\n\n========== PHASE 5H RESULTS ==========\n")

for config <- configs do
  config_results = Enum.filter(all_results, &(&1.config_name == config.name))

  IO.puts("--- #{config.label} ---")
  IO.puts("| Test | Modified? | Majority | Weighted | Worker distributions |")
  IO.puts("| --- | --- | --- | --- | --- |")

  for test_id <- all_tests do
    test_results = Enum.filter(config_results, &(&1.test_id == test_id))
    maj_hits = Enum.count(test_results, & &1.majority_correct)
    wt_hits = Enum.count(test_results, & &1.weighted_correct)

    mod_tag = if hd(test_results).modified, do: "YES", else: "no"

    per_w =
      hd(test_results).per_worker
      |> Enum.map(fn w ->
        conf = if is_float(w.confidence), do: Float.round(w.confidence, 3), else: w.confidence
        "#{w.model}=#{w.answer}(#{conf})"
      end)
      |> Enum.join(" ")

    IO.puts("| #{test_id} | #{mod_tag} | #{maj_hits}/#{length(test_results)} | #{wt_hits}/#{length(test_results)} | #{per_w} |")
  end

  total_maj = Enum.count(config_results, & &1.majority_correct)
  total_wt = Enum.count(config_results, & &1.weighted_correct)
  IO.puts("| **TOTAL** | | **#{total_maj}/#{length(config_results)}** | **#{total_wt}/#{length(config_results)}** | |")
  IO.puts("")
end

# --- Delta analysis: modified tests only ---

IO.puts("\n========== ESCAPE HATCH DELTA (modified tests vs 5G baseline) ==========\n")
IO.puts("5G baseline worker distributions (from collective runs):")
IO.puts("  A1: phi3=A(0.69) stablelm2=B(0.09) granite=A(0.36) qwen=A(1.0) td=A(0.11)")
IO.puts("  A2: phi3=A(0.79) stablelm2=B(0.97) granite=C(0.41) qwen=A(1.0) td=A(0.36)")
IO.puts("  A4: phi3=C(0.33) stablelm2=D(0.63) granite=D(1.0) qwen=D(1.0) td=A(0.52)")
IO.puts("")

for test_id <- modified_test_ids do
  IO.puts("--- #{test_id} (hedge removed) ---")

  for config <- configs do
    test_results = Enum.filter(all_results, &(&1.config_name == config.name and &1.test_id == test_id))

    IO.puts("  #{config.name}:")

    for r <- test_results do
      per_w =
        Enum.map_join(r.per_worker, " ", fn w ->
          probs =
            (w.probabilities || %{})
            |> Enum.sort_by(&elem(&1, 1), :desc)
            |> Enum.map_join(",", fn {k, v} -> "#{k}:#{Float.round(v, 3)}" end)

          "#{w.model}=[#{probs}]"
        end)

      maj_m = if r.majority_correct, do: "✓", else: "✗"
      wt_m = if r.weighted_correct, do: "✓", else: "✗"
      IO.puts("    T#{r.trial}: maj=#{r.majority_answer}#{maj_m} wt=#{r.weighted_answer}#{wt_m} | #{per_w}")
    end
  end

  IO.puts("")
end

# --- Head-to-head: 5H vs 5G ---

IO.puts("========== HEAD-TO-HEAD: 5H vs 5G (all tests) ==========\n")
IO.puts("| Test | Mod? | 5H Cur Maj | 5H Cur Wt | 5G Cur Maj | 5G Cur Wt | Delta |")
IO.puts("| --- | --- | --- | --- | --- | --- | --- |")

baseline_5g = %{
  "A1" => {0, 0}, "A2" => {3, 3}, "A3" => {0, 3}, "A4" => {0, 0},
  "A5" => {3, 3}, "A6" => {3, 3}, "A7" => {0, 3}, "A8" => {0, 0}
}

for test_id <- all_tests do
  c5 = Enum.filter(all_results, &(&1.config_name == "curated_5" and &1.test_id == test_id))
  c5_maj = Enum.count(c5, & &1.majority_correct)
  c5_wt = Enum.count(c5, & &1.weighted_correct)
  {b_maj, b_wt} = Map.fetch!(baseline_5g, test_id)

  mod_tag = if test_id in modified_test_ids, do: "YES", else: "no"
  delta_maj = c5_maj - b_maj
  delta_wt = c5_wt - b_wt
  delta_str = "maj #{if delta_maj >= 0, do: "+"}#{delta_maj}, wt #{if delta_wt >= 0, do: "+"}#{delta_wt}"

  IO.puts("| #{test_id} | #{mod_tag} | #{c5_maj}/3 | #{c5_wt}/3 | #{b_maj}/3 | #{b_wt}/3 | #{delta_str} |")
end

# --- Traces ---

trace_dir = "priv/benchmark_traces/phase5h"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-#{result.config_name}"
  mod = if result.modified, do: "-modified", else: ""
  path = Path.join(trace_dir, "#{result.run_id}-#{label}#{mod}.json")
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
      modified: r.modified,
      choices: r.choices,
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
  phase: "5H",
  method: "escape_hatch_removal",
  description: "Hedge options removed from A1, A2, A4. Models forced to commit.",
  modified_tests: modified_test_ids,
  modifications: %{
    "A1" => "Removed D='It depends on the weather'",
    "A2" => "Removed D='She won't look for it'",
    "A4" => "Removed D='Cannot be determined'"
  },
  panels: Enum.map(configs, fn c ->
    %{name: c.name, label: c.label, models: c.worker_adapter_configs, workers: c.workers}
  end),
  tests: all_tests,
  collective: collective_summary
}

summary_path = Path.join(trace_dir, "phase5h-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("\n========== PHASE 5H COMPLETE ==========")
IO.puts("#{length(all_results)} runs (RUN-#{start_run} – RUN-#{start_run + length(all_results) - 1})")
IO.puts("#{total_calls} total Ollama calls")
IO.puts("Wall time: #{wall_time}ms (#{Float.round(wall_time / 1000, 1)}s)")
IO.puts("Modified tests: #{Enum.join(modified_test_ids, ", ")}")
IO.puts("Summary: #{summary_path}")
IO.puts("Traces: #{trace_dir}/")
