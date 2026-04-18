# Phase 4D: fan-out scaling — 10 and 25 tinydolphin workers vs Phase 4C baseline (5).
# Synthesizer fixed at gemma2:2b. Default 5-role viewpoints cycle across workers (rem index).
# 2 widths × 5 tests × 3 trials = 30 collective runs. No solos (Phase 4A holds solos).
# Run: mix run priv/phase4d_fanout_scaling.exs
#
# Requires: Ollama with tinydolphin, gemma2:2b.

questions = %{
  "A1" => "I need a car wash. The car wash is 50 meters away. Should I walk?",
  "A2" => "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
  "A3" => "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?",
  "A4" => "A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?",
  "A5" => "I have a brother. My brother has no brothers. How is this possible?"
}

synth = "gemma2:2b"
widths = [10, 25]

# Wall time grows with parallel Ollama load; allow headroom for 25 workers + synthesizer.
timeout_ms = 600_000

trials = 3

labels =
  for n_workers <- widths,
      {test_id, question} <- Enum.sort(questions),
      trial <- 1..trials,
      do: {n_workers, test_id, question, trial}

start_run = 151

all_results =
  Enum.map(Enum.with_index(labels, start_run), fn {{n_workers, test_id, question, trial}, run_num} ->
    label = "#{test_id}-T#{trial}"
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"
    worker_models = List.duplicate("tinydolphin", n_workers)

    IO.puts("\n========== #{run_id} #{label} workers=#{n_workers} synth=#{synth} ==========")

    result =
      Cortex.Benchmark.run(question,
        solo_models: [],
        timeout: timeout_ms,
        synthesizer_config: %{model: synth},
        workers: n_workers,
        worker_adapter_configs: worker_models
      )
      |> Map.put(:test_id, test_id)
      |> Map.put(:trial, trial)
      |> Map.put(:run_id, run_id)
      |> Map.put(:n_workers, n_workers)

    c = result.collective

    IO.puts(
      "  synthesizer (#{synth}): #{String.slice(c[:synthesizer_answer] || inspect(c[:status]), 0, 200)}"
    )

    result
  end)

trace_dir = "priv/benchmark_traces/phase4d"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-w#{result.n_workers}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Cortex.Benchmark.export_trace(result, path: path)
end

summary_path = Path.join(trace_dir, "phase4d-summary.json")

summary =
  all_results
  |> Enum.map(fn r ->
    c = r.collective

    %{
      run_id: r.run_id,
      n_workers: r.n_workers,
      test_id: r.test_id,
      trial: r.trial,
      question: r.question,
      synthesizer_answer: c[:synthesizer_answer],
      synthesizer_model: c[:synthesizer_model],
      collective_status: c[:status],
      total_latency_ms: c[:total_latency_ms],
      worker_count: c[:worker_count]
    }
  end)

File.write!(summary_path, Jason.encode!(summary, pretty: true))
IO.puts("\n\n========== PHASE 4D FAN-OUT SCALING COMPLETE ==========")
IO.puts("#{length(all_results)} runs. Summary: #{summary_path}")
