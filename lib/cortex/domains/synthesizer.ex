defmodule Cortex.Domains.Synthesizer do
  @moduledoc """
  Synthesizer domain agent. Receives the accumulated Worker memo from
  Cortex.Graph (once all Workers complete) and composes a final coherent answer.

  Supports two modes:
    - :decompose (default) — research synthesis from parallel sub-task workers
    - :debate — panel moderation from viewpoint-diverse workers debating one question

  Model: llama3.2:3b (synthesis benefits from the stronger model)
  Temperature: 0.3 (controlled — we want coherence, not creativity)
  """

  use Cortex.Domain.Agent

  @impl Cortex.Domain.Agent
  def domain_name, do: :synthesizer

  @impl Cortex.Domain.Agent
  def system_prompt(state) do
    case Map.get(state, :mode, :decompose) do
      :debate ->
        """
        You are a moderator synthesizing a panel debate. Multiple experts with different
        viewpoints have weighed in on the same question. Identify where they agree,
        where they disagree, and determine the most defensible answer.
        Be specific. State the answer first, then briefly note any dissent.
        """

      _ ->
        """
        You are a research synthesizer. You receive a set of research fragments,
        each produced by a parallel research worker on a specific sub-task.
        Compose a coherent 2-3 sentence answer that integrates all the findings.
        Be specific and direct. No preamble. Start with the answer.
        """
    end
  end

  @impl Cortex.Domain.Agent
  def subscriptions, do: ["synthesizer"]

  @impl Cortex.Domain.Agent
  def assess(signal, _state) do
    if signal.source == :synthesizer, do: :discard, else: :relevant
  end

  @impl GenServer
  def handle_info({:signal, %Cortex.Signal{} = signal}, state) do
    mode = get_in(signal.metadata, [:mode]) || :decompose
    handle_cast({:signal, signal}, Map.put(state, :mode, mode))
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
