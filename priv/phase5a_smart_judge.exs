# Phase 5A: Smart Local Judge
# Larger models (7B–9B) as synthesizer with tinydolphin workers.
# Tests whether model size at the synthesis layer clears the 13% wall (JX-7 diagnosis).
#
# Config: solo_models: [] (no solo baselines); synthesizer_config: %{model: ...};
#         default 5-role viewpoints; workers: tinydolphin × 5.
# Runs: 3 synth models × 5 tests × 3 trials = 45 collective runs (RUN-181 – RUN-225).
#
# Synth candidates:
#   1. llama3.1:8b  — natural next step, most commonly used 8B
#   2. gemma2:9b    — builds on gemma2:2b (6/15 solo in Phase 4A), bigger sibling test
#   3. deepseek-r1:8b — reasoning model (chain-of-thought before output); paradigm-level test
#                       at same size as llama3.1:8b
#
# Decision gate: >5/15 (>33%) from any model = meaningful improvement → Phase 5B
#                Flat at ~13% = paradigm problem → Phase 5C (multi-lens assessment)
#
# Run: mix run priv/phase5a_smart_judge.exs

questions = %{
  "A1" => "I need a car wash. The car wash is 50 meters away. Should I walk?",
  "A2" =>
    "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
  "A3" => "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?",
  "A4" =>
    "A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?",
  "A5" => "I have a brother. My brother has no brothers. How is this possible?"
}

# Priority order: llama3.1 (natural step), gemma2:9b (family continuity), deepseek-r1 (paradigm test)
synth_models = ["llama3.1:8b", "gemma2:9b", "deepseek-r1:8b"]

trials = 3
start_run = 181

labels =
  for synth <- synth_models,
      {test_id, question} <- Enum.sort(questions),
      trial <- 1..trials,
      do: {synth, test_id, question, trial}

all_results =
  Enum.map(Enum.with_index(labels, start_run), fn {{synth, test_id, question, trial}, run_num} ->
    label = "#{test_id}-T#{trial}"
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"

    IO.puts("\n========== #{run_id} #{label} synth=#{synth} ==========")

    result =
      Cortex.Benchmark.run(question,
        solo_models: [],
        synthesizer_config: %{model: synth}
      )
      |> Map.put(:test_id, test_id)
      |> Map.put(:trial, trial)
      |> Map.put(:run_id, run_id)
      |> Map.put(:synth_model, synth)

    c = result.collective

    IO.puts(
      "  synthesizer (#{synth}): #{String.slice(c[:synthesizer_answer] || inspect(c[:status]), 0, 200)}"
    )

    result
  end)

trace_dir = "priv/benchmark_traces/phase5a"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-#{String.replace(result.synth_model, ":", "-")}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Cortex.Benchmark.export_trace(result, path: path)
end

summary_path = Path.join(trace_dir, "phase5a-summary.json")

summary =
  all_results
  |> Enum.map(fn r ->
    c = r.collective

    %{
      run_id: r.run_id,
      test_id: r.test_id,
      trial: r.trial,
      synth_model: r.synth_model,
      question: r.question,
      synthesizer_answer: c[:synthesizer_answer],
      synthesizer_model: c[:synthesizer_model],
      collective_status: c[:status],
      total_latency_ms: c[:total_latency_ms]
    }
  end)

File.write!(summary_path, Jason.encode!(summary, pretty: true))
IO.puts("\n\n========== PHASE 5A SMART JUDGE COMPLETE ==========")
IO.puts("#{length(all_results)} runs (RUN-181 – RUN-#{start_run + length(all_results) - 1}).")
IO.puts("Summary: #{summary_path}")
IO.puts("\nDecision gate: >5/15 from any model → Phase 5B | ~13% flatline → Phase 5C")
