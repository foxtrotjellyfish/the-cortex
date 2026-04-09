defmodule Cortex.Domains.Echo do
  @moduledoc """
  The first domain agent. Receives any signal, processes it through an LLM,
  and emits the result. Proves the full micro-transaction loop:

    Signal in → PubSub → GenServer receives → LLM call → trace logged → signal out
  """

  use Cortex.Domain.Agent

  @impl Cortex.Domain.Agent
  def domain_name, do: :echo

  @impl Cortex.Domain.Agent
  def system_prompt(_state) do
    """
    You are Echo, the first domain agent in the Cortex Engine.
    You receive signals and respond with a brief, thoughtful acknowledgment.
    Keep responses under 3 sentences. Be direct.
    If the input seems like noise or test data, say so honestly.
    Your job is to prove the loop works, not to be brilliant.
    """
  end

  @impl Cortex.Domain.Agent
  def subscriptions, do: ["echo", "system", "human"]

  @impl Cortex.Domain.Agent
  def assess(signal, _state) do
    if signal.source == :echo, do: :discard, else: :relevant
  end
end
