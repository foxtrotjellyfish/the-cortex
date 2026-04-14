defmodule Cortex.LLM.Adapters.LlamaCpp do
  @moduledoc """
  LLM adapter for llama-server (llama.cpp HTTP server).

  Targets the OpenAI-compatible /v1/chat/completions endpoint.
  llama-server runs with a single model loaded; the model field in the
  request is ignored by the server (it serves whatever GGUF is loaded).

  Works anywhere llama.cpp compiles: macOS (Metal), Linux (CUDA/CPU),
  BSD variants (CPU), embedded/constrained hardware. The adapter is
  transport-only — it doesn't care what's on the other end of localhost.

  Start llama-server manually:
    llama-server --model /path/to/model.gguf --port 8080 --ctx-size 2048

  Or wire Cortex.LLM.LlamaServer to manage the process via OTP Port supervision.
  """

  @behaviour Cortex.LLM.Adapter

  @default_base_url "http://localhost:8080"
  @default_model "local"

  @impl true
  def call(system_prompt, input, config) do
    model = Map.get(config, :model, @default_model)
    base_url = Map.get(config, :base_url, @default_base_url)

    body =
      %{
        "model" => model,
        "messages" => [
          %{"role" => "system", "content" => system_prompt},
          %{"role" => "user", "content" => input}
        ],
        "stream" => false
      }
      |> put_option(config, :temperature, "temperature")
      |> put_option(config, :top_p, "top_p")
      |> put_option(config, :max_tokens, "max_tokens")
      |> put_option(config, :repeat_penalty, "repeat_penalty")

    case Req.post("#{base_url}/v1/chat/completions", json: body, receive_timeout: 120_000) do
      {:ok, %{status: 200, body: body}} ->
        content = get_in(body, ["choices", Access.at(0), "message", "content"])
        usage = Map.get(body, "usage", %{})

        {:ok,
         %{
           output: content,
           model: get_in(body, ["model"]) || model,
           tokens_in: Map.get(usage, "prompt_tokens"),
           tokens_out: Map.get(usage, "completion_tokens")
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, "llama-server returned #{status}: #{inspect(body)}"}

      {:error, reason} ->
        {:error, "llama-server connection failed: #{inspect(reason)}"}
    end
  end

  defp put_option(body, config, key, field) do
    case Map.get(config, key) do
      nil -> body
      val -> Map.put(body, field, val)
    end
  end
end
