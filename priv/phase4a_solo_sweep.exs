# Phase 4A — Solo baseline sweep (all models × A1–A5 × 3 trials). Collective skipped.
# Run: mix run priv/phase4a_solo_sweep.exs

questions = %{
  "A1" => "I need a car wash. The car wash is 50 meters away. Should I walk?",
  "A2" => "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
  "A3" => "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?",
  "A4" => "A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?",
  "A5" => "I have a brother. My brother has no brothers. How is this possible?"
}

solo_models = [
  "tinydolphin",
  "qwen2.5:0.5b",
  "llama3.2:3b",
  "gemma2:2b",
  "smollm:1.7b",
  "phi3:mini"
]

trials = 3

labels =
  for {test_id, question} <- Enum.sort(questions),
      trial <- 1..trials,
      do: {test_id, question, trial}

all_results =
  Enum.map(Enum.with_index(labels, 46), fn {{test_id, question, trial}, run_num} ->
    label = "#{test_id}-T#{trial}"
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"

    IO.puts("\n========== #{run_id} #{label} ==========")

    result =
      Cortex.Benchmark.run(question,
        solo_models: solo_models,
        solo_only: true
      )
      |> Map.put(:test_id, test_id)
      |> Map.put(:trial, trial)
      |> Map.put(:run_id, run_id)

    for s <- result.solo do
      IO.puts("  #{s.model}: #{String.slice(s.answer || "(error)", 0, 120)}")
    end

    result
  end)

trace_dir = "priv/benchmark_traces/phase4a"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Cortex.Benchmark.export_trace(result, path: path)
end

summary_path = Path.join(trace_dir, "phase4a-summary.json")

summary =
  all_results
  |> Enum.map(fn r ->
    %{
      run_id: r.run_id,
      test_id: r.test_id,
      trial: r.trial,
      question: r.question,
      solo:
        Enum.map(r.solo, fn s ->
          %{model: s.model, answer: s.answer, latency_ms: s.latency_ms, status: s.status}
        end)
    }
  end)

File.write!(summary_path, Jason.encode!(summary, pretty: true))
IO.puts("\n\n========== PHASE 4A SOLO SWEEP COMPLETE ==========")
IO.puts("#{length(all_results)} runs. Summary: #{summary_path}")
