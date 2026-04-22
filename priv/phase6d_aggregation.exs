defmodule Phase6D.Aggregation do
  @moduledoc """
  Phase 6D: Offline aggregation analysis + JSD diagnostics on 6C MedQA traces.
  Zero Ollama calls — pure Elixir math over 300 collective runs (3 panels × 100 Qs).

  Applies 8 aggregation methods to per-worker probability distributions from 6C.
  Computes JSD-based consensus diagnostics per question.
  Answers: does any method beat phi3 solo (53%)? Is the aggregation landscape
  different from gotchas? Does JSD flag genuine disagreement? Bell curve niche?
  Meta-union oracle ceiling?

  Reads: priv/benchmark_traces/phase6c/phase6c-collective-summary.json
  """

  @choices ["A", "B", "C", "D"]
  @epsilon 1.0e-6
  @bell_mu 0.60
  @bell_sigma 0.10
  @phi3_solo 53

  def run do
    path = Path.join([__DIR__, "benchmark_traces", "phase6c", "phase6c-collective-summary.json"])
    data = path |> File.read!() |> Jason.decode!()
    collective = data["collective"]

    IO.puts(String.duplicate("=", 110))
    IO.puts("PHASE 6D AGGREGATION: 8 METHODS × 3 PANELS × 100 MedQA QUESTIONS")
    IO.puts("Re-scoring #{length(collective)} collective runs from 6C traces — ZERO Ollama calls")
    IO.puts(String.duplicate("=", 110))

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
        correct = run["correct_answer"]

        method_results =
          for {name, func} <- methods do
            {answer, dist} = func.(workers)
            {name, answer, answer == correct, dist}
          end

        jsd = compute_jsd(workers)
        n_eff = compute_effective_n(workers)

        %{
          config: run["config"],
          test_id: run["test_id"],
          trial: run["trial"],
          run_id: run["run_id"],
          correct: correct,
          majority_answer: run["majority_answer"],
          weighted_answer: run["weighted_answer"],
          majority_correct: run["majority_correct"],
          weighted_correct: run["weighted_correct"],
          results: method_results,
          workers: workers,
          jsd: jsd,
          n_eff: n_eff
        }
      end

    panels = ["gotcha_curated_6", "power_7", "medqa_informed"]

    print_headline_scores(results, methods, panels)
    print_vs_solo(results, methods, panels)
    print_per_question_comparison(results, methods, panels)
    print_disagreement_analysis(results, methods, panels)
    print_jsd_analysis(results, panels)
    print_bell_curve_sweep(results, panels)
    print_oracle_analysis(results, methods, panels)
    print_method_complementarity(results, methods, panels)
    print_gotcha_comparison(methods)
    print_key_findings(results, methods, panels)
    export_json(results, methods, panels)
  end

  # --- Aggregation Methods ---

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

  # --- JSD / Consensus Diagnostics ---

  defp compute_jsd(workers) do
    n = length(workers)
    mean_dist = Map.new(@choices, fn c ->
      {c, workers |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)}
    end)

    divergences = Enum.map(workers, fn w ->
      kl_divergence(w.dist, mean_dist)
    end)

    Enum.sum(divergences) / n
  end

  defp compute_effective_n(workers) do
    n = length(workers)
    if n <= 1, do: n / 1.0, else: compute_n_eff(workers, n)
  end

  defp compute_n_eff(workers, n) do
    pairs =
      for i <- 0..(n - 2), j <- (i + 1)..(n - 1) do
        wi = Enum.at(workers, i)
        wj = Enum.at(workers, j)
        cosine_similarity(wi.dist, wj.dist)
      end

    avg_sim = if pairs == [], do: 0.0, else: Enum.sum(pairs) / length(pairs)
    n / (1.0 + (n - 1) * max(avg_sim, 0.0))
  end

  defp kl_divergence(p, q) do
    @choices
    |> Enum.map(fn c ->
      pv = max(p[c], @epsilon)
      qv = max(q[c], @epsilon)
      pv * :math.log(pv / qv)
    end)
    |> Enum.sum()
  end

  defp cosine_similarity(d1, d2) do
    dot = @choices |> Enum.map(fn c -> d1[c] * d2[c] end) |> Enum.sum()
    mag1 = @choices |> Enum.map(fn c -> d1[c] * d1[c] end) |> Enum.sum() |> :math.sqrt()
    mag2 = @choices |> Enum.map(fn c -> d2[c] * d2[c] end) |> Enum.sum() |> :math.sqrt()
    if mag1 * mag2 > 0, do: dot / (mag1 * mag2), else: 0.0
  end

  defp entropy(dist) do
    dist |> Map.values() |> Enum.filter(&(&1 > 0)) |> Enum.map(fn p -> -p * :math.log(p) end) |> Enum.sum()
  end

  defp top_answer(dist), do: dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)

  # --- Output Sections ---

  defp print_headline_scores(results, methods, panels) do
    method_names = Enum.map(methods, fn {n, _} -> n end)

    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("HEADLINE: ACCURACY BY PANEL × METHOD (out of 100)")
    IO.puts(String.duplicate("=", 110))

    header = String.pad_trailing("Panel", 22) <>
      Enum.map_join(method_names, "", fn n -> String.pad_trailing(n, 12) end) <>
      "phi3 solo"
    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    for panel <- panels do
      pr = Enum.filter(results, &(&1.config == panel))

      scores = for {name, _} <- methods do
        hits = Enum.count(pr, fn r ->
          Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
        end)
        hits
      end

      row = String.pad_trailing(panel, 22) <>
        Enum.map_join(scores, "", fn s ->
          marker = if s > @phi3_solo, do: "**#{s}**", else: "#{s}"
          String.pad_trailing(marker, 12)
        end) <>
        "#{@phi3_solo}"
      IO.puts(row)
    end

    IO.puts(String.duplicate("-", String.length(header)))
    IO.puts("  ** = beats phi3 solo (#{@phi3_solo}%). Bold if any method exceeds solo baseline.\n")
  end

  defp print_vs_solo(results, methods, panels) do
    IO.puts(String.duplicate("=", 110))
    IO.puts("KEY QUESTION 1: Does any method beat phi3 solo (53%)?")
    IO.puts(String.duplicate("=", 110))

    any_beat = false

    for panel <- panels do
      pr = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n  --- #{panel} ---")

      for {name, _} <- methods do
        hits = Enum.count(pr, fn r ->
          Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
        end)
        delta = hits - @phi3_solo
        arrow = cond do
          delta > 0 -> "BEATS SOLO (+#{delta}pp)"
          delta == 0 -> "TIES SOLO"
          true -> "(#{delta}pp)"
        end
        IO.puts("    #{String.pad_trailing(name, 12)} #{hits}/100 #{arrow}")
      end
    end
  end

  defp print_per_question_comparison(results, methods, panels) do
    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("PER-QUESTION METHOD DIVERGENCE: Where methods disagree with majority")
    IO.puts(String.duplicate("=", 110))

    for panel <- panels do
      pr = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n  --- #{panel} ---")

      upgrades_total = 0
      downgrades_total = 0

      for {name, _} <- methods, name != "Majority" do
        upgrade_qs = Enum.filter(pr, fn r ->
          {_, _, maj_correct, _} = Enum.find(r.results, fn {n, _, _, _} -> n == "Majority" end)
          {_, _, method_correct, _} = Enum.find(r.results, fn {n, _, _, _} -> n == name end)
          method_correct and not maj_correct
        end)

        downgrade_qs = Enum.filter(pr, fn r ->
          {_, _, maj_correct, _} = Enum.find(r.results, fn {n, _, _, _} -> n == "Majority" end)
          {_, _, method_correct, _} = Enum.find(r.results, fn {n, _, _, _} -> n == name end)
          maj_correct and not method_correct
        end)

        net = length(upgrade_qs) - length(downgrade_qs)
        direction = cond do
          net > 0 -> "NET +#{net}"
          net < 0 -> "NET #{net}"
          true -> "NET 0"
        end

        IO.puts("    #{String.pad_trailing(name, 12)} +#{length(upgrade_qs)} gains, -#{length(downgrade_qs)} losses = #{direction}")

        if upgrade_qs != [] do
          ids = upgrade_qs |> Enum.map(& &1.test_id) |> Enum.sort() |> Enum.join(", ")
          IO.puts("      Gains: #{ids}")
        end
      end
    end
  end

  defp print_disagreement_analysis(results, methods, panels) do
    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("CROSS-PANEL DISAGREEMENT: The 39 questions where panels diverge")
    IO.puts(String.duplicate("=", 110))

    test_ids =
      results
      |> Enum.map(& &1.test_id)
      |> Enum.uniq()
      |> Enum.sort()

    disagree_tests = Enum.filter(test_ids, fn tid ->
      answers = for panel <- panels do
        run = Enum.find(results, &(&1.config == panel and &1.test_id == tid))
        if run, do: run.majority_answer, else: nil
      end
      length(Enum.uniq(answers)) > 1
    end)

    IO.puts("  #{length(disagree_tests)} questions with cross-panel majority disagreement\n")

    IO.puts("  " <> String.pad_trailing("Test", 14) <>
      Enum.map_join(panels, "", fn p -> String.pad_trailing(p, 22) end) <>
      "Correct  Best method?")
    IO.puts("  " <> String.duplicate("-", 110))

    best_method_wins = 0

    for tid <- disagree_tests do
      runs = for panel <- panels do
        Enum.find(results, &(&1.config == panel and &1.test_id == tid))
      end

      correct = (hd(runs)).correct

      cells = for run <- runs do
        if run do
          any_method_correct = Enum.any?(run.results, fn {_, _, c, _} -> c end)
          mark = if run.majority_correct, do: "Maj-OK", else: "Maj-X"
          best = if any_method_correct and not run.majority_correct do
            winning = run.results |> Enum.filter(fn {_, _, c, _} -> c end) |> Enum.map(fn {n, _, _, _} -> n end)
            "#{mark} [#{Enum.join(winning, ",")}]"
          else
            mark
          end
          best
        else
          "—"
        end
      end

      any_method_beats_all_maj = Enum.any?(runs, fn run ->
        run && not run.majority_correct && Enum.any?(run.results, fn {_, _, c, _} -> c end)
      end)

      IO.puts("  " <> String.pad_trailing(tid, 14) <>
        Enum.map_join(cells, "", fn c -> String.pad_trailing(c, 22) end) <>
        correct <>
        if(any_method_beats_all_maj, do: "  *", else: ""))
    end
  end

  defp print_jsd_analysis(results, panels) do
    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("JSD ANALYSIS: Does high JSD flag genuine disagreement vs shared ignorance?")
    IO.puts(String.duplicate("=", 110))

    for panel <- panels do
      pr = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n  --- #{panel} ---")

      correct_runs = Enum.filter(pr, & &1.majority_correct)
      wrong_runs = Enum.filter(pr, &(not &1.majority_correct))

      avg_jsd_correct = if correct_runs != [],
        do: Enum.sum(Enum.map(correct_runs, & &1.jsd)) / length(correct_runs),
        else: 0.0
      avg_jsd_wrong = if wrong_runs != [],
        do: Enum.sum(Enum.map(wrong_runs, & &1.jsd)) / length(wrong_runs),
        else: 0.0

      avg_neff_correct = if correct_runs != [],
        do: Enum.sum(Enum.map(correct_runs, & &1.n_eff)) / length(correct_runs),
        else: 0.0
      avg_neff_wrong = if wrong_runs != [],
        do: Enum.sum(Enum.map(wrong_runs, & &1.n_eff)) / length(wrong_runs),
        else: 0.0

      n_workers = pr |> hd() |> Map.get(:workers) |> length()

      IO.puts("    Majority correct (#{length(correct_runs)} Qs): avg JSD=#{Float.round(avg_jsd_correct, 4)}, avg N_eff=#{Float.round(avg_neff_correct, 2)}/#{n_workers}")
      IO.puts("    Majority wrong   (#{length(wrong_runs)} Qs): avg JSD=#{Float.round(avg_jsd_wrong, 4)}, avg N_eff=#{Float.round(avg_neff_wrong, 2)}/#{n_workers}")

      separation = if avg_jsd_correct + avg_jsd_wrong > 0 do
        abs(avg_jsd_wrong - avg_jsd_correct) / ((avg_jsd_correct + avg_jsd_wrong) / 2.0) * 100
      else
        0.0
      end
      IO.puts("    JSD separation: #{Float.round(separation, 1)}%")

      # Quartile analysis
      sorted_by_jsd = Enum.sort_by(pr, & &1.jsd)
      q1 = Enum.take(sorted_by_jsd, 25)
      q4 = Enum.take(sorted_by_jsd, -25)
      q1_acc = Enum.count(q1, & &1.majority_correct)
      q4_acc = Enum.count(q4, & &1.majority_correct)
      IO.puts("    Low-JSD quartile (Q1, consensus):  #{q1_acc}/25 majority correct")
      IO.puts("    High-JSD quartile (Q4, disagreement): #{q4_acc}/25 majority correct")

      # Top 10 highest JSD questions
      top_jsd = Enum.take(sorted_by_jsd, -10) |> Enum.reverse()
      IO.puts("\n    Top 10 highest-JSD questions:")
      IO.puts("    " <> String.pad_trailing("Test", 14) <>
        String.pad_trailing("JSD", 10) <>
        String.pad_trailing("N_eff", 10) <>
        String.pad_trailing("MajCorr?", 10) <>
        "Correct")
      for r <- top_jsd do
        IO.puts("    " <> String.pad_trailing(r.test_id, 14) <>
          String.pad_trailing("#{Float.round(r.jsd, 4)}", 10) <>
          String.pad_trailing("#{Float.round(r.n_eff, 2)}", 10) <>
          String.pad_trailing(if(r.majority_correct, do: "YES", else: "NO"), 10) <>
          r.correct)
      end
    end
  end

  defp print_bell_curve_sweep(results, panels) do
    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("BELL CURVE PARAMETER SWEEP — Does it find a niche on MedQA?")
    IO.puts(String.duplicate("=", 110))

    mus = [0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80]
    sigmas = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30]

    for panel <- panels do
      pr = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n  --- #{panel} ---")

      combos =
        for mu <- mus, sigma <- sigmas do
          hits = Enum.count(pr, fn r ->
            {winner, _} = bell_curve(r.workers, mu, sigma)
            winner == r.correct
          end)
          {mu, sigma, hits}
        end

      {best_mu, best_sigma, best_hits} = Enum.max_by(combos, fn {_, _, h} -> h end)
      default_hits = Enum.count(pr, fn r ->
        {winner, _} = bell_curve(r.workers, @bell_mu, @bell_sigma)
        winner == r.correct
      end)

      IO.puts("    Default (mu=#{@bell_mu}, sigma=#{@bell_sigma}): #{default_hits}/100")
      IO.puts("    Best sweep (mu=#{best_mu}, sigma=#{best_sigma}): #{best_hits}/100")
      IO.puts("    vs phi3 solo: #{best_hits - @phi3_solo}pp")

      # Show top 5 configs
      top5 = combos |> Enum.sort_by(fn {_, _, h} -> -h end) |> Enum.take(5)
      IO.puts("    Top 5 configs:")
      for {mu, sigma, hits} <- top5 do
        IO.puts("      mu=#{mu}, sigma=#{sigma}: #{hits}/100")
      end

      # Questions where bell curve (best config) uniquely corrects vs majority
      best_unique = Enum.filter(pr, fn r ->
        {maj_winner, _} = majority_vote(r.workers)
        {bell_winner, _} = bell_curve(r.workers, best_mu, best_sigma)
        bell_winner == r.correct and maj_winner != r.correct
      end)

      best_lost = Enum.filter(pr, fn r ->
        {maj_winner, _} = majority_vote(r.workers)
        {bell_winner, _} = bell_curve(r.workers, best_mu, best_sigma)
        maj_winner == r.correct and bell_winner != r.correct
      end)

      IO.puts("    vs Majority: +#{length(best_unique)} gains, -#{length(best_lost)} losses")
      if best_unique != [] do
        ids = best_unique |> Enum.map(& &1.test_id) |> Enum.sort() |> Enum.join(", ")
        IO.puts("      Unique gains: #{ids}")
      end
    end
  end

  defp print_oracle_analysis(results, methods, panels) do
    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("META-UNION / ORACLE ANALYSIS: Best method per question ceiling")
    IO.puts(String.duplicate("=", 110))

    for panel <- panels do
      pr = Enum.filter(results, &(&1.config == panel))
      IO.puts("\n  --- #{panel} ---")

      oracle_correct = Enum.count(pr, fn r ->
        Enum.any?(r.results, fn {_, _, c, _} -> c end)
      end)

      method_scores = for {name, _} <- methods do
        hits = Enum.count(pr, fn r ->
          Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
        end)
        {name, hits}
      end

      {best_method, best_score} = Enum.max_by(method_scores, fn {_, s} -> s end)

      IO.puts("    Oracle (best method per Q): #{oracle_correct}/100 (#{oracle_correct}%)")
      IO.puts("    Best single method: #{best_method} at #{best_score}/100")
      IO.puts("    Gap (oracle - best single): #{oracle_correct - best_score} questions")
      IO.puts("    Gap (oracle - phi3 solo): #{oracle_correct - @phi3_solo} questions")

      # Which methods contribute unique questions to oracle?
      IO.puts("\n    Method contributions to oracle (unique questions only this method gets right):")
      for {name, _} <- methods do
        unique = Enum.count(pr, fn r ->
          {_, _, this_correct, _} = Enum.find(r.results, fn {n, _, _, _} -> n == name end)
          if this_correct do
            other_correct = r.results
              |> Enum.filter(fn {n, _, c, _} -> n != name and c end)
              |> length()
            other_correct == 0
          else
            false
          end
        end)
        if unique > 0 do
          IO.puts("      #{String.pad_trailing(name, 12)} #{unique} unique question(s)")
        end
      end

      # Cross-panel oracle
    end

    # Grand oracle: best method per Q per panel
    IO.puts("\n  --- GRAND ORACLE (best panel × method per question) ---")
    test_ids = results |> Enum.map(& &1.test_id) |> Enum.uniq() |> Enum.sort()
    grand_oracle = Enum.count(test_ids, fn tid ->
      Enum.any?(results, &(&1.test_id == tid and Enum.any?(&1.results, fn {_, _, c, _} -> c end)))
    end)
    IO.puts("    Grand oracle: #{grand_oracle}/100 — ceiling across all panels and methods")
    IO.puts("    vs phi3 solo: #{grand_oracle - @phi3_solo}pp")
  end

  defp print_method_complementarity(results, methods, panels) do
    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("METHOD COMPLEMENTARITY: Pairwise agreement on medqa_informed panel")
    IO.puts(String.duplicate("=", 110))

    panel = "medqa_informed"
    pr = Enum.filter(results, &(&1.config == panel))
    method_names = Enum.map(methods, fn {n, _} -> n end)

    IO.puts("\n  Pairwise agreement (% same answer):")
    IO.puts("  " <> String.pad_trailing("", 12) <> Enum.map_join(method_names, "", fn n -> String.pad_trailing(n, 10) end))

    for m1 <- method_names do
      row = for m2 <- method_names do
        if m1 == m2 do
          "  —"
        else
          agree = Enum.count(pr, fn r ->
            {_, a1, _, _} = Enum.find(r.results, fn {n, _, _, _} -> n == m1 end)
            {_, a2, _, _} = Enum.find(r.results, fn {n, _, _, _} -> n == m2 end)
            a1 == a2
          end)
          "#{agree}%"
        end
      end

      IO.puts("  " <> String.pad_trailing(m1, 12) <> Enum.map_join(row, "", fn r -> String.pad_trailing(r, 10) end))
    end
  end

  defp print_gotcha_comparison(_methods) do
    IO.puts("\n" <> String.duplicate("=", 110))
    IO.puts("GOTCHA vs MedQA LANDSCAPE COMPARISON")
    IO.puts(String.duplicate("=", 110))

    IO.puts("""

      On GOTCHAS (5G/5L curated 6):
        Majority: 50.0%  Conf-Wt: 75.0%  MoE: 62.5%  Ent-Wt: 62.5%
        Ent-Gate: 62.5%  PoE: 75.0%  LogOP: 75.0%  BellCurve: 62.5%
        - 5 methods tied at 62.5%, 3 at 75.0%
        - Different methods cracked DIFFERENT tests
        - Bell curve uniquely cracked A4

      Key structural difference:
        Gotchas: 8 tests, 3 trials each = 24 opportunities. Binary per test.
        MedQA: 100 questions, 1 trial each = 100 opportunities. Per question.
        On gotchas, 1 correct flip = +4.2pp (1/24). On MedQA, 1 flip = +1pp (1/100).
        The per-question marginal value is 4× lower on MedQA.

      See headline scores above for the MedQA comparison.
    """)
  end

  defp print_key_findings(results, methods, panels) do
    IO.puts(String.duplicate("=", 110))
    IO.puts("KEY FINDINGS & EMPIRICAL CONSTRAINT CANDIDATES")
    IO.puts(String.duplicate("=", 110))

    # Best overall
    best_overall = nil
    for panel <- panels do
      pr = Enum.filter(results, &(&1.config == panel))
      for {name, _} <- methods do
        hits = Enum.count(pr, fn r ->
          Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
        end)
        IO.puts("    #{String.pad_trailing(panel, 22)} #{String.pad_trailing(name, 12)} #{hits}/100")
      end
    end

    # Questions solvable by no panel, no method
    test_ids = results |> Enum.map(& &1.test_id) |> Enum.uniq() |> Enum.sort()
    unsolvable = Enum.filter(test_ids, fn tid ->
      not Enum.any?(results, &(&1.test_id == tid and Enum.any?(&1.results, fn {_, _, c, _} -> c end)))
    end)
    IO.puts("\n  Unsolvable questions (no panel × method gets right): #{length(unsolvable)}/100")
    if length(unsolvable) <= 20 do
      IO.puts("    #{Enum.join(unsolvable, ", ")}")
    end

    # phi3-solo-only questions: phi3 got right in 6B but no collective method gets right
    # (We can approximate: questions where correct_answer differs from all method answers on all panels)
    always_wrong = Enum.filter(test_ids, fn tid ->
      not Enum.any?(results, &(&1.test_id == tid and Enum.any?(&1.results, fn {_, _, c, _} -> c end)))
    end)

    IO.puts("\n  Questions where ALL 8 methods on ALL 3 panels are wrong: #{length(always_wrong)}/100")
  end

  defp export_json(results, methods, panels) do
    method_names = Enum.map(methods, fn {n, _} -> n end)

    per_run =
      for r <- results do
        %{
          run_id: r.run_id,
          test_id: r.test_id,
          config: r.config,
          correct: r.correct,
          jsd: Float.round(r.jsd, 6),
          n_eff: Float.round(r.n_eff, 4),
          methods: Map.new(r.results, fn {name, answer, correct, dist} ->
            rounded_dist = Map.new(dist, fn {k, v} -> {k, Float.round(v, 6)} end)
            {name, %{answer: answer, correct: correct, distribution: rounded_dist}}
          end)
        }
      end

    summary =
      for panel <- panels, into: %{} do
        pr = Enum.filter(results, &(&1.config == panel))
        method_scores = Map.new(method_names, fn name ->
          score = Enum.count(pr, fn r ->
            Enum.find(r.results, fn {n, _, _, _} -> n == name end) |> elem(2)
          end)
          {name, %{correct: score, total: length(pr), pct: Float.round(score / length(pr) * 100, 1)}}
        end)

        oracle = Enum.count(pr, fn r -> Enum.any?(r.results, fn {_, _, c, _} -> c end) end)

        avg_jsd = Enum.sum(Enum.map(pr, & &1.jsd)) / length(pr)
        avg_neff = Enum.sum(Enum.map(pr, & &1.n_eff)) / length(pr)

        {panel, %{
          methods: method_scores,
          oracle: oracle,
          avg_jsd: Float.round(avg_jsd, 6),
          avg_n_eff: Float.round(avg_neff, 4)
        }}
      end

    # Grand oracle
    test_ids = results |> Enum.map(& &1.test_id) |> Enum.uniq()
    grand_oracle = Enum.count(test_ids, fn tid ->
      Enum.any?(results, &(&1.test_id == tid and Enum.any?(&1.results, fn {_, _, c, _} -> c end)))
    end)

    output = %{
      phase: "6D-aggregation",
      description: "8 aggregation methods + JSD diagnostics over 6C MedQA traces (0 Ollama calls)",
      phi3_solo_baseline: @phi3_solo,
      bell_curve_params: %{mu: @bell_mu, sigma: @bell_sigma},
      per_run: per_run,
      summary: summary,
      grand_oracle: grand_oracle
    }

    path = Path.join([__DIR__, "benchmark_traces", "phase6c", "phase6d-aggregation-results.json"])
    File.write!(path, Jason.encode!(output, pretty: true))
    IO.puts("\nResults exported to: #{path}")
  end
end

Phase6D.Aggregation.run()
