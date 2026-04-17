defmodule Cortex.Graph.Worker do
  @moduledoc """
  Ephemeral worker GenServer. Spawned by Cortex.Graph with a single sub-task string.

  Lifecycle:
    1. Spawned by Graph via Domain.Supervisor.start_agent/2
    2. Sends :start_work to self in init (defers LLM call out of init)
    3. Makes one LLM call via the configured adapter
    4. Reports result to Cortex.Graph via worker_done/3
    5. Stops with :normal — DynamicSupervisor does not restart transient exits

  Workers are not registered in Cortex.Domain.Registry — multiple workers can
  run concurrently for the same plan. The Graph tracks them by worker_id.

  N workers run simultaneously, each making an inference call, each completing
  and reporting back — all supervised, all fault-tolerant, all BEAM-native.
  """

  # restart: :transient means the supervisor won't restart a :normal or :shutdown exit
  use GenServer, restart: :transient
  require Logger

  def start_link(opts) do
    # Intentionally not registered — multiple workers live concurrently
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    plan_id = Keyword.fetch!(opts, :plan_id)
    worker_id = Keyword.fetch!(opts, :worker_id)
    subtask = Keyword.fetch!(opts, :subtask)
    graph_pid = Keyword.fetch!(opts, :graph_pid)
    adapter = Keyword.get(opts, :adapter, Cortex.LLM.Adapters.Ollama)
    adapter_config = Keyword.get(opts, :adapter_config, %{model: "tinydolphin"})
    viewpoint = Keyword.get(opts, :viewpoint)

    Logger.debug("[Worker:#{worker_id}] Online → #{String.slice(subtask, 0, 60)}")

    state = %{
      plan_id: plan_id,
      worker_id: worker_id,
      subtask: subtask,
      graph_pid: graph_pid,
      adapter: adapter,
      adapter_config: adapter_config,
      viewpoint: viewpoint
    }

    # Defer work out of init so the supervisor gets a clean start acknowledgment
    send(self(), :start_work)

    {:ok, state}
  end

  @impl true
  def handle_info(:start_work, state) do
    system_prompt = build_system_prompt(state.viewpoint)

    trace =
      Cortex.Trace.start(
        :worker,
        system_prompt,
        state.subtask,
        state.adapter,
        Map.get(state.adapter_config, :model, "unknown")
      )

    output =
      case state.adapter.call(system_prompt, state.subtask, state.adapter_config) do
        {:ok, %{output: out} = resp} ->
          completed =
            Cortex.Trace.complete(trace, out,
              tokens_in: resp[:tokens_in],
              tokens_out: resp[:tokens_out]
            )

          Cortex.Trace.Collector.log(completed)

          case Cortex.Memos.append(state.plan_id, state.worker_id, state.subtask, out) do
            {:ok, _} ->
              Logger.debug("[Worker:#{state.worker_id}] Memo appended")

            {:error, cs} ->
              Logger.error("[Worker:#{state.worker_id}] Memo insert failed: #{inspect(cs.errors)}")
          end

          Logger.debug(
            "[Worker:#{state.worker_id}] Done (#{completed.duration_ms}ms): #{String.slice(out, 0, 80)}"
          )

          out

        {:error, reason} ->
          failed = Cortex.Trace.fail(trace, inspect(reason))
          Cortex.Trace.Collector.log(failed)
          Logger.error("[Worker:#{state.worker_id}] LLM error: #{inspect(reason)}")
          "(error: #{inspect(reason)})"
      end

    Cortex.Graph.worker_done(state.plan_id, state.worker_id, output)

    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp build_system_prompt(nil) do
    """
    You are a focused research worker. Complete the following task in 1-2 sentences.
    Be specific. No preamble, no conclusions, no hedging. Just the answer.
    """
  end

  defp build_system_prompt(viewpoint) do
    """
    You are one voice in a panel of experts. Your role: #{viewpoint}
    Respond in 1-2 sentences. Be specific. No preamble.
    """
  end
end
