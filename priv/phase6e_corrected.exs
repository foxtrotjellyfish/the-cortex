# Phase 6E Corrected: Re-run viewpoints + persona via /api/generate
#
# The control test revealed phi3's chat template destroys logprobs (53%→16%).
# All /api/chat experiments for phi3 are endpoint artifacts, not prompt effects.
#
# This script re-tests by PREPENDING the system prompt to the user prompt,
# keeping everything on /api/generate. Also runs granite neutral-chat control.
#
# Run: mix run priv/phase6e_corrected.exs

alias Cortex.Benchmark.MedQALoader

questions = MedQALoader.sample(100)

baselines = %{"phi3:mini" => 53, "granite3.1-moe:3b" => 50}

trace_dir = "priv/benchmark_traces/phase6e"
File.mkdir_p!(trace_dir)

# Helper: score via /api/generate with prepended instruction
score_with_prefix = fn prefix, q, model ->
  prompt = "#{prefix}\n\n#{q.mc_prompt}\nAnswer:"
  config = %{model: model}
  Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices)
end

run_experiment = fn label, prefix, model ->
  IO.puts("--- #{model} / #{label} (via /api/generate) ---\n")
  model_t0 = System.monotonic_time(:millisecond)

  results =
    for q <- questions do
      case score_with_prefix.(prefix, q, model) do
        {:ok, result} ->
          correct? = result.answer == q.correct
          marker = if correct?, do: "✓", else: "✗"
          IO.puts("  #{q.id}: #{result.answer} (#{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]")

          %{
            model: model,
            experiment: label,
            id: q.id,
            answer: result.answer,
            correct: q.correct,
            is_correct: correct?,
            probabilities: result.probabilities,
            confidence: result.confidence
          }

        {:error, reason} ->
          IO.puts("  #{q.id}: ERROR #{inspect(reason)}")
          %{model: model, experiment: label, id: q.id, answer: nil, correct: q.correct, is_correct: false, error: inspect(reason)}
      end
    end

  ms = System.monotonic_time(:millisecond) - model_t0
  hits = Enum.count(results, & &1.is_correct)
  pct = Float.round(hits / length(results) * 100, 1)
  base = baselines[model]
  delta = Float.round(pct - base, 1)
  IO.puts("\n  >> #{model}/#{label}: #{hits}/#{length(results)} (#{pct}%) | baseline: #{base}% | delta: #{if delta >= 0, do: "+"}#{delta}pp | #{Float.round(ms / 1000, 1)}s\n")

  {results, %{model: model, experiment: label, accuracy: pct, baseline: base, delta: delta, hits: hits, total: length(results), elapsed_ms: ms}}
end

IO.puts("=" |> String.duplicate(70))
IO.puts("  PHASE 6E CORRECTED: Prompt effects via /api/generate")
IO.puts("  (Bypasses phi3 chat template logprobs destruction)")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

viewpoints = [
  {"CHECK_ASSUMPTIONS",
   "You CHECK ASSUMPTIONS in the question. Are there hidden premises, tricks, or ambiguities?"},
  {"ARGUE_AGAINST",
   "You argue AGAINST the most obvious answer. Find flaws, edge cases, and alternatives."}
]

persona_prompt = "You are a physician taking the USMLE Step 1 exam. Choose the single best answer."

# phi3 experiments via /api/generate
all_results = []
all_summaries = []

for {vp_label, vp_prompt} <- viewpoints do
  {results, summary} = run_experiment.("vp_#{String.downcase(vp_label)}", vp_prompt, "phi3:mini")
  all_results = all_results ++ results
  all_summaries = all_summaries ++ [summary]
end

{persona_results, persona_summary} = run_experiment.("persona", persona_prompt, "phi3:mini")
all_results = all_results ++ persona_results
all_summaries = all_summaries ++ [persona_summary]

# granite viewpoints via /api/generate (for fair comparison)
for {vp_label, vp_prompt} <- viewpoints do
  {results, summary} = run_experiment.("vp_#{String.downcase(vp_label)}", vp_prompt, "granite3.1-moe:3b")
  all_results = all_results ++ results
  all_summaries = all_summaries ++ [summary]
end

{granite_persona_results, granite_persona_summary} = run_experiment.("persona", persona_prompt, "granite3.1-moe:3b")
all_results = all_results ++ granite_persona_results
all_summaries = all_summaries ++ [granite_persona_summary]

# Granite control: neutral system via /api/chat
IO.puts("--- granite3.1-moe:3b / NEUTRAL via /api/chat (control) ---\n")
granite_ctrl_t0 = System.monotonic_time(:millisecond)

granite_ctrl_results =
  for q <- questions do
    prompt = "#{q.mc_prompt}\nAnswer:"
    config = %{model: "granite3.1-moe:3b", system: "Answer the following multiple choice question."}

    case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
      {:ok, result} ->
        correct? = result.answer == q.correct
        marker = if correct?, do: "✓", else: "✗"
        IO.puts("  #{q.id}: #{result.answer} (#{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]")

        %{
          model: "granite3.1-moe:3b",
          experiment: "chat_control_neutral",
          id: q.id,
          answer: result.answer,
          correct: q.correct,
          is_correct: correct?,
          probabilities: result.probabilities,
          confidence: result.confidence
        }

      {:error, reason} ->
        IO.puts("  #{q.id}: ERROR #{inspect(reason)}")
        %{model: "granite3.1-moe:3b", experiment: "chat_control_neutral", id: q.id, answer: nil, correct: q.correct, is_correct: false, error: inspect(reason)}
    end
  end

granite_ctrl_ms = System.monotonic_time(:millisecond) - granite_ctrl_t0
granite_ctrl_hits = Enum.count(granite_ctrl_results, & &1.is_correct)
granite_ctrl_pct = Float.round(granite_ctrl_hits / length(granite_ctrl_results) * 100, 1)
IO.puts("\n  >> granite/NEUTRAL_CHAT: #{granite_ctrl_hits}/#{length(granite_ctrl_results)} (#{granite_ctrl_pct}%) | baseline: 50% | delta: #{if granite_ctrl_pct - 50 >= 0, do: "+"}#{Float.round(granite_ctrl_pct - 50, 1)}pp | #{Float.round(granite_ctrl_ms / 1000, 1)}s\n")

granite_ctrl_summary = %{model: "granite3.1-moe:3b", experiment: "chat_control_neutral", accuracy: granite_ctrl_pct, baseline: 50, delta: Float.round(granite_ctrl_pct - 50, 1), hits: granite_ctrl_hits, total: length(granite_ctrl_results), elapsed_ms: granite_ctrl_ms}

# ============================================================
# CORRECTED GRAND SUMMARY
# ============================================================

IO.puts("=" |> String.duplicate(70))
IO.puts("  CORRECTED RESULTS: /api/generate path for all prompt experiments")
IO.puts("=" |> String.duplicate(70))
IO.puts("")

IO.puts("| Model | Experiment | Endpoint | Accuracy | Baseline | Delta |")
IO.puts("| --- | --- | --- | --- | --- | --- |")
IO.puts("| phi3:mini | 6B baseline | /api/generate | 53.0% | — | — |")
IO.puts("| phi3:mini | NEUTRAL chat control | /api/chat | 16.0% | 53% | -37.0pp |")

for s <- all_summaries do
  IO.puts("| #{s.model} | #{s.experiment} | /api/generate | #{s.accuracy}% | #{s.baseline}% | #{if s.delta >= 0, do: "+"}#{s.delta}pp |")
end

IO.puts("| granite3.1-moe:3b | 6B baseline | /api/generate | 50.0% | — | — |")
IO.puts("| granite3.1-moe:3b | NEUTRAL chat control | /api/chat | #{granite_ctrl_pct}% | 50% | #{if granite_ctrl_pct - 50 >= 0, do: "+"}#{Float.round(granite_ctrl_pct - 50, 1)}pp |")

IO.puts("")

# Identify actual prompt effects (generate-path only)
phi3_generate_summaries = Enum.filter(all_summaries, &(&1.model == "phi3:mini"))
granite_generate_summaries = Enum.filter(all_summaries, &(&1.model == "granite3.1-moe:3b"))

best_phi3 = Enum.max_by(phi3_generate_summaries, & &1.delta)
worst_phi3 = Enum.min_by(phi3_generate_summaries, & &1.delta)

IO.puts("phi3 best prompt: #{best_phi3.experiment} (#{if best_phi3.delta >= 0, do: "+"}#{best_phi3.delta}pp)")
IO.puts("phi3 worst prompt: #{worst_phi3.experiment} (#{if worst_phi3.delta >= 0, do: "+"}#{worst_phi3.delta}pp)")

if length(granite_generate_summaries) > 0 do
  best_granite = Enum.max_by(granite_generate_summaries, & &1.delta)
  worst_granite = Enum.min_by(granite_generate_summaries, & &1.delta)
  IO.puts("granite best prompt: #{best_granite.experiment} (#{if best_granite.delta >= 0, do: "+"}#{best_granite.delta}pp)")
  IO.puts("granite worst prompt: #{worst_granite.experiment} (#{if worst_granite.delta >= 0, do: "+"}#{worst_granite.delta}pp)")
end

IO.puts("")

any_improvement? =
  Enum.any?(all_summaries, fn s -> s.delta >= 5.0 end)

if any_improvement? do
  IO.puts("6F GATE (corrected): At least one prompt shows >= 5pp improvement via /api/generate.")
else
  IO.puts("6F GATE (corrected): No prompt shows >= 5pp improvement via /api/generate.")
end

# Save corrected trace
total_calls = length(all_results) + length(granite_ctrl_results)
total_ms = Enum.reduce(all_summaries, 0, fn s, acc -> acc + s.elapsed_ms end) + granite_ctrl_ms

corrected_trace = %{
  phase: "6E-corrected",
  description: "Re-run prompt experiments via /api/generate to bypass phi3 chat template destruction",
  critical_finding: "phi3:mini /api/chat logprobs destruction: 53%→16% with ANY system prompt (neutral, viewpoint, or persona). Endpoint artifact, not prompt effect.",
  total_calls: total_calls,
  total_elapsed_ms: total_ms,
  summaries: all_summaries ++ [granite_ctrl_summary],
  results: Enum.map(all_results ++ granite_ctrl_results, fn r ->
    Map.take(r, [:model, :experiment, :id, :answer, :correct, :is_correct, :probabilities, :confidence])
  end)
}

File.write!(Path.join(trace_dir, "phase6e-corrected.json"), Jason.encode!(corrected_trace, pretty: true))

IO.puts("\n========== CORRECTED EXPERIMENTS COMPLETE ==========")
IO.puts("#{total_calls} total calls in #{Float.round(total_ms / 1000, 1)}s (#{Float.round(total_ms / 60_000, 1)} min)")
IO.puts("Trace: #{trace_dir}/phase6e-corrected.json")
