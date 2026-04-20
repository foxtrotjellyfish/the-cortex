defmodule Cortex.Benchmark.AnswerExtractor do
  @moduledoc """
  Pure Elixir answer extraction from worker prose.

  Each test family has known correct/incorrect answer tokens.
  Pattern-matching extracts a structured answer from free-form LLM output,
  enabling algorithmic aggregation without an LLM judge.
  """

  @type answer :: String.t() | nil
  @type vote_result :: %{answer: answer, votes: pos_integer(), total: pos_integer()}

  @doc """
  Extract an answer from a single worker's prose output for a given test family.

  Returns a normalized answer string, or nil if no answer could be extracted.
  """
  @spec extract(String.t(), String.t()) :: answer
  def extract(worker_output, test_id) do
    text = String.downcase(worker_output)

    case test_id do
      "A1" -> extract_a1(text)
      "A2" -> extract_a2(text)
      "A3" -> extract_a3(text)
      "A4" -> extract_a4(text)
      "A5" -> extract_a5(text)
      _ -> nil
    end
  end

  @doc """
  Extract answers from all workers and return the majority vote.

  Returns a map with the winning answer, vote count, total workers,
  all extracted answers, and the full vote distribution.
  """
  @spec majority_vote([String.t()], String.t()) :: vote_result
  def majority_vote(worker_outputs, test_id) do
    extracted = Enum.map(worker_outputs, &extract(&1, test_id))

    non_nil = Enum.reject(extracted, &is_nil/1)

    frequencies =
      non_nil
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_answer, count} -> count end, :desc)

    {winner, winner_count} =
      case frequencies do
        [{answer, count} | _] -> {answer, count}
        [] -> {nil, 0}
      end

    %{
      answer: winner,
      votes: winner_count,
      total: length(worker_outputs),
      extracted: extracted,
      distribution: Map.new(frequencies)
    }
  end

  # A1: Car Wash — correct answer rejects walking, mentions needing a car/driving
  defp extract_a1(text) do
    needs_car = Regex.match?(~r/\b(drive|car|vehicle|don'?t walk|should not walk|shouldn'?t walk|need.{0,20}car|bring.{0,20}car)\b/, text)
    just_walk = Regex.match?(~r/\b(yes.{0,30}walk|you (can|should|could) walk|50 meters.{0,20}(short|easy|walkable))\b/, text)

    cond do
      needs_car and not just_walk -> "need_car"
      just_walk and not needs_car -> "walk"
      true -> nil
    end
  end

  # A2: Sally-Anne (false belief) — correct answer is "basket"
  defp extract_a2(text) do
    says_basket = Regex.match?(~r/\b(basket|where she (left|put|placed) it|original (location|place|spot))\b/, text)
    says_box = Regex.match?(~r/\b(the box|in.{0,10}box|look.{0,15}box)\b/, text)

    cond do
      says_basket and not says_box -> "basket"
      says_box and not says_basket -> "box"
      says_basket and says_box -> disambiguate_a2(text)
      true -> nil
    end
  end

  defp disambiguate_a2(text) do
    basket_pos = find_answer_position(text, ~r/\b(basket)\b/)
    box_pos = find_answer_position(text, ~r/\b(box)\b/)

    final_answer = Regex.run(~r/(?:answer|look|search|check).{0,30}(basket|box)/, text)

    case final_answer do
      [_, "basket"] -> "basket"
      [_, "box"] -> "box"
      _ ->
        cond do
          basket_pos && box_pos && basket_pos > box_pos -> "basket"
          true -> "box"
        end
    end
  end

  # A3: Farmer Sheep — correct answer is 8
  defp extract_a3(text) do
    numbers = Regex.scan(~r/\b(\d+)\b/, text)
      |> Enum.map(fn [_, n] -> String.to_integer(n) end)
      |> Enum.reject(&(&1 in [15, 0]))
      |> Enum.filter(&(&1 in 1..14))

    answer_pattern = Regex.run(~r/(?:answer|left|remain|alive|survive|has).{0,30}\b(\d+)\b/, text)

    case answer_pattern do
      [_, n] ->
        num = String.to_integer(n)
        if num in 1..14, do: Integer.to_string(num), else: nil
      nil ->
        case Enum.frequencies(numbers) |> Enum.sort_by(&elem(&1, 1), :desc) do
          [{n, _} | _] -> Integer.to_string(n)
          [] -> nil
        end
    end
  end

  # A4: Polar Bear — correct answer is "white"
  defp extract_a4(text) do
    colors = ~w(white black brown gray grey red blue green yellow orange tan)

    found =
      colors
      |> Enum.filter(fn color -> Regex.match?(~r/\b#{color}\b/, text) end)

    answer_pattern = Regex.run(~r/(?:color|bear).{0,40}\b(white|black|brown|gray|grey)\b/, text)

    case answer_pattern do
      [_, color] -> normalize_color(color)
      nil ->
        case found do
          [single] -> normalize_color(single)
          _multiple_or_none ->
            final = Regex.run(~r/(?:answer|color is|bear is|therefore|so).{0,30}\b(white|black|brown|gray|grey)\b/, text)
            case final do
              [_, c] -> normalize_color(c)
              nil -> if "white" in found, do: "white", else: List.first(found)
            end
        end
    end
  end

  # A5: Siblings — correct answer recognizes narrator is female/sister
  defp extract_a5(text) do
    sister_signal = Regex.match?(~r/\b(sister|female|woman|girl|she|narrator is.{0,15}(female|sister|woman|girl))\b/, text)
    brother_signal = Regex.match?(~r/\b(two brothers|both brothers|he has.{0,10}brother)\b/, text)

    cond do
      sister_signal and not brother_signal -> "sister"
      brother_signal and not sister_signal -> "brother"
      sister_signal and brother_signal -> "sister"
      true -> nil
    end
  end

  @doc """
  Aggregate logprobs-scored MC results via majority vote.

  Takes a list of `%{answer: "B", probabilities: %{...}, confidence: float}`
  maps (one per worker) and returns the majority answer with vote breakdown.
  """
  @spec majority_vote_mc([map()]) :: map()
  def majority_vote_mc(scored_results) do
    answers = Enum.map(scored_results, & &1.answer)
    non_nil = Enum.reject(answers, &is_nil/1)

    frequencies =
      non_nil
      |> Enum.frequencies()
      |> Enum.sort_by(&elem(&1, 1), :desc)

    {winner, winner_count} =
      case frequencies do
        [{answer, count} | _] -> {answer, count}
        [] -> {nil, 0}
      end

    %{
      answer: winner,
      votes: winner_count,
      total: length(scored_results),
      extracted: answers,
      distribution: Map.new(frequencies),
      per_worker: scored_results
    }
  end

  @doc """
  Confidence-weighted MC aggregation.

  Instead of 1 vote per worker, each worker contributes its probability
  distribution. The choice with the highest summed probability wins.
  """
  @spec weighted_vote_mc([map()], [String.t()]) :: map()
  def weighted_vote_mc(scored_results, choices \\ ~w(A B C D)) do
    summed =
      Enum.reduce(scored_results, %{}, fn result, acc ->
        Enum.reduce(choices, acc, fn choice, inner_acc ->
          p = Map.get(result.probabilities || %{}, choice, 0.0)
          Map.update(inner_acc, choice, p, &(&1 + p))
        end)
      end)

    sorted = Enum.sort_by(summed, &elem(&1, 1), :desc)

    {winner, top_score} =
      case sorted do
        [{a, s} | _] -> {a, s}
        [] -> {nil, 0.0}
      end

    %{
      answer: winner,
      scores: Map.new(sorted),
      total: length(scored_results),
      top_score: Float.round(top_score, 4),
      per_worker: scored_results
    }
  end

  defp normalize_color("grey"), do: "gray"
  defp normalize_color(c), do: c

  defp find_answer_position(text, regex) do
    case Regex.run(regex, text, return: :index) do
      [{pos, _} | _] -> pos
      _ -> nil
    end
  end
end
