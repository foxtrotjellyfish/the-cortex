# Collective benchmark: default tinydolphin workers + swapped synthesizer model.
# 5 tests (A1–A5) × 3 trials × 3 synthesizer models = 45 runs. Solo baselines skipped (solo_models: []).
# Run: mix run priv/phase4b_synth_sweep.exs
#
# Requires: Ollama with tinydolphin, phi3:mini, gemma2:2b, llama3.2:3b available locally.

questions = %{
  "A1" => "I need a car wash. The car wash is 50 meters away. Should I walk?",
  "A2" => "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
  "A3" => "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?",
  "A4" => "A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?",
  "A5" => "I have a brother. My brother has no brothers. How is this possible?"
}

# Priority order from solo sweep: strongest candidates first
synth_models = ["phi3:mini", "gemma2:2b", "llama3.2:3b"]

trials = 3

labels =
  for synth <- synth_models,
      {test_id, question} <- Enum.sort(questions),
      trial <- 1..trials,
      do: {synth, test_id, question, trial}

start_run = 61

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

trace_dir = "priv/benchmark_traces/phase4b"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-#{result.synth_model}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Cortex.Benchmark.export_trace(result, path: path)
end

summary_path = Path.join(trace_dir, "phase4b-summary.json")

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
IO.puts("\n\n========== PHASE 4B COLLECTIVE SYNTH SWEEP COMPLETE ==========")
IO.puts("#{length(all_results)} runs. Summary: #{summary_path}")
