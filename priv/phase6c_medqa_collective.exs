# Phase 6C: MedQA Collective Runs — Three Panel Configurations
#
# Tests whether the gotcha-validated ensemble architecture transfers to
# domain-knowledge retrieval (MedQA USMLE). Three panels on the same 100
# questions from 6B, constrained MC with logprobs, no viewpoints.
#
# Panels:
#   gotcha_curated_6 — the 5L panel (phi3, stablelm2, granite, qwen2.5, tinydolphin, tinyllama)
#   power_7          — curated 6 + falcon3 (5L gotcha record holder at 66.7%)
#   medqa_informed   — phi3, granite, falcon3, qwen2.5, llama3.2
#                      (top-2 genuine knowers + 3 diversifiers, built from 6B data)
#
# Key questions:
#   - Does Conf-Wt beat majority on MedQA?
#   - Does the MedQA-informed panel beat the gotcha-curated panel?
#   - Is the ensemble delta concentrated on phi3/granite disagreements?
#   - Does llama3.2's A-bias poison the collective?
#
# Gate: Collective > best solo (53%) by >= 5pp → GREEN
#       Collective ~= best solo (within 3pp) → YELLOW
#       Collective < best solo → RED
#
# Run: mix run priv/phase6c_medqa_collective.exs

alias Cortex.Benchmark
alias Cortex.Benchmark.MedQALoader

configs = [
  %{
    name: "gotcha_curated_6",
    label: "5L gotcha panel (phi3/stablelm2/granite/qwen2.5/td/tinyllama)",
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
    label: "5L power panel (curated 6 + falcon3)",
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
    name: "medqa_informed",
    label: "MedQA-informed (phi3/granite/falcon3/qwen2.5/llama3.2)",
    worker_adapter_configs: [
      "phi3:mini",
      "granite3.1-moe:3b",
      "falcon3:3b",
      "qwen2.5:3b",
      "llama3.2:3b"
    ],
    workers: 5
  }
]

questions = MedQALoader.sample(100)
trials = 1
start_run = 652

total_calls =
  configs
  |> Enum.map(fn c -> c.workers * length(questions) * trials end)
  |> Enum.sum()

IO.puts("========== PHASE 6C: MedQA COLLECTIVE RUNS ==========")
IO.puts("#{length(configs)} panels × #{length(questions)} questions × #{trials} trial = #{length(configs) * length(questions) * trials} runs (#{total_calls} Ollama calls)")
IO.puts("No viewpoints — logprobs mode, model diversity only")
IO.puts("Best solo baseline: phi3:mini 53% (6B)\n")

for config <- configs do
  IO.puts("  #{config.name} (#{config.workers}w): #{Enum.join(config.worker_adapter_configs, ", ")}")
end

IO.puts("")

labels =
  for config <- configs,
      q <- questions,
      trial <- 1..trials,
      do: {config, q, trial}

t_start = System.monotonic_time(:millisecond)

all_results =
  Enum.map(Enum.with_index(labels, start_run), fn {{config, q, trial}, run_num} ->
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"

    IO.puts("---------- #{run_id} #{q.id}-T#{trial} [#{config.name}] ----------")

    opts = [
      test_id: q.id,
      mc_prompt: "#{q.mc_prompt}\nAnswer:",
      choices: q.choices,
      workers: config.workers,
      viewpoints: :none,
      worker_adapter_configs: config.worker_adapter_configs
    ]

    result = Benchmark.run_constrained(q.question, opts)

    correct = q.correct
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

IO.puts("\n\n========== PHASE 6C MedQA COLLECTIVE RESULTS ==========\n")
IO.puts("Best solo baseline: phi3:mini 53/100 (53%)\n")

for config <- configs do
  config_results = Enum.filter(all_results, &(&1.config_name == config.name))

  total_maj = Enum.count(config_results, & &1.majority_correct)
  total_wt = Enum.count(config_results, & &1.weighted_correct)
  n = length(config_results)
  pct_maj = Float.round(total_maj / n * 100, 1)
  pct_wt = Float.round(total_wt / n * 100, 1)

  IO.puts("--- #{config.label} ---")
  IO.puts("  Majority: #{total_maj}/#{n} (#{pct_maj}%)")
  IO.puts("  Weighted: #{total_wt}/#{n} (#{pct_wt}%)")
  IO.puts("  Delta vs best solo (53%): majority #{if total_maj >= 53, do: "+", else: ""}#{total_maj - 53}pp, weighted #{if total_wt >= 53, do: "+", else: ""}#{total_wt - 53}pp")
  IO.puts("")
end

# --- Cross-panel comparison ---

IO.puts("--- CROSS-PANEL COMPARISON ---")
IO.puts("| Panel | Workers | Majority | Weighted | Maj Δ solo | Wt Δ solo |")
IO.puts("| --- | --- | --- | --- | --- | --- |")

for config <- configs do
  cr = Enum.filter(all_results, &(&1.config_name == config.name))
  n = length(cr)
  maj = Enum.count(cr, & &1.majority_correct)
  wt = Enum.count(cr, & &1.weighted_correct)
  pct_maj = Float.round(maj / n * 100, 1)
  pct_wt = Float.round(wt / n * 100, 1)

  IO.puts("| #{config.name} | #{config.workers} | #{maj}/100 (#{pct_maj}%) | #{wt}/100 (#{pct_wt}%) | #{maj - 53} | #{wt - 53} |")
end

IO.puts("| phi3:mini solo | 1 | 53/100 (53.0%) | — | — | — |")

# --- Where do panels agree/disagree? ---

IO.puts("\n--- PANEL AGREEMENT ANALYSIS ---\n")

for q <- questions do
  panel_results =
    Enum.map(configs, fn config ->
      r = Enum.find(all_results, &(&1.config_name == config.name and &1.test_id == q.id))
      {config.name, r}
    end)

  answers = Enum.map(panel_results, fn {_, r} -> {r.majority_answer, r.weighted_answer} end)
  all_maj_same = answers |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1
  all_wt_same = answers |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 1

  unless all_maj_same and all_wt_same do
    correct = q.correct

    detail =
      panel_results
      |> Enum.map(fn {name, r} ->
        maj_m = if r.majority_correct, do: "✓", else: "✗"
        wt_m = if r.weighted_correct, do: "✓", else: "✗"
        "#{name}:M=#{r.majority_answer}#{maj_m}/W=#{r.weighted_answer}#{wt_m}"
      end)
      |> Enum.join("  ")

    IO.puts("  #{q.id} (correct=#{correct}): #{detail}")
  end
end

# --- Majority vs Weighted comparison ---

IO.puts("\n--- MAJORITY vs WEIGHTED VOTING ---\n")

for config <- configs do
  cr = Enum.filter(all_results, &(&1.config_name == config.name))

  both_right = Enum.count(cr, &(&1.majority_correct and &1.weighted_correct))
  maj_only = Enum.count(cr, &(&1.majority_correct and not &1.weighted_correct))
  wt_only = Enum.count(cr, &(not &1.majority_correct and &1.weighted_correct))
  both_wrong = Enum.count(cr, &(not &1.majority_correct and not &1.weighted_correct))

  IO.puts("  #{config.name}:")
  IO.puts("    Both correct:   #{both_right}")
  IO.puts("    Majority only:  #{maj_only}")
  IO.puts("    Weighted only:  #{wt_only}")
  IO.puts("    Both wrong:     #{both_wrong}")
  IO.puts("")
end

# --- llama3.2 A-bias diagnostic (medqa_informed panel) ---

IO.puts("--- LLAMA3.2 A-BIAS DIAGNOSTIC (medqa_informed panel) ---\n")

medqa_results = Enum.filter(all_results, &(&1.config_name == "medqa_informed"))

llama_a_count =
  Enum.count(medqa_results, fn r ->
    llama_worker = Enum.find(r.per_worker, &(&1.model == "llama3.2:3b"))
    llama_worker && llama_worker.answer == "A"
  end)

IO.puts("  llama3.2 selected A on #{llama_a_count}/100 questions")

llama_pulls_wrong =
  Enum.count(medqa_results, fn r ->
    llama_worker = Enum.find(r.per_worker, &(&1.model == "llama3.2:3b"))

    if llama_worker do
      without_llama =
        r.per_worker
        |> Enum.reject(&(&1.model == "llama3.2:3b"))
        |> Enum.group_by(& &1.answer)
        |> Enum.max_by(fn {_, ws} -> length(ws) end)
        |> elem(0)

      without_llama == r.correct_answer and r.majority_answer != r.correct_answer
    else
      false
    end
  end)

IO.puts("  Questions where llama3.2 flipped majority from correct to wrong: #{llama_pulls_wrong}")
IO.puts("")

# --- Gate evaluation ---

IO.puts("========== GATE EVALUATION ==========\n")

best_solo = 53

for config <- configs do
  cr = Enum.filter(all_results, &(&1.config_name == config.name))
  wt = Enum.count(cr, & &1.weighted_correct)
  maj = Enum.count(cr, & &1.majority_correct)
  best_collective = max(wt, maj)
  delta = best_collective - best_solo

  gate =
    cond do
      delta >= 5 -> "GREEN — architecture transfers, proceed to 6D"
      delta >= -3 -> "YELLOW — proceed to 6D but 6E experiments become primary"
      true -> "RED — pivot D (domain-specific curation critical)"
    end

  method = if best_collective == wt, do: "weighted", else: "majority"
  IO.puts("  #{config.name}: best=#{best_collective}% (#{method}), delta=#{if delta >= 0, do: "+"}#{delta}pp → #{gate}")
end

overall_best =
  all_results
  |> Enum.group_by(& &1.config_name)
  |> Enum.map(fn {name, rs} ->
    wt = Enum.count(rs, & &1.weighted_correct)
    maj = Enum.count(rs, & &1.majority_correct)
    {name, max(wt, maj)}
  end)
  |> Enum.max_by(&elem(&1, 1))

{best_panel, best_score} = overall_best
overall_delta = best_score - best_solo

overall_gate =
  cond do
    overall_delta >= 5 -> "GREEN"
    overall_delta >= -3 -> "YELLOW"
    true -> "RED"
  end

IO.puts("\n  OVERALL: best panel = #{best_panel} at #{best_score}%, delta = #{if overall_delta >= 0, do: "+"}#{overall_delta}pp → #{overall_gate}")

# --- Traces ---

trace_dir = "priv/benchmark_traces/phase6c"
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

per_panel_summary =
  Enum.map(configs, fn c ->
    cr = Enum.filter(all_results, &(&1.config_name == c.name))
    n = length(cr)
    maj = Enum.count(cr, & &1.majority_correct)
    wt = Enum.count(cr, & &1.weighted_correct)

    %{
      name: c.name,
      label: c.label,
      models: c.worker_adapter_configs,
      workers: c.workers,
      majority_correct: maj,
      majority_pct: Float.round(maj / n * 100, 1),
      weighted_correct: wt,
      weighted_pct: Float.round(wt / n * 100, 1),
      delta_vs_best_solo_majority: maj - best_solo,
      delta_vs_best_solo_weighted: wt - best_solo
    }
  end)

summary = %{
  phase: "6C",
  method: "logprobs_mc_no_viewpoints_medqa_collective",
  description: "Three panels on 100 MedQA questions — gotcha-curated-6, power-7, MedQA-informed",
  best_solo_baseline: %{model: "phi3:mini", accuracy: best_solo, source: "6B"},
  questions: length(questions),
  trials: trials,
  total_runs: length(all_results),
  total_calls: total_calls,
  elapsed_ms: wall_time,
  panels: per_panel_summary,
  gate: overall_gate,
  collective: collective_summary
}

summary_path = Path.join(trace_dir, "phase6c-collective-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("\n========== PHASE 6C MedQA COLLECTIVE COMPLETE ==========")
IO.puts("#{length(all_results)} collective runs (RUN-#{start_run} – RUN-#{start_run + length(all_results) - 1})")
IO.puts("#{total_calls} total Ollama calls")
IO.puts("Wall time: #{wall_time}ms (#{Float.round(wall_time / 1000, 1)}s)")
IO.puts("Summary: #{summary_path}")
IO.puts("Traces: #{trace_dir}/")
