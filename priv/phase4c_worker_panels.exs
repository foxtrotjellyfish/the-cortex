# Phase 4C: heterogeneous vs homogeneous worker panels. Synthesizer fixed at gemma2:2b (best from Phase 4B).
# 3 panel types × 5 tests × 3 trials = 45 collective runs. No solo baselines (Phase 4A holds solos).
# Run: mix run priv/phase4c_worker_panels.exs
#
# Requires: Ollama with tinydolphin, qwen2.5:0.5b, gemma2:2b.

questions = %{
  "A1" => "I need a car wash. The car wash is 50 meters away. Should I walk?",
  "A2" => "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
  "A3" => "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?",
  "A4" => "A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?",
  "A5" => "I have a brother. My brother has no brothers. How is this possible?"
}

synth = "gemma2:2b"

panels = [
  {"all_td", ~w(tinydolphin tinydolphin tinydolphin tinydolphin tinydolphin)},
  {"all_qwen", List.duplicate("qwen2.5:0.5b", 5)},
  {"mixed", ~w(tinydolphin qwen2.5:0.5b gemma2:2b tinydolphin qwen2.5:0.5b)}
]

trials = 3

labels =
  for {panel_id, worker_models} <- panels,
      {test_id, question} <- Enum.sort(questions),
      trial <- 1..trials,
      do: {panel_id, worker_models, test_id, question, trial}

start_run = 106

all_results =
  Enum.map(Enum.with_index(labels, start_run), fn {{panel_id, worker_models, test_id, question, trial}, run_num} ->
    label = "#{test_id}-T#{trial}"
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"

    IO.puts("\n========== #{run_id} #{label} panel=#{panel_id} synth=#{synth} ==========")

    result =
      Cortex.Benchmark.run(question,
        solo_models: [],
        synthesizer_config: %{model: synth},
        worker_adapter_configs: worker_models
      )
      |> Map.put(:test_id, test_id)
      |> Map.put(:trial, trial)
      |> Map.put(:run_id, run_id)
      |> Map.put(:panel_id, panel_id)

    c = result.collective

    IO.puts(
      "  synthesizer (#{synth}): #{String.slice(c[:synthesizer_answer] || inspect(c[:status]), 0, 200)}"
    )

    result
  end)

trace_dir = "priv/benchmark_traces/phase4c"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-#{result.panel_id}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Cortex.Benchmark.export_trace(result, path: path)
end

summary_path = Path.join(trace_dir, "phase4c-summary.json")

summary =
  all_results
  |> Enum.map(fn r ->
    c = r.collective

    %{
      run_id: r.run_id,
      panel_id: r.panel_id,
      test_id: r.test_id,
      trial: r.trial,
      question: r.question,
      synthesizer_answer: c[:synthesizer_answer],
      synthesizer_model: c[:synthesizer_model],
      collective_status: c[:status],
      total_latency_ms: c[:total_latency_ms]
    }
  end)

File.write!(summary_path, Jason.encode!(summary, pretty: true))
IO.puts("\n\n========== PHASE 4C WORKER PANEL SWEEP COMPLETE ==========")
IO.puts("#{length(all_results)} runs. Summary: #{summary_path}")
