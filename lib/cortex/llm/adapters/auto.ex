defmodule Cortex.LLM.Adapters.Auto do
  @moduledoc """
  Smart adapter that tries Anthropic when ANTHROPIC_API_KEY is set,
  falls back to Ollama otherwise. Lets the demo work immediately
  and upgrade transparently when a real API key appears.
  """

  @behaviour Cortex.LLM.Adapter

  @impl true
  def call(system_prompt, input, config) do
    api_key =
      Map.get(config, :api_key) ||
        Application.get_env(:cortex, :anthropic_api_key) ||
        System.get_env("ANTHROPIC_API_KEY")

    if is_nil(api_key) or api_key == "" do
      ollama_config = %{model: "llama3.2:3b"}

      case Cortex.LLM.Adapters.Ollama.call(system_prompt, input, ollama_config) do
        {:ok, resp} -> {:ok, %{resp | model: "llama3.2:3b (ollama)"}}
        error -> error
      end
    else
      anthropic_config = Map.put(config, :api_key, api_key)
      Cortex.LLM.Adapters.Anthropic.call(system_prompt, input, anthropic_config)
    end
  end
end
