# Phase 6B: MedQA Full Solo Sweep
#
# 10 models × 100 questions × 1 trial = 1,000 calls.
# Trials are deterministic at temp=0 (confirmed in 6A: T1=T2=T3).
# Running 1 trial for the baseline landscape; bump to 3 if variance appears.
#
# Models: 10 (dropped gemma3:4b=gemma2 profile, 3 logprobs-incompatible, deepseek D-spammer)
# Questions: 100-Q fixed sample (seed=42) from MedQA USMLE 4-option test set.
#
# Run: mix run priv/phase6b_medqa_solo_sweep.exs

alias Cortex.Benchmark.MedQALoader

all_models = [
  "tinydolphin",
  "phi3:mini",
  "gemma2:2b",
  "llama3.2:3b",
  "qwen2.5:3b",
  "stablelm2:1.6b",
  "granite3.1-moe:3b",
  "falcon3:3b",
  "smollm2:1.7b",
  "tinyllama"
]

questions = MedQALoader.sample(100)
trials = 1

total_calls = length(all_models) * length(questions) * trials
IO.puts("========== PHASE 6B: MedQA FULL SOLO SWEEP ==========")
IO.puts("#{length(all_models)} models × #{length(questions)} questions × #{trials} trial(s) = #{total_calls} calls")
IO.puts("Models: #{Enum.join(all_models, ", ")}")
IO.puts("Sample: 100-Q (seed=42), #{length(questions)} loaded\n")

t0 = System.monotonic_time(:millisecond)

solo_results =
  for model <- all_models do
    model_t0 = System.monotonic_time(:millisecond)
    IO.puts("========== #{model} ==========\n")

    model_results =
      for q <- questions, trial <- 1..trials do
        prompt = "#{q.mc_prompt}\nAnswer:"
        config = %{model: model}

        case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
          {:ok, result} ->
            correct? = result.answer == q.correct
            marker = if correct?, do: "✓", else: "✗"

            IO.puts(
              "  #{q.id}-T#{trial}: #{result.answer} (conf: #{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]"
            )

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
            IO.puts("  #{q.id}-T#{trial}: ERROR #{inspect(reason)}")

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

    model_elapsed = System.monotonic_time(:millisecond) - model_t0
    hits = Enum.count(model_results, & &1.is_correct)
    total = length(model_results)
    pct = if total > 0, do: Float.round(hits / total * 100, 1), else: 0.0

    IO.puts("\n  >> #{model}: #{hits}/#{total} (#{pct}%) in #{Float.round(model_elapsed / 1000, 1)}s\n")

    model_results
  end
  |> List.flatten()

elapsed_ms = System.monotonic_time(:millisecond) - t0

# === SUMMARY TABLE ===

IO.puts("\n========== PHASE 6B SOLO RESULTS ==========\n")
IO.puts("| Model | Correct | Total | Accuracy | Avg Conf (correct) | Avg Conf (wrong) |")
IO.puts("| --- | --- | --- | --- | --- | --- |")

model_summaries =
  for model <- all_models do
    model_results = Enum.filter(solo_results, &(&1.model == model))
    hits = Enum.count(model_results, & &1.is_correct)
    total = length(model_results)
    pct = if total > 0, do: Float.round(hits / total * 100, 1), else: 0.0

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

    IO.puts("| #{model} | #{hits} | #{total} | **#{pct}%** | #{avg_conf_correct} | #{avg_conf_wrong} |")

    %{model: model, hits: hits, total: total, pct: pct,
      avg_conf_correct: avg_conf_correct, avg_conf_wrong: avg_conf_wrong}
  end

# === LEADERBOARD ===

IO.puts("\n--- Leaderboard ---\n")

model_summaries
|> Enum.sort_by(& &1.pct, :desc)
|> Enum.with_index(1)
|> Enum.each(fn {s, rank} ->
  IO.puts("  #{rank}. #{s.model}: #{s.pct}% (#{s.hits}/#{s.total})")
end)

# === CONFIDENCE CALIBRATION ===

IO.puts("\n--- Confidence Calibration ---\n")

for s <- Enum.sort_by(model_summaries, & &1.pct, :desc) do
  gap = Float.round(s.avg_conf_correct - s.avg_conf_wrong, 3)
  signal = if gap > 0.1, do: "✓ calibrated", else: if(gap > 0, do: "~ weak signal", else: "✗ inverted")
  IO.puts("  #{s.model}: correct=#{s.avg_conf_correct} wrong=#{s.avg_conf_wrong} gap=#{gap} #{signal}")
end

# === PAIRWISE AGREEMENT MATRIX ===

IO.puts("\n--- Pairwise Agreement Matrix ---\n")

question_ids = Enum.map(questions, & &1.id)

model_answers =
  for model <- all_models, into: %{} do
    answers =
      for q_id <- question_ids, into: %{} do
        result = Enum.find(solo_results, &(&1.model == model and &1.id == q_id and &1.trial == 1))
        {q_id, result && result.answer}
      end
    {model, answers}
  end

IO.puts("| Model | #{Enum.join(Enum.map(all_models, &String.slice(&1, 0, 8)), " | ")} |")
IO.puts("| --- | #{Enum.map_join(all_models, " | ", fn _ -> "---" end)} |")

for m1 <- all_models do
  cells =
    for m2 <- all_models do
      if m1 == m2 do
        "-"
      else
        agreements =
          question_ids
          |> Enum.count(fn qid ->
            a1 = model_answers[m1][qid]
            a2 = model_answers[m2][qid]
            a1 != nil and a2 != nil and a1 == a2
          end)

        valid =
          question_ids
          |> Enum.count(fn qid ->
            model_answers[m1][qid] != nil and model_answers[m2][qid] != nil
          end)

        if valid > 0 do
          "#{Float.round(agreements / valid * 100, 0) |> trunc}%"
        else
          "?"
        end
      end
    end

  IO.puts("| #{String.slice(m1, 0, 8)} | #{Enum.join(cells, " | ")} |")
end

# === PER-QUESTION ANALYSIS: find "interesting" questions ===

IO.puts("\n--- Per-Question Analysis: Hardest & Easiest ---\n")

question_stats =
  for q <- questions do
    q_results = Enum.filter(solo_results, &(&1.id == q.id))
    models_correct = Enum.count(q_results, & &1.is_correct)
    models_total = Enum.count(q_results, &(&1.answer != nil))
    correct_models = q_results |> Enum.filter(& &1.is_correct) |> Enum.map(& &1.model)

    %{id: q.id, correct: q.correct, models_correct: models_correct,
      models_total: models_total, correct_models: correct_models}
  end

easiest = question_stats |> Enum.sort_by(& &1.models_correct, :desc) |> Enum.take(10)
hardest = question_stats |> Enum.sort_by(& &1.models_correct, :asc) |> Enum.take(10)

IO.puts("Easiest (most models correct):")
for q <- easiest do
  IO.puts("  #{q.id}: #{q.models_correct}/#{q.models_total} models correct (#{Enum.join(q.correct_models, ", ")})")
end

IO.puts("\nHardest (fewest models correct):")
for q <- hardest do
  IO.puts("  #{q.id}: #{q.models_correct}/#{q.models_total} correct#{if q.models_correct > 0, do: " (#{Enum.join(q.correct_models, ", ")})", else: ""}")
end

# === SECOND-KNOWER / UNIQUE-KNOWER ANALYSIS ===

IO.puts("\n--- Second-Knower / Unique-Knower Detection ---\n")

single_knower_qs =
  question_stats
  |> Enum.filter(&(&1.models_correct == 1))
  |> Enum.sort_by(& &1.id)

IO.puts("Single-knower questions (only 1 model correct): #{length(single_knower_qs)}")
for q <- single_knower_qs do
  IO.puts("  #{q.id}: #{hd(q.correct_models)}")
end

knower_counts =
  single_knower_qs
  |> Enum.map(fn q -> hd(q.correct_models) end)
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_, c} -> -c end)

IO.puts("\nUnique-knower frequency:")
for {model, count} <- knower_counts do
  IO.puts("  #{model}: #{count} unique-knower questions")
end

zero_correct_qs = Enum.filter(question_stats, &(&1.models_correct == 0))
IO.puts("\nQuestions no model got right: #{length(zero_correct_qs)}")
for q <- zero_correct_qs do
  IO.puts("  #{q.id} (correct: #{q.correct})")
end

# === ANSWER DISTRIBUTION ===

IO.puts("\n--- Answer Distribution Bias ---\n")

for model <- all_models do
  model_results = Enum.filter(solo_results, &(&1.model == model))
  dist = model_results |> Enum.map(& &1.answer) |> Enum.frequencies() |> Enum.sort()
  IO.puts("  #{model}: #{inspect(dist)}")
end

IO.puts("\nCorrect answer distribution in sample:")
correct_dist = questions |> Enum.map(& &1.correct) |> Enum.frequencies() |> Enum.sort()
IO.puts("  #{inspect(correct_dist)}")

# === GATE DECISION ===

best = Enum.max_by(model_summaries, & &1.pct)
spread = (Enum.max_by(model_summaries, & &1.pct).pct - Enum.min_by(model_summaries, & &1.pct).pct)

IO.puts("\n========== GATE DECISION ==========")
IO.puts("Best solo: #{best.model} at #{best.pct}%")
IO.puts("Spread (max - min): #{Float.round(spread, 1)}pp")

cond do
  best.pct >= 50.0 ->
    IO.puts("🟢 GREEN (best solo #{best.pct}% >= 50%) — meaningful headroom for ensemble. Proceed to 6C.")
  best.pct >= 35.0 ->
    IO.puts("🟡 YELLOW (best solo #{best.pct}% in 35-49%) — proceed to 6C but expect modest gains. 6E prompt experiments become higher priority.")
  spread <= 5.0 ->
    IO.puts("🟡 PIVOT C (spread #{Float.round(spread, 1)}pp <= 5pp) — high correlation, ensemble won't help. Skip 6C, jump to 6E (prompt diversity).")
  true ->
    IO.puts("🔴 RED (best solo #{best.pct}% < 35%) — models lack domain knowledge. Pivot A/B: document the boundary, prioritize prompt experiments (6E).")
end

# === SAVE TRACES ===

trace_dir = "priv/benchmark_traces/phase6b"
File.mkdir_p!(trace_dir)

summary = %{
  phase: "6B",
  method: "solo_logprobs_mc_medqa_full_sweep",
  description: "10 models × 100 MedQA questions × #{trials} trial(s) solo sweep",
  models: all_models,
  questions: length(questions),
  trials: trials,
  total_calls: total_calls,
  elapsed_ms: elapsed_ms,
  model_summaries: Enum.map(model_summaries, fn s ->
    %{model: s.model, hits: s.hits, total: s.total, pct: s.pct,
      avg_conf_correct: s.avg_conf_correct, avg_conf_wrong: s.avg_conf_wrong}
  end),
  solo: Enum.map(solo_results, fn r ->
    %{
      model: r.model,
      id: r.id,
      trial: r.trial,
      answer: r.answer,
      correct: r.correct,
      is_correct: r.is_correct,
      probabilities: r[:probabilities],
      confidence: r[:confidence]
    }
  end),
  question_stats: Enum.map(question_stats, fn q ->
    %{id: q.id, correct: q.correct, models_correct: q.models_correct,
      models_total: q.models_total, correct_models: q.correct_models}
  end)
}

summary_path = Path.join(trace_dir, "phase6b-solo-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("\n========== PHASE 6B SOLO SWEEP COMPLETE ==========")
IO.puts("#{length(solo_results)} total calls in #{Float.round(elapsed_ms / 1000, 1)}s (#{Float.round(elapsed_ms / 60_000, 1)} min)")
IO.puts("Trace: #{summary_path}")
