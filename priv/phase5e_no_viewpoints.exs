# Phase 5E-alpha: No Viewpoints + Logprobs
#
# Hypothesis: Viewpoint prompts damage logprobs scoring (EC-10). Drop viewpoints
# entirely and rely on model diversity alone. Same diverse panel, same MC suite,
# same logprobs extraction — but workers see only the raw question (no system prompt).
#
# Predicted: 8-10/15 diverse. A2 and A3 should recover (models freed from viewpoint
# damage). A4 should hold. A1 remains the ceiling (no model gets it solo).
#
# Two collective configs (same lineup as 5D for direct comparison):
#   Config 1 (homogeneous): tinydolphin × 5
#   Config 2 (diverse): tinydolphin, phi3:mini, gemma2:2b, llama3.2:3b, tinydolphin
#
# Solo baselines: re-run for sanity check (should match 5D at temp=0).
#
# Run: mix run priv/phase5e_no_viewpoints.exs

Code.require_file("priv/benchmark_suite_mc.exs")

alias Cortex.Benchmark
alias Cortex.Benchmark.MCSuite

configs = [
  %{
    name: "homogeneous",
    label: "tinydolphin×5 (no viewpoints)",
    worker_adapter_configs: nil
  },
  %{
    name: "diverse",
    label: "td/phi3/gemma2/llama3.2/td (no viewpoints)",
    worker_adapter_configs: [
      "tinydolphin",
      "phi3:mini",
      "gemma2:2b",
      "llama3.2:3b",
      "tinydolphin"
    ]
  }
]

solo_models = ["tinydolphin", "phi3:mini", "gemma2:2b", "llama3.2:3b"]
trials = 3
start_run = 286

IO.puts("========== PHASE 5E-alpha: NO VIEWPOINTS + LOGPROBS ==========")
IO.puts("Model diversity only — viewpoints removed from collective scoring")
IO.puts("Hypothesis: dropping viewpoints recovers A2/A3, holds A4/A5\n")

# --- Solo baselines via logprobs (sanity check — should match 5D) ---

IO.puts("---------- SOLO BASELINES (logprobs, no viewpoints) ----------\n")

solo_results =
  for model <- solo_models,
      test_id <- MCSuite.test_ids(),
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
          "  #{test_id}-T#{trial} #{model}: #{result.answer} (conf: #{result.confidence}) #{marker}"
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
        IO.puts("  #{test_id}-T#{trial} #{model}: ERROR #{inspect(reason)}")

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

IO.puts("\n--- Solo Summary ---\n")

for model <- solo_models do
  model_results = Enum.filter(solo_results, &(&1.model == model))
  hits = Enum.count(model_results, & &1.is_correct)
  total = length(model_results)

  per_test =
    for test_id <- MCSuite.test_ids() do
      test_results = Enum.filter(model_results, &(&1.test_id == test_id))
      test_hits = Enum.count(test_results, & &1.is_correct)
      "#{test_id}:#{test_hits}/#{length(test_results)}"
    end

  IO.puts("  #{model}: #{hits}/#{total} (#{Enum.join(per_test, " ")})")
end

# --- Collective runs: NO VIEWPOINTS ---

IO.puts("\n---------- COLLECTIVE RUNS (no viewpoints + logprobs + vote) ----------\n")

labels =
  for config <- configs,
      test_id <- MCSuite.test_ids(),
      trial <- 1..trials,
      do: {config, test_id, trial}

all_results =
  Enum.map(Enum.with_index(labels, start_run), fn {{config, test_id, trial}, run_num} ->
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"
    mc = MCSuite.get(test_id)

    IO.puts("---------- #{run_id} #{test_id}-T#{trial} [#{config.name}] ----------")

    opts = [
      test_id: test_id,
      mc_prompt: "#{mc.mc_prompt}\nAnswer:",
      workers: 5,
      viewpoints: :none
    ]

    opts =
      case config.worker_adapter_configs do
        nil -> opts
        wac -> Keyword.put(opts, :worker_adapter_configs, wac)
      end

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
        "#{w.model}=#{w.answer}(#{w.confidence})"
      end)

    IO.puts("  Workers:  #{per_w}")
    IO.puts("  Latency:  #{result.total_latency_ms}ms")

    result
    |> Map.put(:run_id, run_id)
    |> Map.put(:trial, trial)
    |> Map.put(:config_name, config.name)
    |> Map.put(:config_label, config.label)
    |> Map.put(:correct_answer, correct)
    |> Map.put(:majority_correct, maj_correct)
    |> Map.put(:weighted_correct, wt_correct)
  end)

# --- Summary tables ---

IO.puts("\n\n========== PHASE 5E-alpha RESULTS ==========\n")

for config <- configs do
  config_results = Enum.filter(all_results, &(&1.config_name == config.name))

  IO.puts("--- #{config.label} (#{config.name}) ---")

  for test_id <- MCSuite.test_ids() do
    test_results = Enum.filter(config_results, &(&1.test_id == test_id))
    maj_hits = Enum.count(test_results, & &1.majority_correct)
    wt_hits = Enum.count(test_results, & &1.weighted_correct)

    IO.puts("  #{test_id}: majority #{maj_hits}/#{length(test_results)} | weighted #{wt_hits}/#{length(test_results)}")
  end

  total_maj = Enum.count(config_results, & &1.majority_correct)
  total_wt = Enum.count(config_results, & &1.weighted_correct)

  IO.puts(
    "  TOTAL: majority #{total_maj}/#{length(config_results)} | weighted #{total_wt}/#{length(config_results)}"
  )

  IO.puts("")
end

# --- Comparison with 5D ---

IO.puts("--- Phase 5D (with viewpoints, for comparison) ---")
IO.puts("  Homogeneous: 3/15 majority, 3/15 weighted (A5 only)")
IO.puts("  Diverse:     6/15 majority, 3/15 weighted (A4+A5)")
IO.puts("  Solo best: phi3:mini 12/15, gemma2:2b 6/15")
IO.puts("")

# --- Traces ---

trace_dir = "priv/benchmark_traces/phase5e"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-#{result.config_name}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Benchmark.export_trace(result, path: path)
end

solo_summary =
  solo_results
  |> Enum.map(fn r ->
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
            viewpoint: w.viewpoint,
            answer: w.answer,
            confidence: w.confidence,
            probabilities: w.probabilities
          }
        end),
      total_latency_ms: r.total_latency_ms
    }
  end)

summary = %{
  phase: "5E-alpha",
  method: "logprobs_mc_no_viewpoints",
  hypothesis: "Model diversity without viewpoint damage produces better collective accuracy",
  solo: solo_summary,
  collective: collective_summary
}

summary_path = Path.join(trace_dir, "phase5e-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("========== PHASE 5E-alpha COMPLETE ==========")
IO.puts("#{length(all_results)} collective runs (RUN-#{start_run} – RUN-#{start_run + length(all_results) - 1})")
IO.puts("#{length(solo_results)} solo runs")
IO.puts("Summary: #{summary_path}")
IO.puts("Traces: #{trace_dir}/")
