defmodule Phase5H.Aggregation do
  @moduledoc """
  Phase 5H aggregation: distribution-level methods over 5H escape-hatch-removed
  collective traces. Zero Ollama calls — pure Elixir math.

  Adapts the 5G aggregation script to handle variable choice counts:
  modified tests (A1, A2, A4) have 3 options (A/B/C),
  control tests (A3, A5, A6, A7, A8) have 4 options (A/B/C/D).

  Reads: priv/benchmark_traces/phase5h/phase5h-summary.json
  """

  @epsilon 1.0e-6

  @bell_mu 0.60
  @bell_sigma 0.10

  @correct_answers %{
    "A1" => "B", "A2" => "A", "A3" => "B", "A4" => "C",
    "A5" => "A", "A6" => "D", "A7" => "B", "A8" => "B"
  }

  @test_order ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8"]

  def run do
    path = Path.join([__DIR__, "benchmark_traces", "phase5h", "phase5h-summary.json"])
    data = path |> File.read!() |> Jason.decode!()
    collective = data["collective"]

    IO.puts(String.duplicate("=", 100))
    IO.puts("PHASE 5H AGGREGATION: 8 METHODS × 2 PANELS × 8 TESTS (escape hatch removed)")
    IO.puts("Re-scoring #{length(collective)} collective runs from 5H traces — ZERO Ollama calls")
    IO.puts("Modified tests (3 options): A1, A2, A4 | Control tests (4 options): A3, A5, A6, A7, A8")
    IO.puts(String.duplicate("=", 100))

    methods = [
      {"Majority", &majority_vote/2},
      {"Conf-Wt", &confidence_weighted/2},
      {"MoE", &moe_uniform/2},
      {"Ent-Wt", &entropy_weighted_moe/2},
      {"Ent-Gate", &entropy_gated/2},
      {"PoE", &poe_smoothed/2},
      {"LogOP", &log_opinion_pool/2},
      {"BellCurve", &bell_curve_default/2}
    ]

    results =
      for run <- collective do
        choices = run["choices"]
        workers = normalize_workers(run["per_worker"], choices)
        correct = run["correct_answer"] || @correct_answers[run["test_id"]]

        method_results =
          for {name, func} <- methods do
            {answer, dist} = func.(workers, choices)
            {name, answer, answer == correct, dist}
          end

        %{
          config: run["config"],
          test_id: run["test_id"],
          trial: run["trial"],
          run_id: run["run_id"],
          correct: correct,
          modified: run["modified"],
          choices: choices,
          results: method_results,
          workers: workers
        }
      end

    print_scorecard(results, methods)
    print_5g_comparison(results, methods)
    print_5h_vs_5g_delta(results, methods)
    print_distribution_deep_dive(results)
    print_bell_curve_sweep(results)
    print_meta_aggregation(results, methods)
    print_key_findings(results, methods)
    export_json(results, methods)
  end

  # --- Aggregation Methods ---
  # Each takes (workers, choices) and returns {winner, distribution}

  defp normalize_workers(per_worker, choices) do
    Enum.map(per_worker, fn w ->
      probs = w["probabilities"]
      dist = Map.new(choices, fn c -> {c, Map.get(probs, c, 0.0)} end)
      total = dist |> Map.values() |> Enum.sum()
      dist = if total > 0, do: Map.new(dist, fn {k, v} -> {k, v / total} end), else: dist
      %{model: w["model"], dist: dist, confidence: w["confidence"] || 0.0}
    end)
  end

  defp majority_vote(workers, choices) do
    votes = workers |> Enum.map(fn w -> top_answer(w.dist) end) |> Enum.frequencies()
    dist = Map.new(choices, fn c -> {c, Map.get(votes, c, 0) / length(workers)} end)
    winner = votes |> Enum.max_by(fn {_a, n} -> n end) |> elem(0)
    {winner, dist}
  end

  defp confidence_weighted(workers, choices) do
    dist = Map.new(choices, fn c ->
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

  defp moe_uniform(workers, choices) do
    n = length(workers)
    dist = Map.new(choices, fn c ->
      {c, workers |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)}
    end)
    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist}
  end

  defp entropy_weighted_moe(workers, choices) do
    max_h = :math.log(length(choices))
    weights = Enum.map(workers, fn w ->
      h = entropy(w.dist)
      1.0 / (h / max_h + @epsilon)
    end)
    total_w = Enum.sum(weights)

    dist = Map.new(choices, fn c ->
      val = Enum.zip(workers, weights)
        |> Enum.map(fn {w, wt} -> w.dist[c] * wt end)
        |> Enum.sum()
        |> Kernel./(total_w)
      {c, val}
    end)
    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist}
  end

  defp entropy_gated(workers, choices) do
    max_h = :math.log(length(choices))
    threshold = 0.85

    active = Enum.filter(workers, fn w -> entropy(w.dist) / max_h < threshold end)

    if active == [] do
      moe_uniform(workers, choices)
    else
      n = length(active)
      dist = Map.new(choices, fn c ->
        {c, active |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)}
      end)
      winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
      {winner, dist}
    end
  end

  defp poe_smoothed(workers, choices) do
    raw = Map.new(choices, fn c ->
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

  defp log_opinion_pool(workers, choices) do
    n = length(workers)
    raw = Map.new(choices, fn c ->
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

  defp bell_curve_default(workers, choices), do: bell_curve(workers, choices, @bell_mu, @bell_sigma)

  defp bell_curve(workers, choices, mu, sigma) do
    weights = Enum.map(workers, fn w ->
      top_conf = w.dist |> Map.values() |> Enum.max()
      :math.exp(-((top_conf - mu) * (top_conf - mu)) / (2.0 * sigma * sigma))
    end)
    total_w = Enum.sum(weights)

    if total_w < @epsilon do
      moe_uniform(workers, choices)
    else
      dist = Map.new(choices, fn c ->
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
        String.pad_trailing("Mod?", 6) <>
        String.pad_trailing("Correct", 9) <>
        Enum.map_join(method_names, "", fn n -> String.pad_trailing(n, 12) end)
      IO.puts(header)
      IO.puts(String.duplicate("-", String.length(header)))

      for test_id <- @test_order do
        test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
        correct = @correct_answers[test_id]
        mod = if hd(test_runs).modified, do: "YES", else: "no"

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
          String.pad_trailing(mod, 6) <>
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
        String.pad_trailing("TOTAL", 21) <>
        Enum.map_join(totals, "", fn s -> String.pad_trailing(s, 12) end)
      )
    end
  end

  defp print_5g_comparison(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("5H vs 5G AGGREGATION COMPARISON (same methods, different data)")
    IO.puts("5G had 4-option MC for all tests. 5H removed hedges from A1/A2/A4.")
    IO.puts(String.duplicate("=", 100))

    baseline_5g_curated = %{
      "Majority" => 9, "Conf-Wt" => 15, "MoE" => 15, "Ent-Wt" => 12,
      "Ent-Gate" => 15, "PoE" => 15, "LogOP" => 15, "BellCurve" => 9
    }
    baseline_5g_full = %{
      "Majority" => 9, "Conf-Wt" => 9, "MoE" => 9, "Ent-Wt" => 6,
      "Ent-Gate" => 6, "PoE" => 6, "LogOP" => 6, "BellCurve" => 6
    }

    for {panel, baseline} <- [{"curated_5", baseline_5g_curated}, {"full_8", baseline_5g_full}] do
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      panel_results = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n--- #{panel_label} ---")
      IO.puts("  #{String.pad_trailing("Method", 12)} #{String.pad_trailing("5H", 14)} #{String.pad_trailing("5G", 14)} Delta")
      IO.puts("  " <> String.duplicate("-", 55))

      for {name, _} <- methods do
        h5 = panel_results
          |> Enum.count(fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
          end)
        g5 = baseline[name]
        delta = h5 - g5
        arrow = cond do
          delta > 0 -> "📈 +#{delta}"
          delta < 0 -> "📉 #{delta}"
          true -> "➡️  0"
        end
        IO.puts("  #{String.pad_trailing(name, 12)} #{String.pad_trailing("#{h5}/24 (#{Float.round(h5/24*100,1)}%)", 14)} #{String.pad_trailing("#{g5}/24 (#{Float.round(g5/24*100,1)}%)", 14)} #{arrow}")
      end
    end
  end

  defp print_5h_vs_5g_delta(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("PER-TEST DELTA: 5H vs 5G (which tests flipped?)")
    IO.puts(String.duplicate("=", 100))

    baseline_5g_curated_per_test = %{
      "Majority" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 0, "A8" => 0},
      "Conf-Wt" => %{"A1" => 0, "A2" => 3, "A3" => 3, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 3, "A8" => 0},
      "MoE" => %{"A1" => 0, "A2" => 3, "A3" => 3, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 3, "A8" => 0},
      "Ent-Wt" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 3, "A8" => 0},
      "Ent-Gate" => %{"A1" => 0, "A2" => 3, "A3" => 3, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 3, "A8" => 0},
      "PoE" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 3, "A8" => 3},
      "LogOP" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 3, "A8" => 3},
      "BellCurve" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 3, "A5" => 0, "A6" => 0, "A7" => 0, "A8" => 3}
    }
    baseline_5g_full_per_test = %{
      "Majority" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 0, "A8" => 0},
      "Conf-Wt" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 0, "A8" => 0},
      "MoE" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 3, "A7" => 0, "A8" => 0},
      "Ent-Wt" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 0, "A7" => 0, "A8" => 0},
      "Ent-Gate" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 0, "A7" => 0, "A8" => 0},
      "PoE" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 0, "A7" => 0, "A8" => 0},
      "LogOP" => %{"A1" => 0, "A2" => 3, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 0, "A7" => 0, "A8" => 0},
      "BellCurve" => %{"A1" => 0, "A2" => 0, "A3" => 0, "A4" => 0, "A5" => 3, "A6" => 0, "A7" => 0, "A8" => 3}
    }

    for {panel, baselines} <- [{"curated_5", baseline_5g_curated_per_test}, {"full_8", baseline_5g_full_per_test}] do
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      panel_results = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n--- #{panel_label} ---")

      for {name, _} <- methods do
        flips =
          for test_id <- @test_order do
            test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
            h5 = Enum.count(test_runs, fn r ->
              Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
            end)
            g5 = baselines[name][test_id]
            delta = h5 - g5
            if delta != 0, do: {test_id, delta, hd(test_runs).modified}, else: nil
          end
          |> Enum.reject(&is_nil/1)

        if flips != [] do
          flip_strs = Enum.map(flips, fn {tid, d, mod} ->
            mod_tag = if mod, do: "*", else: ""
            if d > 0, do: "#{tid}#{mod_tag}(+#{d})", else: "#{tid}#{mod_tag}(#{d})"
          end)
          IO.puts("  #{String.pad_trailing(name, 12)} #{Enum.join(flip_strs, " ")}")
        end
      end
      IO.puts("  (* = modified test, hedge removed)")
    end
  end

  defp print_distribution_deep_dive(results) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("DISTRIBUTION DEEP DIVE — Modified Tests (Trial 1)")
    IO.puts("Comparing worker distributions with escape hatches removed")
    IO.puts(String.duplicate("=", 100))

    for panel <- ["curated_5", "full_8"] do
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      panel_t1 = results
        |> Enum.filter(&(&1.config == panel and &1.trial == 1))

      IO.puts("\n=== #{panel_label} ===")

      for test_id <- ["A1", "A2", "A4"] do
        run = Enum.find(panel_t1, &(&1.test_id == test_id))
        if run do
          IO.puts("\n--- #{test_id} (correct: #{run.correct}, #{length(run.choices)} options) ---")
          IO.puts("  Worker distributions:")
          for w <- run.workers do
            dist_str = run.choices
              |> Enum.map(fn c ->
                v = w.dist[c]
                if v > 0.001, do: "#{c}:#{Float.round(v * 100, 1)}%", else: nil
              end)
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" ")
            top_conf = w.dist |> Map.values() |> Enum.max()
            bell_wt = :math.exp(-((top_conf - @bell_mu) * (top_conf - @bell_mu)) / (2.0 * @bell_sigma * @bell_sigma))
            correct_mark = if top_answer(w.dist) == run.correct, do: " ✅", else: ""
            IO.puts("    #{String.pad_trailing(w.model, 20)} #{String.pad_trailing(dist_str, 45)} " <>
              "[bell_wt=#{Float.round(bell_wt, 4)}]#{correct_mark}")
          end

          IO.puts("  Aggregated distributions:")
          for {name, _, correct?, dist} <- run.results do
            dist_str = run.choices
              |> Enum.map(fn c ->
                v = dist[c]
                if v > 0.001, do: "#{c}:#{Float.round(v * 100, 1)}%", else: nil
              end)
              |> Enum.reject(&is_nil/1)
              |> Enum.join(" ")
            mark = if correct?, do: " ✅", else: " ❌"
            IO.puts("    #{String.pad_trailing(name, 12)} #{dist_str}#{mark}")
          end
        end
      end
    end
  end

  defp print_bell_curve_sweep(results) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("BELL CURVE PARAMETER SWEEP (μ × σ) — 5H Data")
    IO.puts(String.duplicate("=", 100))

    mus = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]
    sigmas = [0.10, 0.15, 0.20, 0.25]

    for panel <- ["curated_5", "full_8"] do
      panel_results = Enum.filter(results, &(&1.config == panel))
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      IO.puts("\n--- #{panel_label} ---")

      interesting_tests = ["A1", "A3", "A4", "A7", "A8"]

      for test_id <- interesting_tests do
        test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
        correct = @correct_answers[test_id]
        choices = hd(test_runs).choices

        cracking_configs =
          for mu <- mus, sigma <- sigmas do
            hits = Enum.count(test_runs, fn r ->
              {winner, _dist} = bell_curve(r.workers, choices, mu, sigma)
              winner == correct
            end)
            {mu, sigma, hits, length(test_runs)}
          end
          |> Enum.filter(fn {_, _, hits, _} -> hits > 0 end)

        mod_tag = if hd(test_runs).modified, do: " [MODIFIED]", else: ""

        if cracking_configs != [] do
          best = Enum.max_by(cracking_configs, fn {_, _, h, _} -> h end)
          {best_mu, best_sigma, best_hits, total} = best

          sample_run = hd(test_runs)
          {_, dist} = bell_curve(sample_run.workers, choices, best_mu, best_sigma)
          p_correct = Float.round(dist[correct] * 100, 1)

          IO.puts("  #{test_id}#{mod_tag}: #{best_hits}/#{total} at best (μ=#{best_mu}, σ=#{best_sigma}), P(#{correct})=#{p_correct}%")
          configs_count = length(cracking_configs)
          IO.puts("         #{configs_count}/#{length(mus) * length(sigmas)} configs crack this test")
        else
          IO.puts("  #{test_id}#{mod_tag}: ❌ No (μ,σ) config cracks this test")
        end
      end
    end
  end

  defp print_meta_aggregation(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("META-AGGREGATION: UNION OF ALL METHODS")
    IO.puts("If we could pick the best method per test, what's the ceiling?")
    IO.puts(String.duplicate("=", 100))

    for panel <- ["curated_5", "full_8"] do
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      panel_results = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n--- #{panel_label} ---")

      for test_id <- @test_order do
        test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
        mod_tag = if hd(test_runs).modified, do: " [MOD]", else: ""

        solvers =
          for {name, _} <- methods do
            hits = Enum.count(test_runs, fn r ->
              Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
            end)
            if hits > 0, do: "#{name}(#{hits}/3)", else: nil
          end
          |> Enum.reject(&is_nil/1)

        if solvers == [] do
          IO.puts("  #{test_id}#{mod_tag}: ❌ UNSOLVED by all methods")
        else
          IO.puts("  #{test_id}#{mod_tag}: ✅ #{Enum.join(solvers, ", ")}")
        end
      end

      solved = @test_order |> Enum.count(fn test_id ->
        test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
        Enum.any?(test_runs, fn r ->
          Enum.any?(r.results, fn {_, _, c, _} -> c end)
        end)
      end)

      IO.puts("\n  META-AGGREGATION CEILING: #{solved}/8 tests solvable (#{Float.round(solved/8*100, 1)}%)")
    end
  end

  defp print_key_findings(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("KEY FINDINGS — PHASE 5H AGGREGATION")
    IO.puts(String.duplicate("=", 100))

    for panel <- ["curated_5", "full_8"] do
      panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
      panel_results = Enum.filter(results, &(&1.config == panel))

      IO.puts("\n--- #{panel_label} ---")

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
    end

    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("END OF PHASE 5H AGGREGATION ANALYSIS")
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
          modified: r.modified,
          choices: r.choices,
          methods: Map.new(r.results, fn {name, answer, correct, dist} ->
            {name, %{answer: answer, correct: correct, distribution: dist}}
          end)
        }
      end

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
      phase: "5H-aggregation",
      description: "8 aggregation methods over 5H escape-hatch-removed traces (0 Ollama calls)",
      bell_curve_params: %{mu: @bell_mu, sigma: @bell_sigma},
      modified_tests: ["A1", "A2", "A4"],
      per_run: export,
      summary: summary
    }

    path = Path.join([__DIR__, "benchmark_traces", "phase5h", "phase5h-aggregation-results.json"])
    File.write!(path, Jason.encode!(output, pretty: true))
    IO.puts("Results exported to: #{path}")
  end
end

Phase5H.Aggregation.run()
