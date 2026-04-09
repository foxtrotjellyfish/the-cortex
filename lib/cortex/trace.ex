defmodule Cortex.Trace do
  @moduledoc """
  The micro-transaction record. Every LLM call is logged from the first commit.
  """

  @type outcome :: :completed | :needs_followup | :discarded | :escalated | :error

  @type t :: %__MODULE__{
          id: String.t(),
          domain: atom(),
          system_prompt: String.t(),
          input: String.t(),
          adapter: atom(),
          model: String.t(),
          output: String.t() | nil,
          outcome: outcome(),
          signals_out: [Cortex.Signal.t()],
          duration_ms: non_neg_integer() | nil,
          tokens_in: non_neg_integer() | nil,
          tokens_out: non_neg_integer() | nil,
          error: String.t() | nil,
          started_at: DateTime.t(),
          completed_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :domain, :system_prompt, :input, :adapter, :model, :started_at]
  defstruct [
    :id,
    :domain,
    :system_prompt,
    :input,
    :adapter,
    :model,
    :output,
    :error,
    :duration_ms,
    :tokens_in,
    :tokens_out,
    :completed_at,
    outcome: :completed,
    signals_out: [],
    started_at: nil
  ]

  def start(domain, system_prompt, input, adapter, model) do
    %__MODULE__{
      id: gen_id(),
      domain: domain,
      system_prompt: system_prompt,
      input: input,
      adapter: adapter,
      model: model,
      started_at: DateTime.utc_now()
    }
  end

  def complete(trace, output, opts \\ []) do
    now = DateTime.utc_now()

    %{
      trace
      | output: output,
        outcome: Keyword.get(opts, :outcome, :completed),
        signals_out: Keyword.get(opts, :signals_out, []),
        tokens_in: Keyword.get(opts, :tokens_in),
        tokens_out: Keyword.get(opts, :tokens_out),
        completed_at: now,
        duration_ms: DateTime.diff(now, trace.started_at, :millisecond)
    }
  end

  def fail(trace, error) do
    now = DateTime.utc_now()

    %{
      trace
      | error: error,
        outcome: :error,
        completed_at: now,
        duration_ms: DateTime.diff(now, trace.started_at, :millisecond)
    }
  end

  defp gen_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
