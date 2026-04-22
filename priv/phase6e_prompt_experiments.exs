# Phase 6E: Prompt Experiments
#
# Three experiments testing prompt strategy on MedQA (same 100-Q seed=42 sample):
#
# Exp 1 — Stripped Context: Remove clinical vignettes, keep only the final
#   question sentence + options. phi3 + granite = 200 calls.
#
# Exp 2 — Viewpoints: Solo viewpoint prompts (CHECK_ASSUMPTIONS, ARGUE_AGAINST)
#   on phi3 + granite. Tests whether EC-15 holds on domain knowledge. 400 calls.
#
# Exp 3 — Medical Persona: System prompt priming on phi3. 100 calls.
#
# Baselines from 6B: phi3 53/100, granite 50/100 (no system prompt, full context).
#
# Run: mix run priv/phase6e_prompt_experiments.exs

alias Cortex.Benchmark.MedQALoader

questions = MedQALoader.sample(100)

baselines = %{
  "phi3:mini" => 53,
  "granite3.1-moe:3b" => 50
}

trace_dir = "priv/benchmark_traces/phase6e"
File.mkdir_p!(trace_dir)

# ============================================================
# EXPERIMENT 1: STRIPPED CONTEXT
# ============================================================

IO.puts("=" |> String.duplicate(70))
IO.puts("  EXPERIMENT 1: STRIPPED CONTEXT")
IO.puts("  Remove clinical vignettes, keep only final question + options")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

strip_question = fn question_text ->
  parts = String.split(question_text, "?")

  case length(parts) do
    1 ->
      question_text

    _ ->
      before_last_qmark = Enum.at(parts, -2) |> String.trim()

      sentences =
        before_last_qmark
        |> String.replace(~r/\n+/, " ")
        |> String.split(~r/(?<=[.!])\s+/)

      last_sentence = List.last(sentences) |> String.trim()
      last_sentence <> "?"
  end
end

stripped_questions =
  Enum.map(questions, fn q ->
    stripped_text = strip_question.(q.question)

    sorted_keys = q.choices |> Enum.sort()

    mc_lines =
      Enum.map(sorted_keys, fn key ->
        "#{key}) #{q.options[key]}"
      end)

    stripped_mc_prompt = "Q: #{stripped_text}\n#{Enum.join(mc_lines, "\n")}"

    %{q | question: stripped_text, mc_prompt: stripped_mc_prompt}
  end)

IO.puts("Sample stripped question:")
sample = hd(stripped_questions)
IO.puts("  ORIGINAL: #{hd(questions).question |> String.slice(0, 120)}...")
IO.puts("  STRIPPED: #{sample.question}")
IO.puts("")

char_reduction =
  Enum.zip(questions, stripped_questions)
  |> Enum.map(fn {orig, stripped} ->
    1.0 - String.length(stripped.question) / max(String.length(orig.question), 1)
  end)

avg_reduction = Enum.sum(char_reduction) / length(char_reduction) * 100
IO.puts("Avg character reduction: #{Float.round(avg_reduction, 1)}%")
IO.puts("")

exp1_models = ["phi3:mini", "granite3.1-moe:3b"]
exp1_total = length(exp1_models) * length(stripped_questions)
IO.puts("#{length(exp1_models)} models x #{length(stripped_questions)} questions = #{exp1_total} calls\n")

t0_exp1 = System.monotonic_time(:millisecond)

exp1_results =
  for model <- exp1_models do
    model_t0 = System.monotonic_time(:millisecond)
    IO.puts("--- #{model} (stripped) ---\n")

    model_results =
      for q <- stripped_questions do
        prompt = "#{q.mc_prompt}\nAnswer:"
        config = %{model: model}

        case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
          {:ok, result} ->
            correct? = result.answer == q.correct
            marker = if correct?, do: "✓", else: "✗"

            IO.puts(
              "  #{q.id}: #{result.answer} (#{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]"
            )

            %{
              model: model,
              experiment: "stripped_context",
              id: q.id,
              answer: result.answer,
              correct: q.correct,
              is_correct: correct?,
              probabilities: result.probabilities,
              confidence: result.confidence,
              stripped_question: q.question
            }

          {:error, reason} ->
            IO.puts("  #{q.id}: ERROR #{inspect(reason)}")

            %{
              model: model,
              experiment: "stripped_context",
              id: q.id,
              answer: nil,
              correct: q.correct,
              is_correct: false,
              error: inspect(reason)
            }
        end
      end

    model_ms = System.monotonic_time(:millisecond) - model_t0
    hits = Enum.count(model_results, & &1.is_correct)
    pct = Float.round(hits / length(model_results) * 100, 1)
    base = baselines[model]
    delta = Float.round(pct - base, 1)

    IO.puts("\n  >> #{model} stripped: #{hits}/#{length(model_results)} (#{pct}%) | baseline: #{base}% | delta: #{if delta >= 0, do: "+"}#{delta}pp | #{Float.round(model_ms / 1000, 1)}s\n")

    model_results
  end
  |> List.flatten()

exp1_ms = System.monotonic_time(:millisecond) - t0_exp1

IO.puts("\n--- EXPERIMENT 1 SUMMARY ---\n")
IO.puts("| Model | Baseline | Stripped | Delta | Interpretation |")
IO.puts("| --- | --- | --- | --- | --- |")

exp1_summaries =
  for model <- exp1_models do
    results = Enum.filter(exp1_results, &(&1.model == model))
    hits = Enum.count(results, & &1.is_correct)
    total = length(results)
    pct = Float.round(hits / total * 100, 1)
    base = baselines[model]
    delta = Float.round(pct - base, 1)

    interp =
      cond do
        abs(delta) <= 3.0 -> "PATTERN-MATCHING (vignettes ≈ irrelevant)"
        delta < -3.0 -> "VIGNETTES CARRY SIGNAL (#{abs(delta)}pp drop)"
        delta > 3.0 -> "VIGNETTES HURT (+#{delta}pp without them)"
      end

    IO.puts("| #{model} | #{base}% | #{pct}% | #{if delta >= 0, do: "+"}#{delta}pp | #{interp} |")

    %{model: model, baseline: base, stripped: pct, delta: delta, hits: hits, total: total}
  end

# Per-question flip analysis: which questions changed correctness?
IO.puts("\n--- Per-Question Flip Analysis (phi3) ---\n")

phi3_stripped = Enum.filter(exp1_results, &(&1.model == "phi3:mini"))

# Load 6B baseline for per-question comparison
baseline_trace_path = "priv/benchmark_traces/phase6b/phase6b-solo-summary.json"

per_q_flips =
  if File.exists?(baseline_trace_path) do
    baseline_data = baseline_trace_path |> File.read!() |> Jason.decode!()
    phi3_baseline_map =
      baseline_data["solo"]
      |> Enum.filter(&(&1["model"] == "phi3:mini" && &1["trial"] == 1))
      |> Enum.into(%{}, fn r -> {r["id"], r["is_correct"]} end)

    gained =
      phi3_stripped
      |> Enum.filter(fn r -> r.is_correct and not (phi3_baseline_map[r.id] || false) end)

    lost =
      phi3_stripped
      |> Enum.filter(fn r -> not r.is_correct and (phi3_baseline_map[r.id] || false) end)

    IO.puts("  phi3 gained (wrong→right with stripping): #{length(gained)}")
    for r <- Enum.take(gained, 10), do: IO.puts("    #{r.id}: now #{r.answer} ✓")

    IO.puts("  phi3 lost (right→wrong with stripping): #{length(lost)}")
    for r <- Enum.take(lost, 10), do: IO.puts("    #{r.id}: now #{r.answer} ✗ [correct: #{r.correct}]")

    %{gained: length(gained), lost: length(lost)}
  else
    IO.puts("  (6B trace not found for per-question comparison)")
    %{gained: nil, lost: nil}
  end

# Save Exp 1 trace
exp1_trace = %{
  phase: "6E",
  experiment: "stripped_context",
  description: "Remove clinical vignettes, keep only final question sentence + options",
  models: exp1_models,
  questions: length(questions),
  avg_char_reduction_pct: Float.round(avg_reduction, 1),
  elapsed_ms: exp1_ms,
  summaries: exp1_summaries,
  per_question_flips: per_q_flips,
  results: Enum.map(exp1_results, fn r ->
    Map.take(r, [:model, :experiment, :id, :answer, :correct, :is_correct, :probabilities, :confidence, :stripped_question])
  end)
}

File.write!(Path.join(trace_dir, "exp1-stripped-context.json"), Jason.encode!(exp1_trace, pretty: true))
IO.puts("\nExp 1 trace saved. #{length(exp1_results)} calls in #{Float.round(exp1_ms / 1000, 1)}s\n")


# ============================================================
# EXPERIMENT 2: VIEWPOINTS (CHECK_ASSUMPTIONS + ARGUE_AGAINST)
# ============================================================

IO.puts("=" |> String.duplicate(70))
IO.puts("  EXPERIMENT 2: VIEWPOINTS ON MedQA")
IO.puts("  EC-15 predicts viewpoints hurt on factual recall. Testing.")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

viewpoint_configs = [
  {"CHECK_ASSUMPTIONS",
   "You CHECK ASSUMPTIONS in the question. Are there hidden premises, tricks, or ambiguities?"},
  {"ARGUE_AGAINST",
   "You argue AGAINST the most obvious answer. Find flaws, edge cases, and alternatives."}
]

exp2_models = ["phi3:mini", "granite3.1-moe:3b"]
exp2_total = length(exp2_models) * length(viewpoint_configs) * length(questions)
IO.puts("#{length(exp2_models)} models x #{length(viewpoint_configs)} viewpoints x #{length(questions)} questions = #{exp2_total} calls\n")

t0_exp2 = System.monotonic_time(:millisecond)

exp2_results =
  for model <- exp2_models, {vp_label, vp_prompt} <- viewpoint_configs do
    model_t0 = System.monotonic_time(:millisecond)
    IO.puts("--- #{model} / #{vp_label} ---\n")

    vp_results =
      for q <- questions do
        prompt = "#{q.mc_prompt}\nAnswer:"
        config = %{model: model, system: vp_prompt}

        case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
          {:ok, result} ->
            correct? = result.answer == q.correct
            marker = if correct?, do: "✓", else: "✗"

            IO.puts(
              "  #{q.id}: #{result.answer} (#{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]"
            )

            %{
              model: model,
              experiment: "viewpoint_#{String.downcase(vp_label)}",
              viewpoint: vp_label,
              id: q.id,
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
              experiment: "viewpoint_#{String.downcase(vp_label)}",
              viewpoint: vp_label,
              id: q.id,
              answer: nil,
              correct: q.correct,
              is_correct: false,
              error: inspect(reason)
            }
        end
      end

    vp_ms = System.monotonic_time(:millisecond) - model_t0
    hits = Enum.count(vp_results, & &1.is_correct)
    pct = Float.round(hits / length(vp_results) * 100, 1)
    base = baselines[model]
    delta = Float.round(pct - base, 1)

    IO.puts("\n  >> #{model}/#{vp_label}: #{hits}/#{length(vp_results)} (#{pct}%) | baseline: #{base}% | delta: #{if delta >= 0, do: "+"}#{delta}pp | #{Float.round(vp_ms / 1000, 1)}s\n")

    vp_results
  end
  |> List.flatten()

exp2_ms = System.monotonic_time(:millisecond) - t0_exp2

IO.puts("\n--- EXPERIMENT 2 SUMMARY ---\n")
IO.puts("| Model | Viewpoint | Accuracy | Baseline | Delta | EC-15 holds? |")
IO.puts("| --- | --- | --- | --- | --- | --- |")

exp2_summaries =
  for model <- exp2_models, {vp_label, _} <- viewpoint_configs do
    results = Enum.filter(exp2_results, &(&1.model == model and &1.viewpoint == vp_label))
    hits = Enum.count(results, & &1.is_correct)
    total = length(results)
    pct = Float.round(hits / total * 100, 1)
    base = baselines[model]
    delta = Float.round(pct - base, 1)

    ec15 =
      cond do
        delta < -2.0 -> "YES (viewpoints hurt: #{delta}pp)"
        delta > 2.0 -> "NO (viewpoints help: +#{delta}pp)"
        true -> "NEUTRAL (within ±2pp)"
      end

    IO.puts("| #{model} | #{vp_label} | #{pct}% | #{base}% | #{if delta >= 0, do: "+"}#{delta}pp | #{ec15} |")

    %{model: model, viewpoint: vp_label, accuracy: pct, baseline: base, delta: delta, hits: hits, total: total}
  end

# Save Exp 2 trace
exp2_trace = %{
  phase: "6E",
  experiment: "viewpoints",
  description: "CHECK_ASSUMPTIONS + ARGUE_AGAINST viewpoint system prompts on MedQA",
  viewpoints: Enum.map(viewpoint_configs, fn {l, p} -> %{label: l, prompt: p} end),
  models: exp2_models,
  questions: length(questions),
  elapsed_ms: exp2_ms,
  summaries: exp2_summaries,
  results: Enum.map(exp2_results, fn r ->
    Map.take(r, [:model, :experiment, :viewpoint, :id, :answer, :correct, :is_correct, :probabilities, :confidence])
  end)
}

File.write!(Path.join(trace_dir, "exp2-viewpoints.json"), Jason.encode!(exp2_trace, pretty: true))
IO.puts("\nExp 2 trace saved. #{length(exp2_results)} calls in #{Float.round(exp2_ms / 1000, 1)}s\n")


# ============================================================
# EXPERIMENT 3: MEDICAL PERSONA
# ============================================================

IO.puts("=" |> String.duplicate(70))
IO.puts("  EXPERIMENT 3: MEDICAL PERSONA")
IO.puts("  System prompt: physician taking USMLE Step 1")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

persona_prompt = "You are a physician taking the USMLE Step 1 exam. Choose the single best answer."
exp3_models = ["phi3:mini"]
exp3_total = length(exp3_models) * length(questions)
IO.puts("#{length(exp3_models)} model x #{length(questions)} questions = #{exp3_total} calls\n")

t0_exp3 = System.monotonic_time(:millisecond)

exp3_results =
  for model <- exp3_models do
    model_t0 = System.monotonic_time(:millisecond)
    IO.puts("--- #{model} (persona) ---\n")

    model_results =
      for q <- questions do
        prompt = "#{q.mc_prompt}\nAnswer:"
        config = %{model: model, system: persona_prompt}

        case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
          {:ok, result} ->
            correct? = result.answer == q.correct
            marker = if correct?, do: "✓", else: "✗"

            IO.puts(
              "  #{q.id}: #{result.answer} (#{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]"
            )

            %{
              model: model,
              experiment: "medical_persona",
              id: q.id,
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
              experiment: "medical_persona",
              id: q.id,
              answer: nil,
              correct: q.correct,
              is_correct: false,
              error: inspect(reason)
            }
        end
      end

    model_ms = System.monotonic_time(:millisecond) - model_t0
    hits = Enum.count(model_results, & &1.is_correct)
    pct = Float.round(hits / length(model_results) * 100, 1)
    base = baselines[model]
    delta = Float.round(pct - base, 1)

    IO.puts("\n  >> #{model} persona: #{hits}/#{length(model_results)} (#{pct}%) | baseline: #{base}% | delta: #{if delta >= 0, do: "+"}#{delta}pp | #{Float.round(model_ms / 1000, 1)}s\n")

    model_results
  end
  |> List.flatten()

exp3_ms = System.monotonic_time(:millisecond) - t0_exp3

IO.puts("\n--- EXPERIMENT 3 SUMMARY ---\n")
IO.puts("| Model | Persona | Baseline | Delta | Verdict |")
IO.puts("| --- | --- | --- | --- | --- |")

exp3_summaries =
  for model <- exp3_models do
    results = Enum.filter(exp3_results, &(&1.model == model))
    hits = Enum.count(results, & &1.is_correct)
    total = length(results)
    pct = Float.round(hits / total * 100, 1)
    base = baselines[model]
    delta = Float.round(pct - base, 1)

    verdict =
      cond do
        delta >= 5.0 -> "PERSONA HELPS (+#{delta}pp)"
        delta <= -5.0 -> "PERSONA HURTS (#{delta}pp)"
        delta > 0 -> "SLIGHT POSITIVE (+#{delta}pp, within noise)"
        delta < 0 -> "SLIGHT NEGATIVE (#{delta}pp, within noise)"
        true -> "NO EFFECT"
      end

    IO.puts("| #{model} | #{pct}% | #{base}% | #{if delta >= 0, do: "+"}#{delta}pp | #{verdict} |")

    %{model: model, persona: pct, baseline: base, delta: delta, hits: hits, total: total}
  end

# Save Exp 3 trace
exp3_trace = %{
  phase: "6E",
  experiment: "medical_persona",
  description: "System prompt: '#{persona_prompt}' on phi3:mini",
  persona_prompt: persona_prompt,
  models: exp3_models,
  questions: length(questions),
  elapsed_ms: exp3_ms,
  summaries: exp3_summaries,
  results: Enum.map(exp3_results, fn r ->
    Map.take(r, [:model, :experiment, :id, :answer, :correct, :is_correct, :probabilities, :confidence])
  end)
}

File.write!(Path.join(trace_dir, "exp3-medical-persona.json"), Jason.encode!(exp3_trace, pretty: true))
IO.puts("\nExp 3 trace saved. #{length(exp3_results)} calls in #{Float.round(exp3_ms / 1000, 1)}s\n")


# ============================================================
# GRAND SUMMARY
# ============================================================

total_ms = exp1_ms + exp2_ms + exp3_ms
total_calls = length(exp1_results) + length(exp2_results) + length(exp3_results)

IO.puts("=" |> String.duplicate(70))
IO.puts("  PHASE 6E GRAND SUMMARY")
IO.puts("=" |> String.duplicate(70))
IO.puts("")
IO.puts("| Experiment | Condition | Model | Accuracy | Baseline | Delta |")
IO.puts("| --- | --- | --- | --- | --- | --- |")

for s <- exp1_summaries do
  IO.puts("| Stripped Context | no vignette | #{s.model} | #{s.stripped}% | #{s.baseline}% | #{if s.delta >= 0, do: "+"}#{s.delta}pp |")
end

for s <- exp2_summaries do
  IO.puts("| Viewpoints | #{s.viewpoint} | #{s.model} | #{s.accuracy}% | #{s.baseline}% | #{if s.delta >= 0, do: "+"}#{s.delta}pp |")
end

for s <- exp3_summaries do
  IO.puts("| Medical Persona | USMLE physician | #{s.model} | #{s.persona}% | #{s.baseline}% | #{if s.delta >= 0, do: "+"}#{s.delta}pp |")
end

IO.puts("")

# Identify best result
all_deltas =
  Enum.map(exp1_summaries, fn s -> {s.delta, "Stripped/#{s.model}"} end) ++
  Enum.map(exp2_summaries, fn s -> {s.delta, "#{s.viewpoint}/#{s.model}"} end) ++
  Enum.map(exp3_summaries, fn s -> {s.delta, "Persona/#{s.model}"} end)

{best_delta, best_label} = Enum.max_by(all_deltas, fn {d, _} -> d end)
{worst_delta, worst_label} = Enum.min_by(all_deltas, fn {d, _} -> d end)

IO.puts("Best result: #{best_label} (#{if best_delta >= 0, do: "+"}#{best_delta}pp)")
IO.puts("Worst result: #{worst_label} (#{if worst_delta >= 0, do: "+"}#{worst_delta}pp)")

any_signal? = Enum.any?(all_deltas, fn {d, _} -> d >= 5.0 end)

IO.puts("")
if any_signal? do
  IO.puts("6F GATE: At least one experiment shows >= 5pp improvement. Scale-up warranted.")
else
  IO.puts("6F GATE: No experiment shows >= 5pp improvement. Prompt strategy alone insufficient at this model scale.")
end

# Save grand summary
grand_summary = %{
  phase: "6E",
  description: "Prompt experiments: stripped context, viewpoints, medical persona",
  total_calls: total_calls,
  total_elapsed_ms: total_ms,
  experiments: %{
    stripped_context: %{summaries: exp1_summaries, elapsed_ms: exp1_ms, calls: length(exp1_results)},
    viewpoints: %{summaries: exp2_summaries, elapsed_ms: exp2_ms, calls: length(exp2_results)},
    medical_persona: %{summaries: exp3_summaries, elapsed_ms: exp3_ms, calls: length(exp3_results)}
  },
  best: %{label: best_label, delta: best_delta},
  worst: %{label: worst_label, delta: worst_delta},
  gate_6f: any_signal?
}

File.write!(Path.join(trace_dir, "phase6e-grand-summary.json"), Jason.encode!(grand_summary, pretty: true))

IO.puts("\n========== PHASE 6E COMPLETE ==========")
IO.puts("#{total_calls} total Ollama calls in #{Float.round(total_ms / 1000, 1)}s (#{Float.round(total_ms / 60_000, 1)} min)")
IO.puts("Traces: #{trace_dir}/")
