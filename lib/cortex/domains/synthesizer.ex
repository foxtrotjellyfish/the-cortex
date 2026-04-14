defmodule Cortex.Domains.Synthesizer do
  @moduledoc """
  Synthesizer domain agent. Receives the accumulated Worker memo from
  Cortex.Graph (once all Workers complete) and composes a final coherent answer.

  This is the terminal node of the cognition tree. Its output routes to
  "synthesizer" — nothing downstream subscribes, but the trace is logged
  and visible in the Hive LiveView.

  Model: llama3.2:3b (synthesis benefits from the stronger model)
  Temperature: 0.3 (controlled — we want coherence, not creativity)

  The Synthesizer demonstrates Progressive Disclosure from the Substrate
  protocols: it reads only the current plan's memo, not all accumulated
  knowledge, composing from exactly what the Workers provided.
  """

  use Cortex.Domain.Agent

  @impl Cortex.Domain.Agent
  def domain_name, do: :synthesizer

  @impl Cortex.Domain.Agent
  def system_prompt(_state) do
    """
    You are a research synthesizer. You receive a set of research fragments,
    each produced by a parallel research worker on a specific sub-task.
    Compose a coherent 2-3 sentence answer that integrates all the findings.
    Be specific and direct. No preamble. Start with the answer.
    """
  end

  @impl Cortex.Domain.Agent
  def subscriptions, do: ["synthesizer"]

  @impl Cortex.Domain.Agent
  def assess(signal, _state) do
    if signal.source == :synthesizer, do: :discard, else: :relevant
  end
end
