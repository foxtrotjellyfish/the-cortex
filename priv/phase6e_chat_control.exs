# Phase 6E Control: Chat Endpoint Baseline
#
# The viewpoint and persona experiments both used /api/chat with a system
# message, while the 6B baseline used /api/generate (flat prompt). phi3
# collapsed to 15-18% on both — is this the prompt content or the endpoint?
#
# This control uses /api/chat with a minimal neutral system prompt to isolate
# the endpoint effect from the prompt content effect.
#
# Run: mix run priv/phase6e_chat_control.exs

alias Cortex.Benchmark.MedQALoader

questions = MedQALoader.sample(100)

neutral_prompt = "Answer the following multiple choice question."
model = "phi3:mini"

IO.puts("=" |> String.duplicate(60))
IO.puts("  CONTROL: phi3 via /api/chat with neutral system prompt")
IO.puts("  Isolates endpoint effect from prompt content effect")
IO.puts("=" |> String.duplicate(60))
IO.puts("")
IO.puts("System: \"#{neutral_prompt}\"")
IO.puts("Model: #{model}")
IO.puts("Calls: #{length(questions)}")
IO.puts("")

t0 = System.monotonic_time(:millisecond)

results =
  for q <- questions do
    prompt = "#{q.mc_prompt}\nAnswer:"
    config = %{model: model, system: neutral_prompt}

    case Cortex.LLM.Adapters.Ollama.score_choices(prompt, config, q.choices) do
      {:ok, result} ->
        correct? = result.answer == q.correct
        marker = if correct?, do: "✓", else: "✗"

        IO.puts(
          "  #{q.id}: #{result.answer} (#{Float.round(result.confidence, 3)}) #{marker}  [correct: #{q.correct}]"
        )

        %{
          id: q.id,
          answer: result.answer,
          correct: q.correct,
          is_correct: correct?,
          probabilities: result.probabilities,
          confidence: result.confidence
        }

      {:error, reason} ->
        IO.puts("  #{q.id}: ERROR #{inspect(reason)}")
        %{id: q.id, answer: nil, correct: q.correct, is_correct: false, error: inspect(reason)}
    end
  end

elapsed_ms = System.monotonic_time(:millisecond) - t0

hits = Enum.count(results, & &1.is_correct)
pct = Float.round(hits / length(results) * 100, 1)

IO.puts("\n--- CONTROL RESULT ---\n")
IO.puts("| Condition | Endpoint | Accuracy | vs 6B Baseline (53%) |")
IO.puts("| --- | --- | --- | --- |")
IO.puts("| 6B baseline (no system) | /api/generate | 53.0% | — |")
IO.puts("| CONTROL (neutral system) | /api/chat | #{pct}% | #{if pct - 53 >= 0, do: "+"}#{Float.round(pct - 53, 1)}pp |")
IO.puts("| CHECK_ASSUMPTIONS | /api/chat | 18.0% | -35.0pp |")
IO.puts("| ARGUE_AGAINST | /api/chat | 16.0% | -37.0pp |")
IO.puts("| Medical Persona | /api/chat | 15.0% | -38.0pp |")
IO.puts("")

cond do
  pct >= 48.0 ->
    IO.puts("FINDING: Neutral chat endpoint ≈ baseline. Degradation is from PROMPT CONTENT, not endpoint.")
    IO.puts("The viewpoint/persona prompts specifically damage phi3's logprobs on domain knowledge.")
  pct <= 25.0 ->
    IO.puts("FINDING: Chat endpoint itself causes collapse. phi3's chat template destroys logprobs calibration.")
    IO.puts("Experiments 2 & 3 are measuring an ENDPOINT ARTIFACT, not prompt effects.")
  true ->
    IO.puts("FINDING: Mixed — endpoint causes partial degradation (#{Float.round(53 - pct, 1)}pp),")
    IO.puts("prompt content adds further damage. Both factors contribute.")
end

# Save trace
trace_dir = "priv/benchmark_traces/phase6e"
File.mkdir_p!(trace_dir)

trace = %{
  phase: "6E-control",
  experiment: "chat_endpoint_control",
  description: "phi3 via /api/chat with neutral system prompt to isolate endpoint vs prompt effect",
  system_prompt: neutral_prompt,
  model: model,
  questions: length(questions),
  accuracy: pct,
  hits: hits,
  elapsed_ms: elapsed_ms,
  results: Enum.map(results, fn r ->
    Map.take(r, [:id, :answer, :correct, :is_correct, :probabilities, :confidence])
  end)
}

File.write!(Path.join(trace_dir, "exp-control-chat-endpoint.json"), Jason.encode!(trace, pretty: true))

IO.puts("\n#{length(results)} calls in #{Float.round(elapsed_ms / 1000, 1)}s")
IO.puts("Trace: #{trace_dir}/exp-control-chat-endpoint.json")
