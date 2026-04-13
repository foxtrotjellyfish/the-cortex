#!/usr/bin/env elixir
# Phase 1B: Natural Language Planner Test
# Hypothesis: plain English decomposition outperforms JSON for sub-3B models.
# Run with: mix run scripts/phase1b_natural_language_test.exs

defmodule Phase1BTest do
  @ollama_url "http://localhost:11434/api/chat"
  @trials 10

  # Natural language decomposition — no JSON, no schema, just numbered steps
  @prompt_a_system """
  You are a research planner. Break the given goal into exactly 3-5 concrete research steps.
  Format: number each step. One step per line. Plain English only.
  No explanation, no intro sentence, no conclusion. Just the numbered steps.
  """

  @prompt_a_input "How would you investigate when and where the BEAM virtual machine was invented?"

  @prompt_b_system "You are a focused researcher. Answer in 1-2 sentences only. No preamble."
  @prompt_b_input "What year was the BEAM VM first released and by whom?"

  # Lower temperature for analytical/planning tasks
  @temperature 0.3

  def run do
    IO.puts("\n=== Phase 1B: Natural Language Planner Test ===")
    IO.puts("Hypothesis: plain English steps > JSON for sub-3B models.\n")
    IO.puts("Temperature: #{@temperature} (lower = less hallucination)\n")

    for model <- ["tinydolphin", "llama3.2:3b"] do
      IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      IO.puts("Model: #{model}")
      IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
      {passes, _} = test_prompt_a(model)
      test_prompt_b(model)
      IO.puts("  [1B pass rate vs 1A: #{passes}/10 vs #{phase1a_baseline(model)}/10]\n")
    end

    IO.puts("=== Done ===")
  end

  defp phase1a_baseline("tinydolphin"), do: 0
  defp phase1a_baseline("llama3.2:3b"), do: 5

  defp test_prompt_a(model) do
    IO.puts("PROMPT A — natural language planner (#{@trials} trials)")
    IO.puts("Input: \"#{@prompt_a_input}\"\n")

    results =
      for i <- 1..@trials do
        case call(model, @prompt_a_system, @prompt_a_input) do
          {:ok, raw} ->
            trimmed = String.trim(raw)
            steps = extract_steps(trimmed)
            count = length(steps)

            cond do
              count >= 3 and count <= 5 ->
                IO.puts("  [#{i}/#{@trials}] PASS (#{count} steps) — #{preview_steps(steps)}")
                :pass

              count > 5 ->
                IO.puts("  [#{i}/#{@trials}] MARGINAL (#{count} steps, too many) — #{preview_steps(Enum.take(steps, 3))}")
                :marginal

              count in [1, 2] ->
                IO.puts("  [#{i}/#{@trials}] FAIL (#{count} steps, too few) — #{preview_steps(steps)}")
                :fail

              true ->
                IO.puts("  [#{i}/#{@trials}] FAIL (no steps extracted) — #{String.slice(trimmed, 0, 100)}")
                :fail
            end

          {:error, reason} ->
            IO.puts("  [#{i}/#{@trials}] ERROR — #{inspect(reason)}")
            :error
        end
      end

    passes = Enum.count(results, &(&1 == :pass))
    marginals = Enum.count(results, &(&1 == :marginal))

    verdict = cond do
      passes >= 8 -> "PASS ✓"
      passes + marginals >= 8 -> "PASS WITH LOOSE CRITERIA ✓ (some had >5 steps)"
      passes >= 5 -> "MARGINAL ⚠"
      true -> "FAIL ✗"
    end

    IO.puts("\n  Result: #{passes}/#{@trials} strict pass (#{marginals} marginal) → #{verdict}\n")
    {passes, marginals}
  end

  defp test_prompt_b(model) do
    IO.puts("PROMPT B — worker factual (single trial)")
    IO.puts("Input: \"#{@prompt_b_input}\"\n")

    case call(model, @prompt_b_system, @prompt_b_input) do
      {:ok, raw} -> IO.puts("  Response: #{String.trim(raw)}\n")
      {:error, reason} -> IO.puts("  ERROR: #{inspect(reason)}\n")
    end
  end

  # Extract numbered/bulleted steps from plain text
  # Handles: "1. Step", "1) Step", "- Step", "• Step", plain numbered lines
  defp extract_steps(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) == 0))
    |> Enum.filter(fn line ->
      Regex.match?(~r/^(\d+[\.\):]|\-|•|\*)/, line) or
        (length(String.split(text, "\n") |> Enum.reject(&(String.trim(&1) == ""))) <= 5 and String.length(line) > 10)
    end)
    |> Enum.map(fn line ->
      # Strip leading number/bullet
      Regex.replace(~r/^(\d+[\.\):\s]+|\-\s+|•\s+|\*\s+)/, line, "")
      |> String.trim()
    end)
    |> Enum.reject(&(String.length(&1) < 5))
  end

  defp preview_steps(steps) do
    steps
    |> Enum.take(2)
    |> Enum.map(&String.slice(&1, 0, 45))
    |> Enum.join(" | ")
  end

  defp call(model, system_prompt, input) do
    body = Jason.encode!(%{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => input}
      ],
      "stream" => false,
      "options" => %{
        "temperature" => @temperature,
        "top_p" => 0.9,
        "repeat_penalty" => 1.1
      }
    })

    case :httpc.request(:post,
      {~c"#{@ollama_url}", [], ~c"application/json", body},
      [timeout: 120_000, connect_timeout: 5_000],
      []
    ) do
      {:ok, {{_, 200, _}, _, resp_body}} ->
        case Jason.decode(List.to_string(resp_body)) do
          {:ok, %{"message" => %{"content" => content}}} -> {:ok, content}
          other -> {:error, "unexpected response: #{inspect(other)}"}
        end

      {:ok, {{_, status, _}, _, body}} ->
        {:error, "HTTP #{status}: #{List.to_string(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end

Phase1BTest.run()
