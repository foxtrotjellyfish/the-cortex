defmodule Cortex.LLM.Adapters.Anthropic do
  @moduledoc """
  LLM adapter for Anthropic's Messages API. Claude 3.5 Haiku for speed,
  Sonnet 4 for depth. Each domain can pick its own model.
  """

  @behaviour Cortex.LLM.Adapter

  @default_model "claude-3-5-haiku-20241022"
  @api_url "https://api.anthropic.com/v1/messages"

  @impl true
  def call(system_prompt, input, config) do
    api_key =
      Map.get(config, :api_key) ||
        Application.get_env(:cortex, :anthropic_api_key) ||
        System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      {:error, "ANTHROPIC_API_KEY not configured — export it or set in config/dev.exs"}
    else
      model = Map.get(config, :model, @default_model)
      max_tokens = Map.get(config, :max_tokens, 1024)

      body = %{
        "model" => model,
        "max_tokens" => max_tokens,
        "system" => system_prompt,
        "messages" => [%{"role" => "user", "content" => input}]
      }

      headers = [
        {"x-api-key", api_key},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
      ]

      case Req.post(@api_url, json: body, headers: headers, receive_timeout: 60_000) do
        {:ok, %{status: 200, body: resp}} ->
          content = get_in(resp, ["content", Access.at(0), "text"])
          usage = resp["usage"]

          {:ok,
           %{
             output: content,
             model: model,
             tokens_in: usage["input_tokens"],
             tokens_out: usage["output_tokens"]
           }}

        {:ok, %{status: status, body: resp_body}} ->
          {:error, "Anthropic API #{status}: #{inspect(resp_body)}"}

        {:error, reason} ->
          {:error, "Anthropic connection failed: #{inspect(reason)}"}
      end
    end
  end
end
