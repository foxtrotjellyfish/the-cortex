#!/usr/bin/env elixir
# Phase 1: Structured Output Test
# Run with: mix run scripts/phase1_structured_output_test.exs
#
# Pass criteria:
#   Prompt A: parseable JSON with 3-5 subtask items, at least 8/10 runs
#   Prompt B: coherent factual sentence

defmodule Phase1Test do
  @ollama_url "http://localhost:11434/api/chat"
  @trials 10

  @prompt_a_system "You are a task planner. Given a goal, output ONLY valid JSON: {\"subtasks\": [\"...\", \"...\", \"...\"]}\nNo explanation. No markdown. No other text. Only the JSON object."
  @prompt_a_input "Research the history of the BEAM virtual machine"

  @prompt_b_system "You are a focused researcher. Answer in 1-2 sentences only. No preamble."
  @prompt_b_input "What year was the BEAM VM first released and by whom?"

  def run do
    IO.puts("\n=== Phase 1: Structured Output Test ===\n")
    IO.puts("Testing whether sub-2B models can produce reliable JSON for fan-out routing.\n")

    for model <- ["tinydolphin", "llama3.2:3b"] do
      IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
      IO.puts("Model: #{model}")
      IO.puts("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
      test_prompt_a(model)
      test_prompt_b(model)
    end

    IO.puts("\n=== Done ===")
  end

  defp test_prompt_a(model) do
    IO.puts("PROMPT A — JSON planner (#{@trials} trials)")
    IO.puts("Input: \"#{@prompt_a_input}\"\n")

    results =
      for i <- 1..@trials do
        case call(model, @prompt_a_system, @prompt_a_input) do
          {:ok, raw} ->
            trimmed = String.trim(raw)
            case parse_json(trimmed) do
              {:ok, %{"subtasks" => subtasks}}
              when is_list(subtasks) and length(subtasks) > 0 and
                     is_binary(hd(subtasks)) ->
                count = length(subtasks)
                IO.puts("  [#{i}/#{@trials}] PASS (#{count} subtasks) — #{preview(subtasks)}")
                :pass

              {:ok, %{"subtasks" => subtasks}} when is_list(subtasks) and length(subtasks) > 0 ->
                IO.puts("  [#{i}/#{@trials}] FAIL (subtasks not strings) — #{inspect(hd(subtasks)) |> String.slice(0, 80)}")
                :fail

              {:ok, other} ->
                IO.puts("  [#{i}/#{@trials}] FAIL (parsed but wrong shape) — #{inspect(other) |> String.slice(0, 80)}")
                :fail

              {:error, _} ->
                IO.puts("  [#{i}/#{@trials}] FAIL (not parseable JSON) — #{String.slice(trimmed, 0, 100)}")
                :fail
            end

          {:error, reason} ->
            IO.puts("  [#{i}/#{@trials}] ERROR — #{inspect(reason)}")
            :error
        end
      end

    passes = Enum.count(results, &(&1 == :pass))
    verdict = cond do
      passes >= 8 -> "PASS ✓"
      passes >= 5 -> "MARGINAL ⚠"
      true -> "FAIL ✗"
    end
    IO.puts("\n  Result: #{passes}/#{@trials} pass → #{verdict}\n")
    {model, :prompt_a, passes}
  end

  defp test_prompt_b(model) do
    IO.puts("PROMPT B — worker factual sentence")
    IO.puts("Input: \"#{@prompt_b_input}\"\n")

    case call(model, @prompt_b_system, @prompt_b_input) do
      {:ok, raw} ->
        IO.puts("  Response: #{String.trim(raw)}\n")
      {:error, reason} ->
        IO.puts("  ERROR: #{inspect(reason)}\n")
    end
  end

  defp call(model, system_prompt, input) do
    body = Jason.encode!(%{
      "model" => model,
      "messages" => [
        %{"role" => "system", "content" => system_prompt},
        %{"role" => "user", "content" => input}
      ],
      "stream" => false
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

  defp parse_json(str) do
    # Try direct parse first
    case Jason.decode(str) do
      {:ok, _} = ok -> ok
      {:error, _} ->
        # Try extracting JSON object from surrounding text
        case Regex.run(~r/\{[^{}]*"subtasks"[^{}]*\}/s, str) do
          [json_str] -> Jason.decode(json_str)
          nil -> {:error, :no_json_found}
        end
    end
  end

  defp preview(subtasks) do
    subtasks
    |> Enum.take(2)
    |> Enum.map(&String.slice(&1, 0, 40))
    |> Enum.join(" | ")
  end
end

Phase1Test.run()
