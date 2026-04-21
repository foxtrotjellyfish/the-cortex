defmodule Phase5F.Aggregation do
  @moduledoc """
  Phase 5F-alpha: Distribution-level aggregation over existing 5E traces.
  Zero new Ollama runs — just math over existing logprobs distributions.

  Implements: Majority Vote, Confidence-Weighted, Product of Experts (PoE),
  Mixture of Experts (MoE), Entropy-Weighted MoE, Entropy-Gated MoE,
  Logarithmic Opinion Pool (LogOP).
  """

  @choices ["A", "B", "C", "D"]
  @epsilon 1.0e-6

  def run do
    run_phase("phase5e", "5E (no viewpoints)")
    run_phase("phase5d", "5D (with viewpoints)")
    run_structural_diagnosis()
  end

  def run_phase(phase_dir, label) do
    path = Path.join([__DIR__, "benchmark_traces", phase_dir, "#{phase_dir}-summary.json"])
    data = path |> File.read!() |> Jason.decode!()

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("PHASE 5F-ALPHA: DISTRIBUTION-LEVEL AGGREGATION — #{label}")
    IO.puts("Re-scoring #{length(data["collective"])} collective runs from #{String.upcase(phase_dir)} traces")
    IO.puts(String.duplicate("=", 80))

    collective = data["collective"]

    methods = [
      {"Majority Vote", &majority_vote/1},
      {"Conf-Weighted", &confidence_weighted/1},
      {"MoE (uniform)", &moe_uniform/1},
      {"Entropy-Wt MoE", &entropy_weighted_moe/1},
      {"Entropy-Gated", &entropy_gated/1},
      {"PoE (smoothed)", &poe_smoothed/1},
      {"LogOP", &log_opinion_pool/1}
    ]

    results =
      for run <- collective do
        workers = normalize_workers(run["per_worker"])
        correct = run["correct_answer"]

        method_results =
          for {name, func} <- methods do
            answer = func.(workers)
            {name, answer, answer == correct}
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

    print_per_run_table(results, methods)
    print_summary_table(results, methods)
    print_distribution_deep_dive(results, methods)
    print_key_questions(results, methods)

    results
  end

  defp normalize_workers(per_worker) do
    Enum.map(per_worker, fn w ->
      probs = w["probabilities"]
      dist = Enum.map(@choices, fn c -> {c, Map.get(probs, c, 0.0)} end) |> Map.new()
      total = dist |> Map.values() |> Enum.sum()
      dist = if total > 0, do: Map.new(dist, fn {k, v} -> {k, v / total} end), else: dist
      %{model: w["model"], dist: dist}
    end)
  end

  defp majority_vote(workers) do
    workers
    |> Enum.map(fn w -> top_answer(w.dist) end)
    |> Enum.frequencies()
    |> Enum.max_by(fn {_ans, count} -> count end)
    |> elem(0)
  end

  defp confidence_weighted(workers) do
    @choices
    |> Enum.map(fn c ->
      weight =
        workers
        |> Enum.filter(fn w -> top_answer(w.dist) == c end)
        |> Enum.map(fn w -> w.dist[c] end)
        |> Enum.sum()
      {c, weight}
    end)
    |> Enum.max_by(fn {_c, w} -> w end)
    |> elem(0)
  end

  defp moe_uniform(workers) do
    n = length(workers)
    @choices
    |> Enum.map(fn c ->
      avg = workers |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)
      {c, avg}
    end)
    |> Enum.max_by(fn {_c, v} -> v end)
    |> elem(0)
  end

  defp entropy_weighted_moe(workers) do
    max_entropy = :math.log(length(@choices))
    weights =
      Enum.map(workers, fn w ->
        h = entropy(w.dist)
        1.0 / (h / max_entropy + @epsilon)
      end)

    total_weight = Enum.sum(weights)

    @choices
    |> Enum.map(fn c ->
      val =
        Enum.zip(workers, weights)
        |> Enum.map(fn {w, wt} -> w.dist[c] * wt end)
        |> Enum.sum()
        |> Kernel./(total_weight)
      {c, val}
    end)
    |> Enum.max_by(fn {_c, v} -> v end)
    |> elem(0)
  end

  defp entropy_gated(workers) do
    max_entropy = :math.log(length(@choices))
    threshold = 0.85

    active =
      Enum.filter(workers, fn w ->
        entropy(w.dist) / max_entropy < threshold
      end)

    if active == [] do
      moe_uniform(workers)
    else
      n = length(active)
      @choices
      |> Enum.map(fn c ->
        avg = active |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)
        {c, avg}
      end)
      |> Enum.max_by(fn {_c, v} -> v end)
      |> elem(0)
    end
  end

  defp poe_smoothed(workers) do
    @choices
    |> Enum.map(fn c ->
      log_product =
        workers
        |> Enum.map(fn w -> :math.log(max(w.dist[c], @epsilon)) end)
        |> Enum.sum()
      {c, log_product}
    end)
    |> Enum.max_by(fn {_c, v} -> v end)
    |> elem(0)
  end

  defp log_opinion_pool(workers) do
    n = length(workers)
    @choices
    |> Enum.map(fn c ->
      geo_mean =
        workers
        |> Enum.map(fn w -> :math.log(max(w.dist[c], @epsilon)) end)
        |> Enum.sum()
        |> Kernel./(n)
      {c, geo_mean}
    end)
    |> Enum.max_by(fn {_c, v} -> v end)
    |> elem(0)
  end

  defp entropy(dist) do
    dist
    |> Map.values()
    |> Enum.filter(&(&1 > 0))
    |> Enum.map(fn p -> -p * :math.log(p) end)
    |> Enum.sum()
  end

  defp top_answer(dist) do
    dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
  end

  defp print_per_run_table(results, methods) do
    IO.puts("\n" <> String.duplicate("-", 80))
    IO.puts("PER-RUN RESULTS")
    IO.puts(String.duplicate("-", 80))

    method_names = Enum.map(methods, fn {name, _} -> name end)
    header = String.pad_trailing("Run", 12) <>
      String.pad_trailing("Test", 5) <>
      String.pad_trailing("Config", 6) <>
      String.pad_trailing("Ans", 4) <>
      Enum.map_join(method_names, "", fn n -> String.pad_trailing(String.slice(n, 0, 10), 11) end)
    IO.puts(header)
    IO.puts(String.duplicate("-", String.length(header)))

    for r <- results do
      marks = Enum.map(r.results, fn {_name, ans, correct} ->
        mark = if correct, do: "✅#{ans}", else: "❌#{ans}"
        String.pad_trailing(mark, 11)
      end)

      IO.puts(
        String.pad_trailing(r.run_id, 12) <>
        String.pad_trailing(r.test_id, 5) <>
        String.pad_trailing(String.slice(r.config, 0, 5), 6) <>
        String.pad_trailing(r.correct, 4) <>
        Enum.join(marks, "")
      )
    end
  end

  defp print_summary_table(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("SCORECARD: METHOD × CONFIG × TEST")
    IO.puts(String.duplicate("=", 80))

    for config <- ["homogeneous", "diverse"] do
      IO.puts("\n--- #{String.upcase(config)} ---")
      config_runs = Enum.filter(results, &(&1.config == config))

      method_names = Enum.map(methods, fn {name, _} -> name end)
      header = String.pad_trailing("Test", 6) <>
        Enum.map_join(method_names, "", fn n -> String.pad_trailing(String.slice(n, 0, 14), 15) end)
      IO.puts(header)
      IO.puts(String.duplicate("-", String.length(header)))

      for test_id <- ["A1", "A2", "A3", "A4", "A5"] do
        test_runs = Enum.filter(config_runs, &(&1.test_id == test_id))
        scores = for {name, _} <- methods do
          correct_count = test_runs
            |> Enum.flat_map(fn r ->
              Enum.filter(r.results, fn {n, _, _} -> n == name end)
            end)
            |> Enum.count(fn {_, _, c} -> c end)
          "#{correct_count}/#{length(test_runs)}"
        end

        IO.puts(
          String.pad_trailing(test_id, 6) <>
          Enum.map_join(scores, "", fn s -> String.pad_trailing(s, 15) end)
        )
      end

      totals = for {name, _} <- methods do
        correct_count = config_runs
          |> Enum.flat_map(fn r ->
            Enum.filter(r.results, fn {n, _, _} -> n == name end)
          end)
          |> Enum.count(fn {_, _, c} -> c end)
        total = length(config_runs)
        pct = Float.round(correct_count / total * 100, 1)
        "#{correct_count}/#{total} (#{pct}%)"
      end

      IO.puts(String.duplicate("-", String.length(header)))
      IO.puts(
        String.pad_trailing("TOTAL", 6) <>
        Enum.map_join(totals, "", fn s -> String.pad_trailing(s, 15) end)
      )
    end
  end

  defp print_distribution_deep_dive(results, _methods) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("DISTRIBUTION DEEP DIVE — Key Questions")
    IO.puts(String.duplicate("=", 80))

    diverse_runs = Enum.filter(results, &(&1.config == "diverse"))

    for test_id <- ["A1", "A2", "A3", "A4", "A5"] do
      run = Enum.find(diverse_runs, &(&1.test_id == test_id && &1.trial == 1))
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
          h = entropy(w.dist)
          max_h = :math.log(length(@choices))
          IO.puts("    #{String.pad_trailing(w.model, 15)} #{dist_str}  [H=#{Float.round(h / max_h, 3)}]")
        end

        IO.puts("  Aggregated distributions:")
        for method_name <- ["MoE (uniform)", "Entropy-Wt MoE", "PoE (smoothed)", "LogOP"] do
          agg_dist = case method_name do
            "MoE (uniform)" -> compute_moe_dist(run.workers)
            "Entropy-Wt MoE" -> compute_entropy_wt_dist(run.workers)
            "PoE (smoothed)" -> compute_poe_dist(run.workers)
            "LogOP" -> compute_logop_dist(run.workers)
          end

          dist_str = @choices
            |> Enum.map(fn c ->
              v = Map.get(agg_dist, c, 0.0)
              if v > 0.001, do: "#{c}:#{Float.round(v * 100, 1)}%", else: nil
            end)
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" ")
          winner = agg_dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
          correct_mark = if winner == run.correct, do: " ✅", else: " ❌"
          IO.puts("    #{String.pad_trailing(method_name, 15)} #{dist_str}#{correct_mark}")
        end
      end
    end
  end

  defp compute_moe_dist(workers) do
    n = length(workers)
    Map.new(@choices, fn c ->
      {c, workers |> Enum.map(fn w -> w.dist[c] end) |> Enum.sum() |> Kernel./(n)}
    end)
  end

  defp compute_entropy_wt_dist(workers) do
    max_entropy = :math.log(length(@choices))
    weights = Enum.map(workers, fn w ->
      h = entropy(w.dist)
      1.0 / (h / max_entropy + @epsilon)
    end)
    total_weight = Enum.sum(weights)

    Map.new(@choices, fn c ->
      val = Enum.zip(workers, weights)
        |> Enum.map(fn {w, wt} -> w.dist[c] * wt end)
        |> Enum.sum()
        |> Kernel./(total_weight)
      {c, val}
    end)
  end

  defp compute_poe_dist(workers) do
    raw = Map.new(@choices, fn c ->
      log_prod = workers
        |> Enum.map(fn w -> :math.log(max(w.dist[c], @epsilon)) end)
        |> Enum.sum()
      {c, :math.exp(log_prod)}
    end)
    z = raw |> Map.values() |> Enum.sum()
    if z > 0, do: Map.new(raw, fn {k, v} -> {k, v / z} end), else: raw
  end

  defp compute_logop_dist(workers) do
    n = length(workers)
    raw = Map.new(@choices, fn c ->
      avg_log = workers
        |> Enum.map(fn w -> :math.log(max(w.dist[c], @epsilon)) end)
        |> Enum.sum()
        |> Kernel./(n)
      {c, :math.exp(avg_log)}
    end)
    z = raw |> Map.values() |> Enum.sum()
    if z > 0, do: Map.new(raw, fn {k, v} -> {k, v / z} end), else: raw
  end

  defp print_key_questions(results, methods) do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("KEY QUESTIONS")
    IO.puts(String.duplicate("=", 80))

    diverse = Enum.filter(results, &(&1.config == "diverse"))

    a3_flipped = diverse
      |> Enum.filter(&(&1.test_id == "A3"))
      |> Enum.flat_map(fn r ->
        r.results
        |> Enum.filter(fn {name, _ans, correct} -> correct and name != "Majority Vote" end)
        |> Enum.map(fn {name, _ans, _correct} -> name end)
      end)

    IO.puts("\n1. Does any method flip A3? (phi3 correct at 76.7% but outvoted 4-1)")
    if a3_flipped == [] do
      IO.puts("   ❌ NO — no method flipped A3 diverse.")
    else
      IO.puts("   ✅ YES — #{Enum.uniq(a3_flipped) |> Enum.join(", ")} flipped A3!")
    end

    a4_held = diverse
      |> Enum.filter(&(&1.test_id == "A4"))
      |> Enum.flat_map(fn r ->
        r.results
        |> Enum.filter(fn {_name, _ans, correct} -> correct end)
        |> Enum.map(fn {name, _ans, _correct} -> name end)
      end)

    IO.puts("\n2. Does any method hold A4 without viewpoints?")
    if a4_held == [] do
      IO.puts("   ❌ NO — no method recovered A4 diverse.")
    else
      IO.puts("   ✅ YES — #{Enum.uniq(a4_held) |> Enum.join(", ")} held A4!")
    end

    a1_cracked = diverse
      |> Enum.filter(&(&1.test_id == "A1"))
      |> Enum.flat_map(fn r ->
        r.results
        |> Enum.filter(fn {_name, _ans, correct} -> correct end)
        |> Enum.map(fn {name, _ans, _correct} -> name end)
      end)

    IO.puts("\n3. Does any method crack A1? (all models wrong, but is there distribution signal?)")
    if a1_cracked == [] do
      IO.puts("   ❌ NO — A1 remains impenetrable. No distribution-level method could surface B.")
    else
      IO.puts("   ✅ YES — #{Enum.uniq(a1_cracked) |> Enum.join(", ")} cracked A1!")
    end

    IO.puts("\n4. Does any method beat majority vote overall (diverse)?")
    majority_score = diverse
      |> Enum.flat_map(fn r -> Enum.filter(r.results, fn {n, _, _} -> n == "Majority Vote" end) end)
      |> Enum.count(fn {_, _, c} -> c end)

    for {name, _} <- methods, name != "Majority Vote" do
      score = diverse
        |> Enum.flat_map(fn r -> Enum.filter(r.results, fn {n, _, _} -> n == name end) end)
        |> Enum.count(fn {_, _, c} -> c end)
      delta = score - majority_score
      mark = cond do
        delta > 0 -> "📈 +#{delta}"
        delta < 0 -> "📉 #{delta}"
        true -> "➡️  0"
      end
      IO.puts("   #{String.pad_trailing(name, 18)} #{score}/15 (#{mark} vs majority #{majority_score}/15)")
    end

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("END OF PHASE 5F-ALPHA ANALYSIS")
    IO.puts(String.duplicate("=", 80) <> "\n")
  end

  def run_structural_diagnosis do
    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("STRUCTURAL DIAGNOSIS: WHY ALL METHODS AGREE")
    IO.puts(String.duplicate("=", 80))

    path = Path.join([__DIR__, "benchmark_traces", "phase5e", "phase5e-summary.json"])
    data = path |> File.read!() |> Jason.decode!()

    diverse = data["collective"] |> Enum.filter(&(&1["config"] == "diverse"))

    IO.puts("\n--- The Vote Count Problem ---")
    IO.puts("Panel: td / phi3 / gemma2 / llama3.2 / td  (tinydolphin appears TWICE)")
    IO.puts("")

    for test_id <- ["A1", "A2", "A3", "A4", "A5"] do
      run = Enum.find(diverse, &(&1["test_id"] == test_id && &1["trial"] == 1))
      correct = run["correct_answer"]
      workers = normalize_workers(run["per_worker"])

      votes_for_correct = Enum.count(workers, fn w -> top_answer(w.dist) == correct end)
      votes_total = length(workers)

      correct_mass = workers |> Enum.map(fn w -> w.dist[correct] end) |> Enum.sum()
      avg_correct_mass = correct_mass / votes_total

      zero_on_correct = Enum.count(workers, fn w -> w.dist[correct] < @epsilon end)

      IO.puts("  #{test_id}: #{votes_for_correct}/#{votes_total} vote for #{correct} | " <>
        "avg P(#{correct})=#{Float.round(avg_correct_mass * 100, 1)}% | " <>
        "#{zero_on_correct} models put ~0% on #{correct}" <>
        if(zero_on_correct > 0, do: " ← PoE VETO", else: ""))
    end

    IO.puts("\n--- What If: Deduplicated Panel (unique models only) ---")
    IO.puts("Simulate: drop 2nd tinydolphin → panel of 4 unique models")

    for test_id <- ["A1", "A2", "A3", "A4", "A5"] do
      run = Enum.find(diverse, &(&1["test_id"] == test_id && &1["trial"] == 1))
      correct = run["correct_answer"]
      all_workers = normalize_workers(run["per_worker"])

      unique_workers = Enum.take(all_workers, 4)

      methods = [
        {"Majority", &majority_vote/1},
        {"MoE", &moe_uniform/1},
        {"Ent-Wt", &entropy_weighted_moe/1},
        {"Ent-Gate", &entropy_gated/1},
        {"PoE", &poe_smoothed/1},
        {"LogOP", &log_opinion_pool/1}
      ]

      results = Enum.map(methods, fn {name, func} ->
        ans = func.(unique_workers)
        mark = if ans == correct, do: "✅", else: "❌"
        "#{name}:#{mark}#{ans}"
      end)

      IO.puts("  #{test_id} (correct:#{correct}) #{Enum.join(results, " | ")}")
    end

    IO.puts("\n--- What If: phi3 Only (strongest solo model at 12/15) ---")
    IO.puts("If the aggregation matched the best solo model, it would score 12/15.")
    IO.puts("The collective adds td×2/gemma2/llama — all wrong on A3,A4 — drowning phi3.")
    IO.puts("This IS the thesis problem: collective ≤ best solo when vote count dominates.")

    IO.puts("\n--- Entropy Analysis: Who's Guessing? ---")
    max_h = :math.log(4)
    for test_id <- ["A3", "A4"] do
      run = Enum.find(diverse, &(&1["test_id"] == test_id && &1["trial"] == 1))
      correct = run["correct_answer"]
      workers = normalize_workers(run["per_worker"])

      IO.puts("\n  #{test_id} (correct: #{correct}):")
      for w <- workers do
        h = entropy(w.dist) / max_h
        top = top_answer(w.dist)
        top_p = w.dist[top]
        correct_p = w.dist[correct]
        status = cond do
          top == correct -> "CORRECT"
          h > 0.85 -> "GUESSING (H=#{Float.round(h, 3)})"
          true -> "WRONG (conf #{Float.round(top_p * 100, 1)}% on #{top})"
        end
        IO.puts("    #{String.pad_trailing(w.model, 15)} P(#{correct})=#{Float.round(correct_p * 100, 1)}% | #{status}")
      end
    end

    IO.puts("\n" <> String.duplicate("=", 80))
    IO.puts("CONCLUSION")
    IO.puts(String.duplicate("=", 80))
    IO.puts("""

    Distribution-level aggregation does NOT break the 6/15 ceiling.
    The distribution-level aggregation hypothesis is cleanly FALSIFIED for this panel.

    Root cause: the problem isn't how we count votes — it's WHO votes.
    - A3: phi3 is the ONLY model that puts any real mass on B (76.7%).
           gemma2 puts 0% on B → PoE veto. 4 models outvote 1.
    - A4: phi3 is the ONLY model that favors C (63.7%).
           But td×2 + llama put 60-72% on A. Even phi3's peaked
           distribution can't overcome three confident wrong models.
    - A1: EVERY model is wrong. No distribution signal to surface.

    The binding constraint is EC-5 (correct answer = minority) combined
    with panel composition (2× tinydolphin = double weight to weakest model).

    WHAT MOVES THE NEEDLE:
    1. Panel composition (more models that know the answer) — but this is
       benchmark overfitting (deferred — moves score but doesn't generalize)
    2. New test questions A6/A7 where the distribution methods might help
       (cases where 2-3 models partially know the answer, not just 1)
    3. Temperature >0 to get real trial variance (5F-beta)
    4. The 5D traces (with viewpoints) to see if viewpoint-shifted
       distributions create different aggregation dynamics
    """)
  end
end

Phase5F.Aggregation.run()
