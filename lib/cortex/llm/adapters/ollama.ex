defmodule Cortex.LLM.Adapters.Ollama do
  @moduledoc """
  LLM adapter for locally-hosted models via Ollama.
  Uses the /api/chat endpoint directly. Zero cost, zero network, full privacy.
  """

  @behaviour Cortex.LLM.Adapter

  @default_base_url "http://localhost:11434"

  @impl true
  def call(system_prompt, input, config) do
    model = Map.get(config, :model, "tinydolphin")
    base_url = Map.get(config, :base_url, @default_base_url)

    options_keys = [:temperature, :top_p, :repeat_penalty, :num_predict]

    options =
      config
      |> Map.take(options_keys)
      |> Map.new(fn {k, v} -> {to_string(k), v} end)

    body =
      %{
        "model" => model,
        "messages" => [
          %{"role" => "system", "content" => system_prompt},
          %{"role" => "user", "content" => input}
        ],
        "stream" => false
      }
      |> then(fn b -> if map_size(options) > 0, do: Map.put(b, "options", options), else: b end)

    case Req.post("#{base_url}/api/chat", json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: %{"message" => %{"content" => content}} = resp_body}} ->
        {:ok,
         %{
           output: content,
           model: model,
           tokens_in: get_in(resp_body, ["prompt_eval_count"]),
           tokens_out: get_in(resp_body, ["eval_count"])
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "Ollama returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Ollama connection failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Score multiple-choice answers via logprobs.

  When `config` includes a `:system` key, uses `/api/chat` with the viewpoint
  as a system message and the MC question as a user message. This keeps the
  model in "answer the question" mode rather than "write about the viewpoint"
  mode, which is critical for models like gemma2 that otherwise produce prose
  tokens instead of A/B/C/D.

  Falls back to `/api/generate` with a flat prompt when no `:system` is set.

  Returns `{:ok, %{answer: "B", probabilities: %{...}, confidence: float}}`
  or `{:error, reason}`.
  """
  def score_choices(prompt, config, choices \\ ~w(A B C D)) do
    model = Map.get(config, :model, "tinydolphin")
    base_url = Map.get(config, :base_url, @default_base_url)

    choice_list = Enum.join(choices, ", ")

    body =
      case Map.get(config, :system) do
        nil ->
          %{
            "model" => model,
            "prompt" => prompt,
            "stream" => false,
            "logprobs" => true,
            "top_logprobs" => 10,
            "options" => %{"num_predict" => 1, "temperature" => 0}
          }

        system_prompt ->
          %{
            "model" => model,
            "messages" => [
              %{
                "role" => "system",
                "content" =>
                  system_prompt <>
                    " Respond with ONLY a single letter: #{choice_list}."
              },
              %{"role" => "user", "content" => prompt}
            ],
            "stream" => false,
            "logprobs" => true,
            "top_logprobs" => 10,
            "options" => %{"num_predict" => 1, "temperature" => 0}
          }
      end

    endpoint =
      if Map.has_key?(config, :system),
        do: "#{base_url}/api/chat",
        else: "#{base_url}/api/generate"

    case Req.post(endpoint, json: body, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: resp_body}} ->
        {:ok, parse_logprobs(resp_body, choices)}

      {:ok, %{status: status, body: body}} ->
        {:error, "Ollama returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Ollama connection failed: #{inspect(reason)}"}
    end
  end

  defp parse_logprobs(resp_body, choices) do
    raw_probs =
      resp_body
      |> get_in(["logprobs"])
      |> List.wrap()
      |> List.first(%{})
      |> Map.get("top_logprobs", [])
      |> Enum.reduce(%{}, fn entry, acc ->
        token = entry["token"] |> String.trim()

        if token in choices do
          Map.put(acc, token, :math.exp(entry["logprob"]))
        else
          acc
        end
      end)

    total = Map.values(raw_probs) |> Enum.sum()

    probabilities =
      if total > 0,
        do: Map.new(raw_probs, fn {k, v} -> {k, Float.round(v / total, 4)} end),
        else: raw_probs

    sorted = Enum.sort_by(probabilities, &elem(&1, 1), :desc)

    {answer, top_p} =
      case sorted do
        [{a, p} | _] -> {a, p}
        [] -> {nil, 0.0}
      end

    second_p =
      case sorted do
        [_, {_, p} | _] -> p
        _ -> 0.0
      end

    %{
      answer: answer,
      probabilities: probabilities,
      confidence: Float.round(top_p - second_p, 4),
      raw_response: String.trim(resp_body["response"] || "")
    }
  end
end
