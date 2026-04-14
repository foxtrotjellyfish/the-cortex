defmodule Cortex.Graph do
  @moduledoc """
  Fan-out / fan-in coordinator for the cognition tree.

  Receives a Planner's natural-language sub-task list on the "graph" topic,
  spawns one Worker per sub-task under the DynamicSupervisor, tracks completion
  in GenServer state, and fires a :synthesizer signal when all workers report done.

    Planner signal → Graph.parse/1 → N × Worker GenServers (DynamicSupervisor)
       ↓ each worker calls worker_done/3 when its LLM call completes
    Graph sees all done → accumulates memo → broadcasts to "synthesizer" topic

  No framework required. DynamicSupervisor + named GenServer + PubSub = the tree.

  Protocol #9 compliance: every signal emitted by the Graph carries
  plan_id, classification, and timestamp in its metadata envelope.
  """

  use GenServer
  require Logger

  @graph_topic "graph"
  @synthesizer_topic "synthesizer"
  @events_topic "cortex:events"

  # ---- Public API -----------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Simulate a Planner signal from iex for testing: Cortex.Graph.execute_plan(plan_text)"
  def execute_plan(plan_text) when is_binary(plan_text) do
    signal = Cortex.Signal.new(:manual, @graph_topic, plan_text)
    Phoenix.PubSub.broadcast(Cortex.PubSub, @graph_topic, {:signal, signal})
    {:ok, signal.id}
  end

  @doc "Called by Graph.Worker on completion. Direct cast — no PubSub hop."
  def worker_done(plan_id, worker_id, output) do
    GenServer.cast(__MODULE__, {:worker_done, plan_id, worker_id, output})
  end

  @doc "Inspect active plans and their worker completion counts."
  def active_plans do
    GenServer.call(__MODULE__, :active_plans)
  end

  # ---- GenServer ------------------------------------------------------------

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Cortex.PubSub, @graph_topic)
    Logger.info("[Cortex.Graph] Online. Subscribed to '#{@graph_topic}'.")
    {:ok, %{plans: %{}}}
  end

  # Receive Planner output signal → parse → fan out
  @impl true
  def handle_info({:signal, %Cortex.Signal{} = signal}, state) do
    subtasks = parse_plan(signal.content)

    if Enum.empty?(subtasks) do
      Logger.warning("[Graph] Received plan with no parseable steps (signal #{signal.id})")
      {:noreply, state}
    else
      plan_id = signal.id
      Logger.info("[Graph] Plan #{plan_id}: #{length(subtasks)} sub-tasks → fanning out")
      broadcast({:plan_started, %{plan_id: plan_id, subtask_count: length(subtasks), source: signal.source}})

      adapter = Application.get_env(:cortex, :worker_adapter, Cortex.LLM.Adapters.Ollama)
      adapter_config = Application.get_env(:cortex, :worker_adapter_config, %{model: "tinydolphin"})

      # Spawn one Worker per sub-task; build tracking state in a single pass
      workers =
        subtasks
        |> Enum.with_index()
        |> Enum.reduce(%{}, fn {subtask, idx}, acc ->
          worker_id = "#{plan_id}_w#{idx}"

          opts = [
            plan_id: plan_id,
            worker_id: worker_id,
            subtask: subtask,
            graph_pid: self(),
            adapter: adapter,
            adapter_config: adapter_config
          ]

          case Cortex.Domain.Supervisor.start_agent(Cortex.Graph.Worker, opts) do
            {:ok, pid} ->
              Logger.debug("[Graph] Spawned #{worker_id} (pid=#{inspect(pid)}) → #{String.slice(subtask, 0, 60)}")
              broadcast({:worker_spawned, %{plan_id: plan_id, worker_id: worker_id, subtask: subtask}})
              Map.put(acc, worker_id, %{status: :pending, output: nil, subtask: subtask})

            {:error, reason} ->
              Logger.error("[Graph] Failed to spawn worker for '#{subtask}': #{inspect(reason)}")
              acc
          end
        end)

      if map_size(workers) == 0 do
        Logger.error("[Graph] Plan #{plan_id}: all workers failed to spawn")
        {:noreply, state}
      else
        plan_state = %{
          plan_id: plan_id,
          subtasks: subtasks,
          workers: workers,
          plan_signal: signal,
          started_at: DateTime.utc_now()
        }

        {:noreply, put_in(state, [:plans, plan_id], plan_state)}
      end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Worker completion callback
  @impl true
  def handle_cast({:worker_done, plan_id, worker_id, output}, state) do
    case get_in(state, [:plans, plan_id]) do
      nil ->
        Logger.warning("[Graph] worker_done for unknown plan #{plan_id} (already complete?)")
        {:noreply, state}

      _plan ->
        state =
          update_in(state, [:plans, plan_id, :workers, worker_id], fn worker ->
            %{worker | status: :done, output: output}
          end)

        plan = get_in(state, [:plans, plan_id])
        workers = plan.workers
        done_count = workers |> Map.values() |> Enum.count(&(&1.status == :done))
        total = map_size(workers)

        Logger.info("[Graph] Plan #{plan_id}: #{done_count}/#{total} workers done")
        broadcast({:worker_done, %{plan_id: plan_id, worker_id: worker_id, done: done_count, total: total}})

        if done_count == total do
          trigger_synthesizer(plan_id, plan)
          {:noreply, update_in(state, [:plans], &Map.delete(&1, plan_id))}
        else
          {:noreply, state}
        end
    end
  end

  @impl true
  def handle_call(:active_plans, _from, state) do
    summary =
      Map.new(state.plans, fn {id, plan} ->
        done = plan.workers |> Map.values() |> Enum.count(&(&1.status == :done))
        total = map_size(plan.workers)

        {id,
         %{
           total: total,
           done: done,
           pending: total - done,
           elapsed_ms: DateTime.diff(DateTime.utc_now(), plan.started_at, :millisecond)
         }}
      end)

    {:reply, summary, state}
  end

  # ---- Private --------------------------------------------------------------

  # Parse a numbered/bulleted plain-text plan into a list of sub-task strings.
  # Handles: "1. step", "1) step", "- step", "* step"
  # Filters out non-list lines (intro sentences, blank lines, etc.)
  defp parse_plan(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.filter(&looks_like_step?/1)
    |> Enum.map(&strip_prefix/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp looks_like_step?(line) do
    String.match?(String.trim(line), ~r/^(\d+[\.\)]+|[-*])\s/)
  end

  defp strip_prefix(line) do
    Regex.replace(~r/^\s*(\d+[\.\)]+\s+|[-*]\s+)/, String.trim(line), "")
  end

  defp trigger_synthesizer(plan_id, plan) do
    # Read from the persistent Memo store — the SQLite record is the source
    # of truth for the Synthesizer, not the in-memory worker state.
    memo =
      plan_id
      |> Cortex.Memos.list_by_plan()
      |> Cortex.Memos.to_synthesis_input()

    signal =
      Cortex.Signal.new(
        :graph,
        @synthesizer_topic,
        memo,
        metadata: %{
          # Protocol #9 envelope fields
          plan_id: plan_id,
          classification: :synthesis_request,
          worker_count: map_size(plan.workers),
          source_signal_id: plan.plan_signal.id,
          timestamp: DateTime.utc_now()
        }
      )

    Cortex.Router.route(signal)

    elapsed_ms = DateTime.diff(DateTime.utc_now(), plan.started_at, :millisecond)

    broadcast({:plan_complete, %{plan_id: plan_id, elapsed_ms: elapsed_ms, worker_count: map_size(plan.workers)}})
    Logger.info("[Graph] Plan #{plan_id} complete in #{elapsed_ms}ms → synthesizer triggered")
  end

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(Cortex.PubSub, @events_topic, event)
  end
end
