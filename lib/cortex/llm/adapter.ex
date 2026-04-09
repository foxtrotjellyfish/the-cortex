defmodule Cortex.LLM.Adapter do
  @moduledoc """
  The LLM adapter behaviour. One prompt in, one response out, full trace metadata.
  """

  @type response :: %{
          output: String.t(),
          model: String.t(),
          tokens_in: non_neg_integer() | nil,
          tokens_out: non_neg_integer() | nil
        }

  @callback call(system_prompt :: String.t(), input :: String.t(), config :: map()) ::
              {:ok, response()} | {:error, term()}
end
