questions = %{
  "A2" => "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
  "A3" => "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?"
}

solo_models = ["qwen2.5:0.5b", "tinydolphin", "llama3.2:3b"]
trials = 3

all_results =
  for {test_id, question} <- Enum.sort(questions),
      trial <- 1..trials do
    label = "#{test_id}-T#{trial}"
    IO.puts("\n========== #{label} ==========")
    IO.puts("Question: #{String.slice(question, 0, 60)}...")

    result =
      Cortex.Benchmark.run(question,
        solo_models: solo_models,
        adapter_config: %{model: "tinydolphin", num_predict: 64}
      )
      |> Map.put(:test_id, test_id)
      |> Map.put(:trial, trial)

    IO.puts("Solo:")
    for s <- result.solo do
      IO.puts("  #{s.model}: #{String.slice(s.answer || "(error)", 0, 80)} [#{s.latency_ms}ms]")
    end

    synth = result.collective[:synthesizer_answer] || "(none)"
    IO.puts("Collective: #{String.slice(synth, 0, 100)} [#{result.collective[:total_latency_ms]}ms]")

    result
  end

trace_dir = "priv/benchmark_traces"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}"
  path = Path.join(trace_dir, "#{label}.json")
  Cortex.Benchmark.export_trace(result, path: path)
end

summary_path = Path.join(trace_dir, "suite-summary.json")

summary =
  all_results
  |> Enum.map(fn r ->
    %{
      test_id: r.test_id,
      trial: r.trial,
      question: r.question,
      solo: Enum.map(r.solo, fn s -> %{model: s.model, answer: s.answer, latency_ms: s.latency_ms, status: s.status} end),
      collective_answer: r.collective[:synthesizer_answer],
      collective_status: r.collective[:status],
      collective_latency_ms: r.collective[:total_latency_ms],
      worker_outputs: r.collective[:worker_outputs]
    }
  end)

File.write!(summary_path, Jason.encode!(summary, pretty: true))
IO.puts("\n\n========== SUITE COMPLETE ==========")
IO.puts("#{length(all_results)} runs completed. Summary: #{summary_path}")
IO.puts("Traces: #{trace_dir}/")
