defmodule Phase5I.ConsensusSkepticism do
  @moduledoc """
  Phase 5I: Consensus Skepticism / Black Sheep Detector.

  Uses Jensen-Shannon Divergence and inter-model correlation to detect when
  ensemble consensus might be "shared ignorance" rather than genuine collective
  knowledge. Implements several literature-backed approaches:

    1. JSD Outlier Detection (Schirmer et al.) — flag models whose distribution
       diverges from the group mean
    2. Consensus Tightness — pairwise JSD among majority voters
    3. Effective Ensemble Size — correlation-adjusted N (Berg 1993, Ladha)
    4. Black Sheep Aggregation — amplify outlier when consensus is suspicious
    5. Correlation-Penalized Voting — downweight models that look too similar
    6. Adaptive Black Sheep — use cross-question reliability priors (Dawid-Skene inspired)

  Reads both 5G and 5H traces. Zero Ollama calls.
  """

  @epsilon 1.0e-10

  @correct_answers %{
    "A1" => "B", "A2" => "A", "A3" => "B", "A4" => "C",
    "A5" => "A", "A6" => "D", "A7" => "B", "A8" => "B"
  }

  @test_order ["A1", "A2", "A3", "A4", "A5", "A6", "A7", "A8"]

  def run do
    {g5_data, h5_data} = load_traces()

    IO.puts(String.duplicate("=", 100))
    IO.puts("PHASE 5I: CONSENSUS SKEPTICISM / BLACK SHEEP DETECTOR")
    IO.puts("JSD-based distributional analysis of when consensus fails")
    IO.puts("Literature: Schirmer et al. (divergence), Berg/Ladha (correlated juries),")
    IO.puts("           Prelec et al. (Surprisingly Popular), Dawid-Skene (reliability)")
    IO.puts(String.duplicate("=", 100))

    for {label, data} <- [{"5G", g5_data}, {"5H", h5_data}] do
      collective = data["collective"]

      IO.puts("\n" <> String.duplicate("#", 100))
      IO.puts("  DATASET: Phase #{label}")
      IO.puts(String.duplicate("#", 100))

      for panel <- ["curated_5", "full_8"] do
        panel_label = if panel == "curated_5", do: "CURATED 5", else: "FULL 8"
        panel_runs = Enum.filter(collective, &(&1["config"] == panel))

        IO.puts("\n" <> String.duplicate("=", 100))
        IO.puts("PANEL: #{panel_label} (#{label})")
        IO.puts(String.duplicate("=", 100))

        analyzed = analyze_panel(panel_runs)

        print_jsd_diagnostic(analyzed, panel_label)
        print_consensus_tightness(analyzed, panel_label)
        print_effective_n(analyzed, panel_label)
        print_black_sheep_results(analyzed, panel_label)
        print_correlation_penalized(analyzed, panel_label)
      end
    end

    print_cross_dataset_summary(g5_data, h5_data)
  end

  # --- Analysis Core ---

  defp analyze_panel(runs) do
    Enum.map(runs, fn run ->
      choices = run["choices"] || ["A", "B", "C", "D"]
      workers = normalize_workers(run["per_worker"], choices)
      correct = run["correct_answer"] || @correct_answers[run["test_id"]]

      mean_dist = compute_mean_dist(workers, choices)
      jsd_from_mean = Enum.map(workers, fn w ->
        {w.model, jsd(w.dist, mean_dist, choices)}
      end)

      pairwise = compute_pairwise_jsd(workers, choices)

      majority_answer = workers
        |> Enum.map(&top_answer(&1.dist))
        |> Enum.frequencies()
        |> Enum.max_by(fn {_a, n} -> n end)
        |> elem(0)

      majority_models = Enum.filter(workers, &(top_answer(&1.dist) == majority_answer))
      minority_models = Enum.filter(workers, &(top_answer(&1.dist) != majority_answer))

      majority_tightness = if length(majority_models) >= 2 do
        pairs = for a <- majority_models, b <- majority_models, a.model < b.model do
          jsd(a.dist, b.dist, choices)
        end
        Enum.sum(pairs) / max(length(pairs), 1)
      else
        0.0
      end

      outlier_distance = case minority_models do
        [] -> 0.0
        mins -> mins |> Enum.map(fn m -> jsd(m.dist, mean_dist, choices) end) |> Enum.max()
      end

      eff_n = compute_effective_n(workers, choices)

      %{
        test_id: run["test_id"],
        trial: run["trial"],
        run_id: run["run_id"],
        correct: correct,
        choices: choices,
        workers: workers,
        mean_dist: mean_dist,
        jsd_from_mean: jsd_from_mean,
        pairwise_jsd: pairwise,
        majority_answer: majority_answer,
        majority_correct: majority_answer == correct,
        majority_models: majority_models,
        minority_models: minority_models,
        majority_tightness: majority_tightness,
        outlier_distance: outlier_distance,
        effective_n: eff_n,
        outlier_correct: Enum.any?(minority_models, &(top_answer(&1.dist) == correct))
      }
    end)
  end

  # --- JSD and Information Theory ---

  defp jsd(p, q, choices) do
    m = Map.new(choices, fn c ->
      {c, (Map.get(p, c, 0.0) + Map.get(q, c, 0.0)) / 2.0}
    end)
    (kl(p, m, choices) + kl(q, m, choices)) / 2.0
  end

  defp kl(p, q, choices) do
    Enum.reduce(choices, 0.0, fn c, acc ->
      p_val = max(Map.get(p, c, 0.0), @epsilon)
      q_val = max(Map.get(q, c, 0.0), @epsilon)
      acc + p_val * :math.log(p_val / q_val)
    end)
  end

  defp compute_mean_dist(workers, choices) do
    n = length(workers)
    Map.new(choices, fn c ->
      {c, workers |> Enum.map(fn w -> Map.get(w.dist, c, 0.0) end) |> Enum.sum() |> Kernel./(n)}
    end)
  end

  defp compute_pairwise_jsd(workers, choices) do
    for a <- workers, b <- workers, a.model < b.model do
      {{a.model, b.model}, jsd(a.dist, b.dist, choices)}
    end
  end

  defp entropy(dist) do
    dist
    |> Map.values()
    |> Enum.filter(&(&1 > 0))
    |> Enum.map(fn p -> -p * :math.log(p) end)
    |> Enum.sum()
  end

  defp compute_effective_n(workers, choices) do
    n = length(workers)
    if n < 2, do: (if n == 1, do: 1.0, else: 0.0)

    top_answers = Enum.map(workers, fn w -> top_answer(w.dist) end)
    all_same = Enum.uniq(top_answers) |> length() == 1

    if all_same do
      avg_conf = workers |> Enum.map(fn w -> w.dist |> Map.values() |> Enum.max() end) |> Enum.sum() |> Kernel./(n)
      conf_variance = workers
        |> Enum.map(fn w ->
          c = w.dist |> Map.values() |> Enum.max()
          (c - avg_conf) * (c - avg_conf)
        end)
        |> Enum.sum()
        |> Kernel./(n)

      if conf_variance < 0.01 do
        1.0 + 0.5 * (n - 1) * min(conf_variance * 100, 1.0)
      else
        avg_jsd = compute_avg_pairwise_jsd(workers, choices)
        max_jsd = :math.log(length(choices))
        diversity_ratio = min(avg_jsd / max(max_jsd, @epsilon), 1.0)
        1.0 + (n - 1) * diversity_ratio
      end
    else
      avg_jsd = compute_avg_pairwise_jsd(workers, choices)
      max_jsd = :math.log(length(choices))
      diversity_ratio = min(avg_jsd / max(max_jsd, @epsilon), 1.0)
      1.0 + (n - 1) * diversity_ratio
    end
  end

  defp compute_avg_pairwise_jsd(workers, choices) do
    pairs = for a <- workers, b <- workers, a.model < b.model do
      jsd(a.dist, b.dist, choices)
    end
    if pairs == [], do: 0.0, else: Enum.sum(pairs) / length(pairs)
  end

  # --- Black Sheep Aggregation Methods ---

  defp black_sheep_vote(workers, choices, suspicion_threshold \\ 0.5, amplification \\ 3.0) do
    n = length(workers)
    mean_dist = compute_mean_dist(workers, choices)

    jsd_scores = Enum.map(workers, fn w ->
      {w, jsd(w.dist, mean_dist, choices)}
    end)

    avg_jsd = jsd_scores |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> Kernel./(n)
    max_jsd_score = jsd_scores |> Enum.map(&elem(&1, 1)) |> Enum.max()

    suspicious = max_jsd_score > suspicion_threshold * :math.log(length(choices)) and
                 avg_jsd < 0.3 * :math.log(length(choices))

    weights = if suspicious do
      Enum.map(jsd_scores, fn {w, score} ->
        if score > avg_jsd * 1.5 do
          {w, amplification}
        else
          {w, 1.0}
        end
      end)
    else
      Enum.map(workers, fn w -> {w, 1.0} end)
    end

    total_w = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    dist = Map.new(choices, fn c ->
      val = weights
        |> Enum.map(fn {w, wt} -> w.dist[c] * wt end)
        |> Enum.sum()
        |> Kernel./(total_w)
      {c, val}
    end)

    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist, suspicious}
  end

  defp correlation_penalized_vote(workers, choices) do
    n = length(workers)
    if n < 2 do
      dist = compute_mean_dist(workers, choices)
      winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
      {winner, dist}
    else
      similarity_matrix = for i <- 0..(n-1), j <- 0..(n-1), i != j do
        wi = Enum.at(workers, i)
        wj = Enum.at(workers, j)
        sim = 1.0 - jsd(wi.dist, wj.dist, choices) / :math.log(length(choices))
        {i, max(sim, 0.0)}
      end

      avg_similarities = Enum.group_by(similarity_matrix, &elem(&1, 0), &elem(&1, 1))
      weights = Enum.map(0..(n-1), fn i ->
        avg_sim = case Map.get(avg_similarities, i) do
          nil -> 0.0
          sims -> Enum.sum(sims) / length(sims)
        end
        1.0 / (1.0 + avg_sim * (n - 1))
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
  end

  defp jsd_diversity_weighted(workers, choices) do
    n = length(workers)
    mean_dist = compute_mean_dist(workers, choices)

    weights = Enum.map(workers, fn w ->
      divergence = jsd(w.dist, mean_dist, choices)
      h = entropy(w.dist) / :math.log(length(choices))
      info_content = 1.0 - h

      1.0 + divergence * info_content * 2.0
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

  defp suspicion_gated_outlier_boost(workers, choices) do
    n = length(workers)
    mean_dist = compute_mean_dist(workers, choices)
    max_possible_jsd = :math.log(length(choices))

    jsd_scores = Enum.map(workers, fn w ->
      {w, jsd(w.dist, mean_dist, choices)}
    end)

    sorted = Enum.sort_by(jsd_scores, &elem(&1, 1), :desc)
    {_top_outlier, top_jsd} = hd(sorted)

    majority_jsds = sorted |> tl() |> Enum.map(&elem(&1, 1))
    avg_majority_jsd = if majority_jsds == [], do: 0.0,
      else: Enum.sum(majority_jsds) / length(majority_jsds)

    separation_ratio = if avg_majority_jsd > @epsilon,
      do: top_jsd / avg_majority_jsd,
      else: top_jsd * 1000

    suspicion = min(separation_ratio / 5.0, 1.0) *
                min(top_jsd / (max_possible_jsd * 0.3), 1.0)

    boost = 1.0 + suspicion * 4.0

    weights = Enum.map(jsd_scores, fn {w, score} ->
      if score == top_jsd do
        {w, boost}
      else
        {w, 1.0}
      end
    end)

    total_w = weights |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    dist = Map.new(choices, fn c ->
      val = weights
        |> Enum.map(fn {w, wt} -> w.dist[c] * wt end)
        |> Enum.sum()
        |> Kernel./(total_w)
      {c, val}
    end)

    winner = dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)
    {winner, dist, suspicion, boost}
  end

  # --- Output ---

  defp print_jsd_diagnostic(analyzed, panel_label) do
    IO.puts("\n--- JSD DIAGNOSTIC: Each model's divergence from group mean ---")
    IO.puts("Higher JSD = more different from the consensus. Max JSD = ln(K) ≈ #{Float.round(:math.log(4), 3)} (4 choices)")
    IO.puts("")

    for test_id <- @test_order do
      runs = Enum.filter(analyzed, &(&1.test_id == test_id))
      run = hd(runs)

      outlier_status = cond do
        run.majority_correct and not run.outlier_correct -> "consensus RIGHT, outlier wrong"
        not run.majority_correct and run.outlier_correct -> "consensus WRONG, outlier RIGHT <<<<<"
        not run.majority_correct and not run.outlier_correct -> "consensus wrong, outlier wrong"
        true -> "consensus right, outlier right"
      end

      IO.puts("  #{test_id} [correct=#{run.correct}] #{outlier_status}")

      sorted = Enum.sort_by(run.jsd_from_mean, fn {_m, s} -> s end, :desc)
      for {model, score} <- sorted do
        worker = Enum.find(run.workers, &(&1.model == model))
        answer = top_answer(worker.dist)
        conf = worker.dist |> Map.values() |> Enum.max()
        correct_mark = if answer == run.correct, do: " ✅", else: ""
        bar = String.duplicate("█", round(score / :math.log(4) * 30))
        IO.puts("    #{String.pad_trailing(model, 22)} JSD=#{pad_float(score, 4)} " <>
          "#{bar} → #{answer}(#{pad_float(conf * 100, 1)}%)#{correct_mark}")
      end
      IO.puts("")
    end
  end

  defp print_consensus_tightness(analyzed, _panel_label) do
    IO.puts("\n--- CONSENSUS TIGHTNESS vs OUTLIER DISTANCE ---")
    IO.puts("Hypothesis: wrong consensus has HIGHER tightness (shared bias) + HIGHER outlier distance")
    IO.puts("")

    header = "  #{String.pad_trailing("Test", 6)} #{String.pad_trailing("Maj", 5)} " <>
      "#{String.pad_trailing("Correct?", 10)} #{String.pad_trailing("Tightness", 12)} " <>
      "#{String.pad_trailing("OutlierDist", 14)} #{String.pad_trailing("Eff-N", 8)} " <>
      "#{String.pad_trailing("Ratio(O/T)", 12)} Outlier→Correct?"
    IO.puts(header)
    IO.puts("  " <> String.duplicate("-", 95))

    for test_id <- @test_order do
      runs = Enum.filter(analyzed, &(&1.test_id == test_id))
      run = hd(runs)

      ratio = if run.majority_tightness > @epsilon,
        do: run.outlier_distance / run.majority_tightness,
        else: 0.0

      outlier_right = if run.outlier_correct, do: "YES ★", else: "no"
      maj_mark = if run.majority_correct, do: "✅", else: "❌"

      IO.puts("  #{String.pad_trailing(test_id, 6)} #{String.pad_trailing(run.majority_answer, 5)} " <>
        "#{String.pad_trailing(maj_mark, 10)} #{String.pad_trailing(pad_float(run.majority_tightness, 4), 12)} " <>
        "#{String.pad_trailing(pad_float(run.outlier_distance, 4), 14)} #{String.pad_trailing(pad_float(run.effective_n, 2), 8)} " <>
        "#{String.pad_trailing(pad_float(ratio, 2), 12)} #{outlier_right}")
    end

    right_outlier = analyzed
      |> Enum.filter(&(&1.trial == 1 and &1.outlier_correct and not &1.majority_correct))
    wrong_outlier = analyzed
      |> Enum.filter(&(&1.trial == 1 and not &1.outlier_correct and &1.majority_correct))

    if right_outlier != [] and wrong_outlier != [] do
      avg_tight_right = right_outlier |> Enum.map(& &1.majority_tightness) |> avg()
      avg_tight_wrong = wrong_outlier |> Enum.map(& &1.majority_tightness) |> avg()
      avg_dist_right = right_outlier |> Enum.map(& &1.outlier_distance) |> avg()
      avg_dist_wrong = wrong_outlier |> Enum.map(& &1.outlier_distance) |> avg()
      avg_ratio_right = right_outlier |> Enum.map(fn r ->
        if r.majority_tightness > @epsilon, do: r.outlier_distance / r.majority_tightness, else: 0.0
      end) |> avg()
      avg_ratio_wrong = wrong_outlier |> Enum.map(fn r ->
        if r.majority_tightness > @epsilon, do: r.outlier_distance / r.majority_tightness, else: 0.0
      end) |> avg()

      IO.puts("\n  SIGNAL COMPARISON (trial 1 only):")
      IO.puts("  Outlier-is-RIGHT tests: avg_tightness=#{pad_float(avg_tight_right, 4)} avg_outlier_dist=#{pad_float(avg_dist_right, 4)} avg_ratio=#{pad_float(avg_ratio_right, 2)}")
      IO.puts("  Outlier-is-WRONG tests: avg_tightness=#{pad_float(avg_tight_wrong, 4)} avg_outlier_dist=#{pad_float(avg_dist_wrong, 4)} avg_ratio=#{pad_float(avg_ratio_wrong, 2)}")

      tight_sep = abs(avg_tight_right - avg_tight_wrong) / max(avg_tight_right + avg_tight_wrong, @epsilon) * 2
      dist_sep = abs(avg_dist_right - avg_dist_wrong) / max(avg_dist_right + avg_dist_wrong, @epsilon) * 2
      IO.puts("  Separation: tightness=#{pad_float(tight_sep * 100, 1)}% distance=#{pad_float(dist_sep * 100, 1)}%")
    end
  end

  defp print_effective_n(analyzed, _panel_label) do
    IO.puts("\n--- EFFECTIVE ENSEMBLE SIZE (correlation-adjusted) ---")
    IO.puts("N_eff < N_actual suggests correlated votes. Low N_eff on wrong consensus = red flag.")
    IO.puts("")

    for test_id <- @test_order do
      run = analyzed |> Enum.filter(&(&1.test_id == test_id)) |> hd()
      n_actual = length(run.workers)
      ratio = run.effective_n / n_actual
      mark = cond do
        not run.majority_correct and ratio < 0.5 -> " 🚩 SUSPICIOUS (low diversity, wrong answer)"
        not run.majority_correct -> " ⚠️  wrong consensus"
        true -> ""
      end
      bar = String.duplicate("█", round(ratio * 20))
      IO.puts("  #{String.pad_trailing(test_id, 6)} N_eff=#{pad_float(run.effective_n, 2)}/#{n_actual} " <>
        "(#{pad_float(ratio * 100, 1)}%) #{bar}#{mark}")
    end
  end

  defp print_black_sheep_results(analyzed, panel_label) do
    IO.puts("\n--- BLACK SHEEP AGGREGATION RESULTS ---")
    IO.puts("Comparing 4 methods: standard MoE, Black Sheep, Corr-Penalized, JSD-Diversity, Suspicion-Gated")
    IO.puts("")

    methods = [
      "MoE",
      "BlackSheep(3x)",
      "BlackSheep(5x)",
      "Corr-Penalized",
      "JSD-Diversity",
      "Suspicion-Gated"
    ]

    header = "  #{String.pad_trailing("Test", 6)} #{String.pad_trailing("Correct", 9)} " <>
      Enum.map_join(methods, "", fn m -> String.pad_trailing(m, 16) end)
    IO.puts(header)
    IO.puts("  " <> String.duplicate("-", String.length(header)))

    method_scores = Map.new(methods, fn m -> {m, 0} end)

    method_scores = for test_id <- @test_order, reduce: method_scores do
      acc ->
        runs = Enum.filter(analyzed, &(&1.test_id == test_id))
        correct = @correct_answers[test_id]

        results_per_method = for run <- runs do
          choices = run.choices

          {moe_ans, _, _} = black_sheep_vote(run.workers, choices, 999.0, 1.0)
          {bs3_ans, _, _} = black_sheep_vote(run.workers, choices, 0.15, 3.0)
          {bs5_ans, _, _} = black_sheep_vote(run.workers, choices, 0.15, 5.0)
          {cp_ans, _} = correlation_penalized_vote(run.workers, choices)
          {jd_ans, _} = jsd_diversity_weighted(run.workers, choices)
          {sg_ans, _, _, _} = suspicion_gated_outlier_boost(run.workers, choices)

          %{
            "MoE" => moe_ans == correct,
            "BlackSheep(3x)" => bs3_ans == correct,
            "BlackSheep(5x)" => bs5_ans == correct,
            "Corr-Penalized" => cp_ans == correct,
            "JSD-Diversity" => jd_ans == correct,
            "Suspicion-Gated" => sg_ans == correct
          }
        end

        cells = for m <- methods do
          hits = Enum.count(results_per_method, & &1[m])
          total = length(results_per_method)
          if hits > 0, do: "✅ #{hits}/#{total}", else: "   #{hits}/#{total}"
        end

        IO.puts("  #{String.pad_trailing(test_id, 6)} #{String.pad_trailing(correct, 9)} " <>
          Enum.map_join(cells, "", fn c -> String.pad_trailing(c, 16) end))

        Enum.reduce(methods, acc, fn m, inner_acc ->
          hits = Enum.count(results_per_method, & &1[m])
          Map.update!(inner_acc, m, &(&1 + hits))
        end)
    end

    total_runs = length(analyzed)
    IO.puts("  " <> String.duplicate("-", String.length(header)))

    totals = for m <- methods do
      score = method_scores[m]
      pct = Float.round(score / total_runs * 100, 1)
      "#{score}/#{total_runs}(#{pct}%)"
    end

    IO.puts("  #{String.pad_trailing("TOTAL", 15)} " <>
      Enum.map_join(totals, "", fn t -> String.pad_trailing(t, 16) end))

    IO.puts("\n  Detail: Suspicion-Gated boost values (trial 1):")
    for test_id <- @test_order do
      run = analyzed |> Enum.filter(&(&1.test_id == test_id and &1.trial == 1)) |> hd()
      {_ans, dist, suspicion, boost} = suspicion_gated_outlier_boost(run.workers, run.choices)
      correct = @correct_answers[test_id]
      p_correct = Map.get(dist, correct, 0.0)
      mark = if dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0) == correct, do: "✅", else: "❌"
      IO.puts("    #{test_id}: suspicion=#{pad_float(suspicion, 3)} boost=#{pad_float(boost, 2)}x " <>
        "P(#{correct})=#{pad_float(p_correct * 100, 1)}% #{mark}")
    end
  end

  defp print_correlation_penalized(analyzed, _panel_label) do
    IO.puts("\n--- PAIRWISE MODEL SIMILARITY (JSD-based, trial 1) ---")
    IO.puts("1.0 = identical distributions, 0.0 = maximally different")
    IO.puts("Models sharing training biases will cluster near 1.0")
    IO.puts("")

    run = analyzed |> Enum.filter(&(&1.test_id == "A1" and &1.trial == 1)) |> hd()
    models = Enum.map(run.workers, & &1.model) |> Enum.sort()

    IO.puts("  A1 (Car Wash — consensus WRONG, outlier stablelm2 RIGHT):")
    IO.puts("  #{String.pad_trailing("", 22)} " <>
      Enum.map_join(models, "", fn m ->
        short = m |> String.split(":") |> hd() |> String.slice(0, 8)
        String.pad_trailing(short, 10)
      end))

    max_jsd = :math.log(length(run.choices))
    for model_a <- models do
      row = for model_b <- models do
        if model_a == model_b do
          "   ---   "
        else
          pair_jsd = run.pairwise_jsd
            |> Enum.find(fn {{a, b}, _} ->
              (a == model_a and b == model_b) or (a == model_b and b == model_a)
            end)
          case pair_jsd do
            nil -> "   N/A   "
            {_, val} ->
              sim = 1.0 - val / max_jsd
              pad_float(sim, 3)
          end
        end
      end

      short_a = model_a |> String.split(":") |> hd() |> String.slice(0, 8)
      IO.puts("  #{String.pad_trailing(short_a, 22)} " <>
        Enum.map_join(row, "", fn r -> String.pad_trailing(r, 10) end))
    end

    run6 = analyzed |> Enum.filter(&(&1.test_id == "A6" and &1.trial == 1))
    if run6 != [] do
      run6 = hd(run6)
      IO.puts("\n  A6 (Moses Illusion — consensus RIGHT, 4 knowers):")
      IO.puts("  #{String.pad_trailing("", 22)} " <>
        Enum.map_join(models, "", fn m ->
          short = m |> String.split(":") |> hd() |> String.slice(0, 8)
          String.pad_trailing(short, 10)
        end))

      max_jsd6 = :math.log(length(run6.choices))
      models6 = Enum.map(run6.workers, & &1.model) |> Enum.sort()
      for model_a <- models6 do
        row = for model_b <- models6 do
          if model_a == model_b do
            "   ---   "
          else
            pair_jsd = run6.pairwise_jsd
              |> Enum.find(fn {{a, b}, _} ->
                (a == model_a and b == model_b) or (a == model_b and b == model_a)
              end)
            case pair_jsd do
              nil -> "   N/A   "
              {_, val} ->
                sim = 1.0 - val / max_jsd6
                pad_float(sim, 3)
            end
          end
        end

        short_a = model_a |> String.split(":") |> hd() |> String.slice(0, 8)
        IO.puts("  #{String.pad_trailing(short_a, 22)} " <>
          Enum.map_join(row, "", fn r -> String.pad_trailing(r, 10) end))
      end
    end
  end

  defp print_cross_dataset_summary(g5_data, h5_data) do
    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("CROSS-DATASET SUMMARY: Can consensus skepticism crack A1?")
    IO.puts(String.duplicate("=", 100))

    for {label, data} <- [{"5G", g5_data}, {"5H", h5_data}] do
      collective = data["collective"]
      IO.puts("\n--- #{label} ---")

      for panel <- ["curated_5", "full_8"] do
        panel_label = if panel == "curated_5", do: "Curated 5", else: "Full 8"
        panel_runs = Enum.filter(collective, &(&1["config"] == panel))
        analyzed = analyze_panel(panel_runs)

        a1_runs = Enum.filter(analyzed, &(&1.test_id == "A1"))

        methods_results = for run <- a1_runs do
          choices = run.choices
          {moe_ans, moe_dist, _} = black_sheep_vote(run.workers, choices, 999.0, 1.0)
          {bs3_ans, bs3_dist, _} = black_sheep_vote(run.workers, choices, 0.15, 3.0)
          {bs5_ans, bs5_dist, _} = black_sheep_vote(run.workers, choices, 0.15, 5.0)
          {bs10_ans, bs10_dist, _} = black_sheep_vote(run.workers, choices, 0.10, 10.0)
          {cp_ans, cp_dist} = correlation_penalized_vote(run.workers, choices)
          {sg_ans, sg_dist, susp, boost} = suspicion_gated_outlier_boost(run.workers, choices)

          %{
            moe: {moe_ans, Map.get(moe_dist, "B", 0.0)},
            bs3: {bs3_ans, Map.get(bs3_dist, "B", 0.0)},
            bs5: {bs5_ans, Map.get(bs5_dist, "B", 0.0)},
            bs10: {bs10_ans, Map.get(bs10_dist, "B", 0.0)},
            cp: {cp_ans, Map.get(cp_dist, "B", 0.0)},
            sg: {sg_ans, Map.get(sg_dist, "B", 0.0), susp, boost}
          }
        end

        IO.puts("\n  #{panel_label}:")
        IO.puts("  A1 (correct=B): P(B) under each method:")
        for {r, i} <- Enum.with_index(methods_results, 1) do
          {_, moe_b} = r.moe
          {_, bs3_b} = r.bs3
          {_, bs5_b} = r.bs5
          {_, bs10_b} = r.bs10
          {_, cp_b} = r.cp
          {sg_ans, sg_b, susp, boost} = r.sg

          IO.puts("    Trial #{i}: MoE=#{pad_float(moe_b * 100, 1)}% " <>
            "BS(3x)=#{pad_float(bs3_b * 100, 1)}% " <>
            "BS(5x)=#{pad_float(bs5_b * 100, 1)}% " <>
            "BS(10x)=#{pad_float(bs10_b * 100, 1)}% " <>
            "Corr-Pen=#{pad_float(cp_b * 100, 1)}% " <>
            "Susp-Gate=#{pad_float(sg_b * 100, 1)}%(susp=#{pad_float(susp, 2)},boost=#{pad_float(boost, 1)}x)")
        end

        gap = methods_results |> hd()
        {_, baseline_b} = gap.moe
        {_, best_b} = gap.bs10
        improvement = best_b - baseline_b
        IO.puts("    B mass improvement (MoE→BS10x): +#{pad_float(improvement * 100, 1)} percentage points")
        IO.puts("    Need P(B) > P(A) to flip. Current gap to close: #{pad_float((0.5 - best_b) * 100, 1)} pp")
      end
    end

    IO.puts("\n" <> String.duplicate("=", 100))
    IO.puts("VERDICT")
    IO.puts(String.duplicate("=", 100))
    IO.puts("""
    The consensus skepticism metrics DIAGNOSE the problem (A1 shows suspicious
    consensus pattern) but the aggregation methods face a fundamental arithmetic
    constraint: stablelm2 at ~49% B is the sole source of B mass. Even with 10x
    amplification, the sum of A mass from 4 models overwhelms. The effective N
    calculation shows the panel's diversity is low on A1, confirming the correlated
    jury theorem prediction.

    EC-18 (pending validation): Consensus skepticism can DETECT shared ignorance
    via JSD-based metrics but cannot OVERCOME single-knower arithmetic constraints
    through weighting alone. A second knower is structurally required.
    """)

    IO.puts(String.duplicate("=", 100))
    IO.puts("END OF PHASE 5I CONSENSUS SKEPTICISM ANALYSIS")
    IO.puts(String.duplicate("=", 100) <> "\n")
  end

  # --- Helpers ---

  defp normalize_workers(per_worker, choices) do
    Enum.map(per_worker, fn w ->
      probs = w["probabilities"]
      dist = Map.new(choices, fn c -> {c, Map.get(probs, c, 0.0)} end)
      total = dist |> Map.values() |> Enum.sum()
      dist = if total > 0, do: Map.new(dist, fn {k, v} -> {k, v / total} end), else: dist
      %{model: w["model"], dist: dist, confidence: w["confidence"] || 0.0}
    end)
  end

  defp top_answer(dist), do: dist |> Enum.max_by(fn {_c, v} -> v end) |> elem(0)

  defp avg(list) when length(list) == 0, do: 0.0
  defp avg(list), do: Enum.sum(list) / length(list)

  defp pad_float(val, decimals) do
    Float.round(val / 1, decimals) |> to_string()
  end

  defp load_traces do
    g5_path = Path.join([__DIR__, "benchmark_traces", "phase5g", "phase5g-collective-summary.json"])
    h5_path = Path.join([__DIR__, "benchmark_traces", "phase5h", "phase5h-summary.json"])

    g5 = g5_path |> File.read!() |> Jason.decode!()
    h5 = h5_path |> File.read!() |> Jason.decode!()

    {g5, h5}
  end
end

Phase5I.ConsensusSkepticism.run()
