defmodule Cortex.Domains.Planner do
  @moduledoc """
  Planner domain agent. Receives a research goal, decomposes it into 3-5
  numbered plain-English research steps, and routes the plan to Cortex.Graph
  for fan-out execution.

  Model: llama3.2:3b (stronger reasoning, more reliable NL decomposition)
  Temperature: 0.3 (analytical task — lower temperature, fewer hallucinations)

  Natural language decomposition (numbered steps) is dramatically more reliable
  than JSON for sub-3B models. The Planner outputs human-readable steps;
  Cortex.Graph.parse_plan/1 extracts them into a sub-task list for fan-out.
  The OTP supervision tree is the tool-caller; the model just says what to do.
  """

  use Cortex.Domain.Agent

  @impl Cortex.Domain.Agent
  def domain_name, do: :planner

  @impl Cortex.Domain.Agent
  def system_prompt(_state) do
    """
    You are a research planner. Break the given goal into exactly 3-5 concrete research steps.
    Format: number each step. One step per line. Plain English only.
    No explanation, no intro sentence, no conclusion. Just the numbered steps.
    Each step must start with a number and a period or parenthesis: "1. " or "1) ".
    """
  end

  @impl Cortex.Domain.Agent
  def subscriptions, do: ["planner"]

  @impl Cortex.Domain.Agent
  def assess(signal, _state) do
    if signal.source == :planner, do: :discard, else: :relevant
  end

  @impl Cortex.Domain.Agent
  def output_topic, do: "graph"
end
