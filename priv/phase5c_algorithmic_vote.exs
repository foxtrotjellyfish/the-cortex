# Phase 5C-lite: Algorithmic Aggregation (no LLM judge)
#
# Two configs testing whether pure Elixir answer extraction + majority vote
# can break through the 13% synthesis wall that 8 LLM-judge configurations couldn't.
#
# Config 1 (control): tinydolphin × 5 — same worker stack as Phases 3–5A.
#   Isolates the aggregation change: same workers, different aggregation.
#
# Config 2 (diverse): tinydolphin, phi3:mini, gemma2:2b, llama3.2:3b, tinydolphin
#   Tests model diversity + algorithmic aggregation combined.
#   These models crack different tests individually (Phase 4A solo sweep).
#
# Both configs: 5 tests × 3 trials = 15 runs each, 30 total.
# The LLM synthesizer still runs (for head-to-head comparison) but is not the grade.
#
# Correct answers:
#   A1: need_car (reject walking, mention needing to drive)
#   A2: basket (Sally's false belief — she thinks marble is where she left it)
#   A3: 8 (all but 8 die = 8 remain)
#   A4: white (North Pole → polar bear)
#   A5: sister (narrator is female)
#
# Run: mix run priv/phase5c_algorithmic_vote.exs

questions = %{
  "A1" => "I need a car wash. The car wash is 50 meters away. Should I walk?",
  "A2" =>
    "Sally puts a marble in a basket and leaves the room. While she's gone, Anne moves the marble from the basket to a box. When Sally comes back, where will she look for the marble?",
  "A3" => "A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?",
  "A4" =>
    "A man builds a house where all four walls face south. A bear walks past the house. What color is the bear?",
  "A5" => "I have a brother. My brother has no brothers. How is this possible?"
}

correct_answers = %{
  "A1" => "need_car",
  "A2" => "basket",
  "A3" => "8",
  "A4" => "white",
  "A5" => "sister"
}

configs = [
  %{
    name: "homogeneous",
    label: "tinydolphin×5",
    worker_adapter_configs: nil
  },
  %{
    name: "diverse",
    label: "td/phi3/gemma2/llama3.2/td",
    worker_adapter_configs: [
      "tinydolphin",
      "phi3:mini",
      "gemma2:2b",
      "llama3.2:3b",
      "tinydolphin"
    ]
  }
]

trials = 3
start_run = 226

IO.puts("========== PHASE 5C-LITE: ALGORITHMIC AGGREGATION ==========\n")

labels =
  for config <- configs,
      {test_id, question} <- Enum.sort(questions),
      trial <- 1..trials,
      do: {config, test_id, question, trial}

all_results =
  Enum.map(Enum.with_index(labels, start_run), fn {{config, test_id, question, trial}, run_num} ->
    run_id = "RUN-#{String.pad_leading(Integer.to_string(run_num), 3, "0")}"
    label = "#{test_id}-T#{trial}"

    IO.puts("\n---------- #{run_id} #{label} [#{config.name}] ----------")

    opts = [
      test_id: test_id,
      solo_models: [],
      timeout: 180_000
    ]

    opts =
      case config.worker_adapter_configs do
        nil -> opts
        wac -> Keyword.put(opts, :worker_adapter_configs, wac)
      end

    result = Cortex.Benchmark.run_algorithmic(question, opts)

    algo_answer = result[:algorithmic_answer] || "(nil)"
    algo_votes = result[:algorithmic_votes] || 0
    algo_total = result[:algorithmic_total] || 0
    synth_answer = result[:synthesizer_answer] || "(timeout/nil)"
    correct = Map.get(correct_answers, test_id)
    algo_correct = algo_answer == correct
    synth_correct = String.contains?(String.downcase(synth_answer), correct)

    IO.puts("  Algorithmic: #{algo_answer} (#{algo_votes}/#{algo_total} votes) #{if algo_correct, do: "✓ CORRECT", else: "✗ wrong"}")
    IO.puts("  Synthesizer: #{String.slice(synth_answer, 0, 100)} #{if synth_correct, do: "✓", else: "✗"}")
    IO.puts("  Extracted:   #{inspect(result[:extracted_answers])}")
    IO.puts("  Distribution: #{inspect(result[:algorithmic_distribution])}")

    result
    |> Map.put(:question, question)
    |> Map.put(:test_id, test_id)
    |> Map.put(:trial, trial)
    |> Map.put(:run_id, run_id)
    |> Map.put(:config_name, config.name)
    |> Map.put(:config_label, config.label)
    |> Map.put(:correct_answer, correct)
    |> Map.put(:algo_correct, algo_correct)
    |> Map.put(:synth_correct, synth_correct)
  end)

# --- Summary tables ---

IO.puts("\n\n========== PHASE 5C-LITE RESULTS ==========\n")

for config <- configs do
  config_results = Enum.filter(all_results, &(&1.config_name == config.name))

  IO.puts("--- #{config.label} (#{config.name}) ---")
  IO.puts("")

  for test_id <- ["A1", "A2", "A3", "A4", "A5"] do
    test_results = Enum.filter(config_results, &(&1.test_id == test_id))

    algo_hits = Enum.count(test_results, & &1.algo_correct)
    synth_hits = Enum.count(test_results, & &1.synth_correct)

    IO.puts("  #{test_id}: algo #{algo_hits}/#{length(test_results)} | synth #{synth_hits}/#{length(test_results)}")
  end

  total_algo = Enum.count(config_results, & &1.algo_correct)
  total_synth = Enum.count(config_results, & &1.synth_correct)
  IO.puts("  TOTAL: algo #{total_algo}/#{length(config_results)} | synth #{total_synth}/#{length(config_results)}")
  IO.puts("")
end

# --- Traces ---

trace_dir = "priv/benchmark_traces/phase5c"
File.mkdir_p!(trace_dir)

for result <- all_results do
  label = "#{result.test_id}-T#{result.trial}-#{result.config_name}"
  path = Path.join(trace_dir, "#{result.run_id}-#{label}.json")
  Cortex.Benchmark.export_trace(result, path: path)
end

summary =
  all_results
  |> Enum.map(fn r ->
    %{
      run_id: r.run_id,
      test_id: r.test_id,
      trial: r.trial,
      config: r.config_name,
      config_label: r.config_label,
      question: r.question,
      correct_answer: r.correct_answer,
      algorithmic_answer: r[:algorithmic_answer],
      algorithmic_votes: r[:algorithmic_votes],
      algorithmic_total: r[:algorithmic_total],
      algorithmic_distribution: r[:algorithmic_distribution],
      extracted_answers: r[:extracted_answers],
      algo_correct: r.algo_correct,
      synthesizer_answer: r[:synthesizer_answer],
      synth_correct: r.synth_correct,
      total_latency_ms: r[:total_latency_ms],
      worker_outputs: r[:worker_outputs]
    }
  end)

summary_path = Path.join(trace_dir, "phase5c-summary.json")
File.write!(summary_path, Jason.encode!(summary, pretty: true))

IO.puts("========== PHASE 5C-LITE COMPLETE ==========")
IO.puts("#{length(all_results)} runs (RUN-#{start_run} – RUN-#{start_run + length(all_results) - 1}).")
IO.puts("Summary: #{summary_path}")
IO.puts("Traces: #{trace_dir}/")
