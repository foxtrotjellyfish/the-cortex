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
end
