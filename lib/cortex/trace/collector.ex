defmodule Cortex.Trace.Collector do
  @moduledoc """
  Receives and stores traces from all domain agents.
  ETS for hot queries. Ecto persistence coming in a later phase.
  """

  use GenServer
  require Logger

  @table :cortex_traces

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def log(%Cortex.Trace{} = trace) do
    GenServer.cast(__MODULE__, {:log, trace})
  end

  def all do
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 1)) |> Enum.sort_by(& &1.started_at, :desc)
  end

  def by_domain(domain) do
    all() |> Enum.filter(&(&1.domain == domain))
  end

  def count, do: :ets.info(@table, :size)

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("[Cortex.Trace.Collector] Online. Traces: ETS table #{inspect(table)}")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:log, %Cortex.Trace{} = trace}, state) do
    :ets.insert(@table, {trace.id, trace})

    Logger.info(
      "[Trace] #{trace.domain} | #{trace.model} | #{trace.outcome} | #{trace.duration_ms}ms"
    )

    Phoenix.PubSub.broadcast(Cortex.PubSub, "traces", {:new_trace, trace})
    {:noreply, state}
  end
end
