defmodule Cortex.Router do
  @moduledoc """
  The Router is deliberately unintelligent. It matches patterns, checks a routing
  table, and addresses envelopes. It does not reason about content.

  V1: Programmatic only. Pattern match + routing table. No LLM calls.
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def route(%Cortex.Signal{} = signal) do
    GenServer.cast(__MODULE__, {:route, signal})
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Cortex.Router] Online. Programmatic routing (V1).")
    {:ok, %{routed: 0, discarded: 0, topics_seen: MapSet.new()}}
  end

  @impl true
  def handle_cast({:route, %Cortex.Signal{} = signal}, state) do
    Logger.debug("[Router] Routing signal from :#{signal.source} to topic '#{signal.topic}'")

    Phoenix.PubSub.broadcast(Cortex.PubSub, signal.topic, {:signal, signal})
    Phoenix.PubSub.broadcast(Cortex.PubSub, "all_signals", {:signal, signal})

    new_state = %{
      state
      | routed: state.routed + 1,
        topics_seen: MapSet.put(state.topics_seen, signal.topic)
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       routed: state.routed,
       discarded: state.discarded,
       topics_seen: MapSet.to_list(state.topics_seen)
     }, state}
  end
end
