defmodule Phase5G.Aggregation do
  @moduledoc """
  Phase 5G aggregation: distribution-level methods over 5G collective traces.
  Zero Ollama calls — pure Elixir math over existing logprobs distributions.

  Implements 8 methods:
    1. Majority Vote (baseline)
    2. Confidence-Weighted Vote
    3. MoE (uniform mixture)
    4. Entropy-Weighted MoE
    5. Entropy-Gated MoE
    6. Product of Experts (smoothed)
    7. Logarithmic Opinion Pool
    8. Bell Curve (Jake's novel method — penalize over/under-confident models)

  Reads: priv/benchmark_traces/phase5g/phase5g-collective-summary.json
  """

  @choices ["A", "B", "C", "D"]
  @epsilon 1.0e-6

  # Bell curve default: μ=0.60, σ=0.10 (best from pre-simulation on A7/A8)
  @bell_mu 0.60
  @bell_sigma 0.10

  @correct_answers %{
    "A1" => "B", "A2" => "A", "A3" => "B", "A4" => "C",
    "A5" => "A", "A6" => "D", "A7" => "B", "A8" => "B"
  }

  def run do
    path = Path.join([__DIR__, "benchmark_traces", "phase5g", "phase5g-collective-summary.json"])
    data = path |> File.read!() |> Jason.decode!()
    collective = data["collective"]

    IO.puts(String.duplicate("=", 100))
    IO.puts("PHASE 5G AGGREGATION: 8 METHODS × 2 PANELS × 8 TESTS")
    IO.puts("Re-scoring #{length(collective)} collective runs from 5G traces — ZERO Ollama calls")
    IO.puts(String.duplicate("=", 100))

    methods = [
      {"Majority", &majority_vote/1},
      {"Conf-Wt", &confidence_weighted/1},
      {"MoE", &moe_uniform/1},
      {"Ent-Wt", &entropy_weighted_moe/1},
      {"Ent-Gate", &entropy_gated/1},
      {"PoE", &poe_smoothed/1},
      {"LogOP", &log_opinion_pool/1},
      {"BellCurve", &bell_curve_default/1}
    ]

    results =
      for run <- collective do
        workers = normalize_workers(run["per_worker"])
        correct = run["correct_answer"] || @correct_answers[run["test_id"]]

        method_results =
          for {name, func} <- methods do
            {answer, dist} = func.(workers)
            {name, answer, answer == correct, dist}
          end

        %{
          config: run["config"],
          test_id: run["test_id"],
          trial: run["trial"],
          run_id: run["run_id"],
          correct: correct,
          results: method_results,
          workers: workers
        }
      end

    print_scorecard(results, methods)
    print_head_to_head(results, methods)
    print_divergence_table(results, methods)
    print_distribution_deep_dive(results)
    print_bell_curve_sweep(results)
    print_key_findings(results, methods)
    export_json(results, methods)
  end

  # --- Aggregation Methods ---
  # Each returns {winner_letter, full_distribution_map}

  defp normalize_workers(per_worker) do
    Enum.map(per_worker, fn w ->
      probs = w["probabilities"]
      dist = Map.new(@choices, fn c -> {c, Map.get(probs, c, 0.0)} end)
      total = dist |> Map.values() |> Enum.sum()
      dist = if total > 0, do: Map.new(dist, fn {k, v} -> {k, v / total} end), else: dist
      %{model: w["model"], dist: dist, confidence: w["confidence"] || 0.0}
    end)
  end

  defp majority_vote(workers) do
    votes = workers |> Enum.map(fn w -> top_answer(w.dist) end) |> Enum.frequencies()
    dist = Map.new(@choices, fn c -> {c, Map.get(votes, c, 0) / length(workers)} end)
    winner = votes |> Enum.max_by(fn {_a, n} -> n end) |> elem(0)
    {winner, dist}
  end

  defp confidence_weighted(workers) do
    dist = Map.new(@choices, fn c ->
      weight =
        workers
        |> Enum.filter(fn w -> top_answer(w.dist) == c end)
        |> Enum.map(fn w -> w.dist[c] end)
        |> Enum.sum()
      {c, weight}
    end)
    total = dist |> Map.values() |> Enum.sum()
    dist = if total > 0, do: Map.new(dist, fn {k, v} -> {k, v / total} end), else: dist
    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist}
  end

  defp moe_uniform(workers) do
    n = length(workers)
    dist = Map.new(@choices, fn c ->
      {c, workers |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)}
    end)
    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist}
  end

  defp entropy_weighted_moe(workers) do
    max_h = :math.log(length(@choices))
    weights = Enum.map(workers, fn w ->
      h = entropy(w.dist)
      1.0 / (h / max_h + @epsilon)
    end)
    total_w = Enum.sum(weights)

    dist = Map.new(@choices, fn c ->
      val = Enum.zip(workers, weights)
        |> Enum.map(fn {w, wt} -> w.dist[c] * wt end)
        |> Enum.sum()
        |> Kernel./(total_w)
      {c, val}
    end)
    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist}
  end

  defp entropy_gated(workers) do
    max_h = :math.log(length(@choices))
    threshold = 0.85

    active = Enum.filter(workers, fn w -> entropy(w.dist) / max_h < threshold end)

    if active == [] do
      moe_uniform(workers)
    else
      n = length(active)
      dist = Map.new(@choices, fn c ->
        {c, active |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)}
      end)
      winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
      {winner, dist}
    end
  end

  defp poe_smoothed(workers) do
    raw = Map.new(@choices, fn c ->
      log_prod = workers
        |> Enum.map(fn w -> :math.log(max(w.dist[c], @epsilon)) end)
        |> Enum.sum()
      {c, :math.exp(log_prod)}
    end)
    z = raw |> Map.values() |> Enum.sum()
    dist = if z > 0, do: Map.new(raw, fn {k, v} -> {k, v / z} end), else: raw
    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist}
  end

  defp log_opinion_pool(workers) do
    n = length(workers)
    raw = Map.new(@choices, fn c ->
      avg_log = workers
        |> Enum.map(fn w -> :math.log(max(w.dist[c], @epsilon)) end)
        |> Enum.sum()
        |> Kernel./(n)
      {c, :math.exp(avg_log)}
    end)
    z = raw |> Map.values() |> Enum.sum()
    dist = if z > 0, do: Map.new(raw, fn {k, v} -> {k, v / z} end), else: raw
    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist}
  end

  defp bell_curve_default(workers), do: bell_curve(workers, @bell_mu, @bell_sigma)

  defp bell_curve(workers, mu, sigma) do
    weights = Enum.map(workers, fn w ->
      top_conf = w.dist |> Map.values() |> Enum.max()
      :math.exp(-((top_conf - mu) * (top_conf - mu)) / (2.0 * sigma * sigma))
    end)
    total_w = Enum.sum(weights)

    if total_w < @epsilon do
      moe_uniform(workers)
    else
      dist = Map.new(@choices, fn c ->
        val = Enum.zip(workers, weights)
          |> Enum.map(fn {w, wt} -> w.dist[c] * wt end)
          |> Enum.sum()
          |> Kernel./(total_w)
        {c, val}
      end)
      winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
      {winner, dist}
    end
  end

  # --- Utilities ---

  defp entropy(dist) do
    dist |> Map.values() |> Enum.filter(&(&1 > 0)) |> Enum.map(fn p -> -p * :math.log(p) end) |> Enum.sum()
  end

  defp top_answer(dist), do: dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)

  # --- Output ---

  defp print_scorecard(results, methods) do
    method_names = Enum.map(methods, fn {n, _} -> n end)

    for panel <- ["curated_5", "full_8"] do
      panel_results = Enum.filter(results, &(&1.config == panel))
      panel_label = if panel == "curated_5", do: "CURATED 5-WORKER PANEL", else: "FULL 8-WORKER PANEL"

      IO.puts("\n" <> String.duplicate("=", 100))
      IO.puts("SCORECARD: #{panel_label}")
      IO.puts(String.duplicate("=", 100))

      header = String.pad_trailing("Test", 6) <>
        String.pad_trailing("Correct", 9) <>
        Enum.map_join(method_names, "", fn n -> String.pad_trailing(n, 12) end)
      IO.puts(header)
      IO.puts(String.duplicate("-", String.length(header)))

      for test_id <- ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8"] do
        test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
        correct = @correct_answers[test_id]

        scores = for {name, _} <- methods do
          hits = test_runs
            |> Enum.count(fn r ->
              Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
            end)
          score = "#{hits}/#{length(test_runs)}"
          if hits > 0, do: "✅ #{score}", else: "   #{score}"
        end

        IO.puts(
          String.pad_trailing(test_id, 6) <>
          String.pad_trailing(correct, 9) <>
          Enum.map_join(scores, "", fn s -> String.pad_trailing(s, 12) end)
        )
      end

      IO.puts(String.duplicate("-", String.length(header)))

      totals = for {name, _} <- methods do
        hits = panel_results
          |> Enum.count(fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
          end)
        total = length(panel_results)
        pct = Float.round(hits / total * 100, 1)
        "#{hits}/#{total}(#{pct}%)"
      end

      IO.puts(
        String.pad_trailing("TOTAL", 15) <>
        Enum.map_join(totals, "", fn s -> String.pad_trailing(s, 12) end)
      )
    end
  end

  defp print_head_to_head(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("HEAD-TO-HEAD: CURATED 5 vs FULL 8 (by method)")
    IO.puts(String.duplicate("=", 100))

    for {name, _} <- methods do
      c5 = results |> Enum.filter(&(&1.config == "curated_5"))
        |> Enum.count(fn r -> Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2) end)
      f8 = results |> Enum.filter(&(&1.config == "full_8"))
        |> Enum.count(fn r -> Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2) end)
      delta = c5 - f8
      arrow = cond do
        delta > 0 -> "curated +#{delta}"
        delta < 0 -> "full_8 +#{abs(delta)}"
        true -> "tied"
      end
      IO.puts("  #{String.pad_trailing(name, 12)} curated: #{c5}/24  full: #{f8}/24  (#{arrow})")
    end
  end

  defp print_divergence_table(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("DIVERGENCE FROM MAJORITY VOTE")
    IO.puts("Where methods disagree with majority — these are the interesting cases")
    IO.puts(String.duplicate("=", 100))

    for panel <- ["curated_5", "full_8"] do
      panel_results = Enum.filter(results, &(&1.config == panel))
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      IO.puts("\n--- #{panel_label} ---")

      divergences =
        for r <- panel_results,
            {name, answer, correct, dist} <- r.results,
            name != "Majority",
            {_, maj_ans, _, _} = Enum.find(r.results, fn {n, _, _, _} -> n == "Majority" end),
            answer != maj_ans do
          %{
            run: r.run_id,
            test: r.test_id,
            trial: r.trial,
            correct_ans: r.correct,
            method: name,
            method_answer: answer,
            method_correct: correct,
            majority_answer: maj_ans,
            p_correct: Float.round(dist[r.correct] * 100, 1)
          }
        end

      if divergences == [] do
        IO.puts("  No divergences — all methods agree with majority on every run.")
      else
        IO.puts("  #{String.pad_trailing("Run", 10)} #{String.pad_trailing("Test", 5)} " <>
          "#{String.pad_trailing("Method", 12)} #{String.pad_trailing("Method→", 9)} " <>
          "#{String.pad_trailing("Maj→", 6)} #{String.pad_trailing("Correct", 9)} " <>
          "P(correct)")
        IO.puts("  " <> String.duplicate("-", 75))

        for d <- divergences do
          m_mark = if d.method_correct, do: "✅", else: "❌"
          IO.puts("  #{String.pad_trailing(d.run, 10)} #{String.pad_trailing(d.test, 5)} " <>
            "#{String.pad_trailing(d.method, 12)} #{m_mark} #{d.method_answer}       " <>
            "#{d.majority_answer}     #{d.correct_ans}        #{d.p_correct}%")
        end

        upgrades = Enum.count(divergences, & &1.method_correct)
        downgrades = Enum.count(divergences, &(not &1.method_correct))
        IO.puts("\n  Divergences: #{length(divergences)} total | #{upgrades} upgrades ✅ | #{downgrades} downgrades ❌")
      end
    end
  end

  defp print_distribution_deep_dive(results) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("DISTRIBUTION DEEP DIVE — Key Tests (Trial 1, Curated 5)")
    IO.puts(String.duplicate("=", 100))

    curated_t1 = results
      |> Enum.filter(&(&1.config == "curated_5" and &1.trial == 1))

    for test_id <- ["A3", "A4", "A7", "A8", "A1"] do
      run = Enum.find(curated_t1, &(&1.test_id == test_id))
      if run do
        IO.puts("\n--- #{test_id} (correct: #{run.correct}) ---")
        IO.puts("  Worker distributions:")
        for w <- run.workers do
          dist_str = @choices
            |> Enum.map(fn c ->
              v = w.dist[c]
              if v > 0.001, do: "#{c}:#{Float.round(v * 100, 1)}%", else: nil
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" ")
          top_conf = w.dist |> Map.values() |> Enum.max()
          bell_wt = :math.exp(-((top_conf - @bell_mu) * (top_conf - @bell_mu)) / (2.0 * @bell_sigma * @bell_sigma))
          h = entropy(w.dist) / :math.log(length(@choices))
          correct_mark = if top_answer(w.dist) == run.correct, do: " ✅", else: ""
          IO.puts("    #{String.pad_trailing(w.model, 20)} #{String.pad_trailing(dist_str, 45)} " <>
            "[H=#{Float.round(h, 3)} bell_wt=#{Float.round(bell_wt, 4)}]#{correct_mark}")
        end

        IO.puts("  Aggregated distributions (normalized):")
        for {name, _, _, dist} <- run.results do
          dist_str = @choices
            |> Enum.map(fn c ->
              v = dist[c]
              if v > 0.001, do: "#{c}:#{Float.round(v * 100, 1)}%", else: nil
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" ")
          winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
          mark = if winner == run.correct, do: " ✅", else: " ❌"
          IO.puts("    #{String.pad_trailing(name, 12)} #{dist_str}#{mark}")
        end
      end
    end
  end

  defp print_bell_curve_sweep(results) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("BELL CURVE PARAMETER SWEEP (μ × σ)")
    IO.puts("Testing which (μ, σ) configs crack which tests")
    IO.puts(String.duplicate("=", 100))

    mus = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]
    sigmas = [0.10, 0.15, 0.20, 0.25]

    for panel <- ["curated_5", "full_8"] do
      panel_results = Enum.filter(results, &(&1.config == panel))
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      IO.puts("\n--- #{panel_label} ---")

      # For each interesting test, find which (μ,σ) configs crack it
      interesting_tests = ["A1", "A3", "A4", "A7", "A8"]

      for test_id <- interesting_tests do
        test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
        correct = @correct_answers[test_id]

        cracking_configs =
          for mu <- mus, sigma <- sigmas do
            hits = Enum.count(test_runs, fn r ->
              {winner, _dist} = bell_curve(r.workers, mu, sigma)
              winner == correct
            end)
            {mu, sigma, hits, length(test_runs)}
          end
          |> Enum.filter(fn {_, _, hits, _} -> hits > 0 end)

        if cracking_configs != [] do
          best = Enum.max_by(cracking_configs, fn {_, _, h, _} -> h end)
          {best_mu, best_sigma, best_hits, total} = best

          # Get the P(correct) from the best config
          sample_run = hd(test_runs)
          {_, dist} = bell_curve(sample_run.workers, best_mu, best_sigma)
          p_correct = Float.round(dist[correct] * 100, 1)

          IO.puts("  #{test_id}: #{best_hits}/#{total} at best (μ=#{best_mu}, σ=#{best_sigma}), P(#{correct})=#{p_correct}%")
          other_hits = cracking_configs
            |> Enum.filter(fn {m, s, _, _} -> m != best_mu or s != best_sigma end)
            |> Enum.filter(fn {_, _, h, _} -> h > 0 end)
            |> Enum.map(fn {m, s, h, t} -> "μ=#{m},σ=#{s}:#{h}/#{t}" end)
          if other_hits != [], do: IO.puts("         Also: #{Enum.join(other_hits, " | ")}")
        else
          IO.puts("  #{test_id}: ❌ No (μ,σ) config cracks this test")
        end
      end
    end
  end

  defp print_key_findings(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("KEY FINDINGS")
    IO.puts(String.duplicate("=", 100))

    for panel <- ["curated_5", "full_8"] do
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      panel_results = Enum.filter(results, &(&1.config == panel))

      IO.puts("\n--- #{panel_label} ---")

      # Compare each method to majority
      maj_score = panel_results
        |> Enum.count(fn r ->
          Enum.find(r.results, fn {n, _, _, _} -> n == "Majority" end) |> elem(2)
        end)

      IO.puts("  Method scores (vs Majority #{maj_score}/24):")

      for {name, _} <- methods do
        score = panel_results
          |> Enum.count(fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
          end)
        delta = score - maj_score
        arrow = cond do
          delta > 0 -> "📈 +#{delta}"
          delta < 0 -> "📉 #{delta}"
          true -> "➡️  0"
        end
        IO.puts("    #{String.pad_trailing(name, 12)} #{score}/24 (#{Float.round(score / 24 * 100, 1)}%)  #{arrow}")
      end

      # Which tests does each method crack that majority doesn't?
      IO.puts("\n  Tests cracked beyond majority:")
      for {name, _} <- methods, name != "Majority" do
        upgrades =
          for test_id <- ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8"] do
            test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))

            maj_hits = Enum.count(test_runs, fn r ->
              Enum.find(r.results, fn {n, _, _, _} -> n == "Majority" end) |> elem(2)
            end)
            method_hits = Enum.count(test_runs, fn r ->
              Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
            end)

            if method_hits > maj_hits, do: "#{test_id}(+#{method_hits - maj_hits})", else: nil
          end
          |> Enum.reject(&is_nil/1)

        downgrades =
          for test_id <- ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8"] do
            test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))

            maj_hits = Enum.count(test_runs, fn r ->
              Enum.find(r.results, fn {n, _, _, _} -> n == "Majority" end) |> elem(2)
            end)
            method_hits = Enum.count(test_runs, fn r ->
              Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
            end)

            if method_hits < maj_hits, do: "#{test_id}(-#{maj_hits - method_hits})", else: nil
          end
          |> Enum.reject(&is_nil/1)

        if upgrades != [] or downgrades != [] do
          parts = []
          parts = if upgrades != [], do: parts ++ ["gains: #{Enum.join(upgrades, ", ")}"], else: parts
          parts = if downgrades != [], do: parts ++ ["losses: #{Enum.join(downgrades, ", ")}"], else: parts
          IO.puts("    #{String.pad_trailing(name, 12)} #{Enum.join(parts, " | ")}")
        end
      end
    end

    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("PRE-SIMULATION VALIDATION")
    IO.puts(String.duplicate("=", 100))

    curated = Enum.filter(results, &(&1.config == "curated_5"))
    full = Enum.filter(results, &(&1.config == "full_8"))

    predictions = [
      {"A7 cracked by PoE at 94.7%?", "A7", "PoE"},
      {"A3 flipped by Conf-Wt/MoE?", "A3", "Conf-Wt"},
      {"A8 cracked by PoE/LogOP?", "A8", "PoE"},
      {"A8 cracked by BellCurve (8-panel)?", "A8", "BellCurve"},
      {"A1 still fails (all methods)?", "A1", nil}
    ]

    for {label, test_id, method_name} <- predictions do
      if method_name do
        c5_hits = curated |> Enum.filter(&(&1.test_id == test_id))
          |> Enum.count(fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == method_name end) |> elem(2)
          end)
        f8_hits = full |> Enum.filter(&(&1.test_id == test_id))
          |> Enum.count(fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == method_name end) |> elem(2)
          end)
        mark = if c5_hits > 0 or f8_hits > 0, do: "✅", else: "❌"
        IO.puts("  #{mark} #{label} — curated #{method_name}: #{c5_hits}/3, full: #{f8_hits}/3")
      else
        # Check if ANY method on ANY panel cracks this test
        any_hit = results |> Enum.filter(&(&1.test_id == test_id))
          |> Enum.any?(fn r -> Enum.any?(r.results, fn {_, _, c, _} -> c end) end)
        mark = if any_hit, do: "❌ PREDICTION WRONG", else: "✅"
        IO.puts("  #{mark} #{label}")
      end
    end

    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("END OF PHASE 5G AGGREGATION ANALYSIS")
    IO.puts(String.duplicate("=", 100) <> "\n")
  end

  defp export_json(results, methods) do
    method_names = Enum.map(methods, fn {n, _} -> n end)

    export =
      for r <- results do
        %{
          run_id: r.run_id,
          test_id: r.test_id,
          trial: r.trial,
          config: r.config,
          correct: r.correct,
          methods: Map.new(r.results, fn {name, answer, correct, dist} ->
            {name, %{answer: answer, correct: correct, distribution: dist}}
          end)
        }
      end

    # Summary by panel × method
    summary =
      for panel <- ["curated_5", "full_8"] do
        panel_results = Enum.filter(results, &(&1.config == panel))
        method_scores = Map.new(method_names, fn name ->
          score = Enum.count(panel_results, fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
          end)
          {name, %{correct: score, total: length(panel_results), pct: Float.round(score / length(panel_results) * 100, 1)}}
        end)
        {panel, method_scores}
      end
      |> Map.new()

    output = %{
      phase: "5G-aggregation",
      description: "8 aggregation methods over 5G collective traces (0 Ollama calls)",
      bell_curve_params: %{mu: @bell_mu, sigma: @bell_sigma},
      per_run: export,
      summary: summary
    }

    path = Path.join([__DIR__, "benchmark_traces", "phase5g", "phase5g-aggregation-results.json"])
    File.write!(path, Jason.encode!(output, pretty: true))
    IO.puts("Results exported to: #{path}")
  end
end

Phase5G.Aggregation.run()
