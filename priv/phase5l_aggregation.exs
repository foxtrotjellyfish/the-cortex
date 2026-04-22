defmodule Phase5L.Aggregation do
  @moduledoc """
  Phase 5L aggregation: distribution-level methods over recomposed panel traces.
  Zero Ollama calls — pure Elixir math over existing logprobs distributions.

  Re-scores 72 collective runs (3 panels × 8 tests × 3 trials) through 8 methods.
  Key question: can any method crack BOTH A7 AND A8 on the same panel?

  Reads: priv/benchmark_traces/phase5l/phase5l-recomposition-summary.json
  """

  @choices ["A", "B", "C", "D"]
  @epsilon 1.0e-6
  @bell_mu 0.60
  @bell_sigma 0.10

  @correct_answers %{
    "A1" => "B", "A2" => "A", "A3" => "B", "A4" => "C",
    "A5" => "A", "A6" => "D", "A7" => "B", "A8" => "B"
  }

  def run do
    path = Path.join([__DIR__, "benchmark_traces", "phase5l", "phase5l-recomposition-summary.json"])
    data = path |> File.read!() |> Jason.decode!()
    collective = data["collective"]

    IO.puts(String.duplicate("=", 100))
    IO.puts("PHASE 5L AGGREGATION: 8 METHODS × 3 PANELS × 8 TESTS")
    IO.puts("Re-scoring #{length(collective)} collective runs from 5L traces — ZERO Ollama calls")
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

    panels = ["curated_6", "power_7", "coverage_8"]
    print_scorecard(results, methods, panels)
    print_cross_panel(results, methods, panels)
    print_a8_deep_dive(results, methods)
    print_bell_curve_sweep(results, panels)
    print_union_analysis(results, methods, panels)
    print_key_findings(results, methods, panels)
    export_json(results, methods, panels)
  end

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

  defp entropy(dist) do
    dist |> Map.values() |> Enum.filter(&(&1 > 0)) |> Enum.map(fn p -> -p * :math.log(p) end) |> Enum.sum()
  end

  defp top_answer(dist), do: dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)

  # --- Output ---

  defp print_scorecard(results, methods, panels) do
    method_names = Enum.map(methods, fn {n, _} -> n end)

    for panel <- panels do
      panel_results = Enum.filter(results, &(&1.config == panel))

      IO.puts("\n" <> String.duplicate("=", 100))
      IO.puts("SCORECARD: #{String.upcase(panel)}")
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
          if hits > 0, do: "** #{score}", else: "   #{score}"
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

  defp print_cross_panel(results, methods, panels) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("CROSS-PANEL: Best method per panel")
    IO.puts(String.duplicate("=", 100))

    for panel <- panels do
      panel_results = Enum.filter(results, &(&1.config == panel))

      best = methods
        |> Enum.map(fn {name, _} ->
          score = Enum.count(panel_results, fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
          end)
          {name, score}
        end)
        |> Enum.max_by(fn {_, s} -> s end)

      {best_name, best_score} = best
      pct = Float.round(best_score / length(panel_results) * 100, 1)
      IO.puts("  #{String.pad_trailing(panel, 15)} #{best_name}: #{best_score}/24 (#{pct}%)")
    end
  end

  defp print_a8_deep_dive(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("A8 (Modified CRT) DEEP DIVE — Per-method performance across panels")
    IO.puts(String.duplicate("=", 100))

    for panel <- ["curated_6", "power_7", "coverage_8"] do
      a8_runs = results |> Enum.filter(&(&1.config == panel and &1.test_id == "A8"))

      IO.puts("\n--- #{panel} ---")

      for {name, _} <- methods do
        hits = Enum.count(a8_runs, fn r ->
          Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
        end)

        sample = hd(a8_runs)
        {_, _, _, dist} = Enum.find(sample.results, fn {n, _, _, _} -> n == name end)
        p_b = Float.round(dist["B"] * 100, 1)
        p_top = dist |> Enum.max_by(fn {_c, v} -> v end)
        {top_c, top_v} = p_top

        mark = if hits > 0, do: "**", else: "  "
        IO.puts("  #{mark}#{String.pad_trailing(name, 12)} #{hits}/3  P(B)=#{p_b}%  top=#{top_c}(#{Float.round(top_v * 100, 1)}%)")
      end
    end

    IO.puts("\n  Worker distributions (curated_6, T1):")
    c6_a8 = results |> Enum.find(&(&1.config == "curated_6" and &1.test_id == "A8" and &1.trial == 1))
    if c6_a8 do
      for w <- c6_a8.workers do
        dist_str = @choices
          |> Enum.map(fn c ->
            v = w.dist[c]
            if v > 0.001, do: "#{c}:#{Float.round(v * 100, 1)}%", else: nil
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" ")
        top_conf = w.dist |> Map.values() |> Enum.max()
        bell_wt = :math.exp(-((top_conf - @bell_mu) * (top_conf - @bell_mu)) / (2.0 * @bell_sigma * @bell_sigma))
        correct_mark = if top_answer(w.dist) == "B", do: " <<B>>", else: ""
        IO.puts("    #{String.pad_trailing(w.model, 22)} #{String.pad_trailing(dist_str, 50)} bell_wt=#{Float.round(bell_wt, 4)}#{correct_mark}")
      end
    end
  end

  defp print_bell_curve_sweep(results, panels) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("BELL CURVE PARAMETER SWEEP (μ × σ) — A7 + A8 focus")
    IO.puts(String.duplicate("=", 100))

    mus = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70]
    sigmas = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30]

    for panel <- panels do
      panel_results = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n--- #{panel} ---")

      best_total = 0
      best_config = nil

      combos =
        for mu <- mus, sigma <- sigmas do
          total_hits = Enum.count(panel_results, fn r ->
            {winner, _} = bell_curve(r.workers, mu, sigma)
            winner == @correct_answers[r.test_id]
          end)

          a7_hits = panel_results |> Enum.filter(&(&1.test_id == "A7"))
            |> Enum.count(fn r -> {w, _} = bell_curve(r.workers, mu, sigma); w == "B" end)
          a8_hits = panel_results |> Enum.filter(&(&1.test_id == "A8"))
            |> Enum.count(fn r -> {w, _} = bell_curve(r.workers, mu, sigma); w == "B" end)

          {mu, sigma, total_hits, a7_hits, a8_hits}
        end

      {best_mu, best_sigma, best_hits, _, _} = Enum.max_by(combos, fn {_, _, t, _, _} -> t end)
      IO.puts("  Best overall: μ=#{best_mu}, σ=#{best_sigma} → #{best_hits}/24 (#{Float.round(best_hits / 24 * 100, 1)}%)")

      both_a7_a8 = Enum.filter(combos, fn {_, _, _, a7, a8} -> a7 > 0 and a8 > 0 end)
      if both_a7_a8 != [] do
        best_both = Enum.max_by(both_a7_a8, fn {_, _, t, _, _} -> t end)
        {bm, bs, bt, ba7, ba8} = best_both
        IO.puts("  ** BOTH A7+A8: μ=#{bm}, σ=#{bs} → #{bt}/24 (A7:#{ba7}/3, A8:#{ba8}/3)")
      else
        IO.puts("  No bell curve config cracks both A7 and A8 on this panel")
      end

      IO.puts("\n  A7/A8 grid:")
      IO.puts("  #{String.pad_trailing("μ\\σ", 8)}" <> Enum.map_join(sigmas, "", fn s -> String.pad_trailing("σ=#{s}", 12) end))
      for mu <- mus do
        row = for sigma <- sigmas do
          {_, _, _, a7, a8} = Enum.find(combos, fn {m, s, _, _, _} -> m == mu and s == sigma end)
          "A7:#{a7} A8:#{a8}"
        end
        IO.puts("  #{String.pad_trailing("μ=#{mu}", 8)}" <> Enum.map_join(row, "", fn s -> String.pad_trailing(s, 12) end))
      end
    end
  end

  defp print_union_analysis(results, methods, panels) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("META-AGGREGATION: Union of methods per panel")
    IO.puts("If ANY method gets a test right, that test is 'cracked'")
    IO.puts(String.duplicate("=", 100))

    for panel <- panels do
      panel_results = Enum.filter(results, &(&1.config == panel))

      cracked =
        for test_id <- ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8"] do
          test_runs = Enum.filter(panel_results, &(&1.test_id == test_id))
          any_cracked = Enum.any?(test_runs, fn r ->
            Enum.any?(r.results, fn {_, _, c, _} -> c end)
          end)

          crackers = if any_cracked do
            for {name, _} <- methods do
              hits = Enum.count(test_runs, fn r ->
                Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
              end)
              if hits > 0, do: "#{name}(#{hits}/3)", else: nil
            end |> Enum.reject(&is_nil/1)
          else
            []
          end

          {test_id, any_cracked, crackers}
        end

      total_cracked = Enum.count(cracked, fn {_, c, _} -> c end)
      IO.puts("\n--- #{panel}: #{total_cracked}/8 tests cracked (union) ---")
      for {test_id, c, crackers} <- cracked do
        mark = if c, do: "**", else: "  "
        crackers_str = if crackers != [], do: Enum.join(crackers, ", "), else: "—"
        IO.puts("  #{mark}#{test_id}: #{crackers_str}")
      end
    end
  end

  defp print_key_findings(results, methods, panels) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("KEY FINDINGS")
    IO.puts(String.duplicate("=", 100))

    for panel <- panels do
      panel_results = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n--- #{panel} ---")

      for {name, _} <- methods do
        score = Enum.count(panel_results, fn r ->
          Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
        end)
        pct = Float.round(score / 24 * 100, 1)
        marker = cond do
          pct > 75 -> " *** NEW RECORD ***"
          pct >= 75 -> " ** TIES RECORD **"
          pct > 66.7 -> " * above power_7 raw"
          true -> ""
        end
        IO.puts("    #{String.pad_trailing(name, 12)} #{score}/24 (#{pct}%)#{marker}")
      end
    end

    IO.puts("\n  Reference scores:")
    IO.puts("    5G curated 5 weighted: 15/24 (62.5%)")
    IO.puts("    5H curated 5 Conf-Wt:  18/24 (75.0%) — project record")
    IO.puts("    5L power 7 weighted:   16/24 (66.7%) — new raw collective record")

    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("END OF PHASE 5L AGGREGATION ANALYSIS")
    IO.puts(String.duplicate("=", 100) <> "\n")
  end

  defp export_json(results, methods, panels) do
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

    summary =
      for panel <- panels do
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
      phase: "5L-aggregation",
      description: "8 aggregation methods over 5L recomposed panel traces (0 Ollama calls)",
      bell_curve_params: %{mu: @bell_mu, sigma: @bell_sigma},
      per_run: export,
      summary: summary
    }

    path = Path.join([__DIR__, "benchmark_traces", "phase5l", "phase5l-aggregation-results.json"])
    File.write!(path, Jason.encode!(output, pretty: true))
    IO.puts("Results exported to: #{path}")
  end
end

Phase5L.Aggregation.run()
