defmodule Cortex.Domains.Dynamic do
  @moduledoc """
  A runtime-configurable domain agent. Unlike static domain modules (Echo),
  Dynamic agents receive their name, system prompt, and subscriptions at
  start time. The system grows new cognitive domains from signal pressure —
  no restarts, no deploys, no PRs.
  """

  use GenServer
  require Logger

  alias Cortex.Domains.StoredDomain
  alias Cortex.Repo

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(name))
  end

  def via_tuple(name) do
    {:via, Registry, {Cortex.Domain.Registry, name}}
  end

  def get_state(name) do
    GenServer.call(via_tuple(name), :get_state)
  catch
    :exit, _ -> nil
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    topics = Keyword.get(opts, :topics, [to_string(name)])
    adapter = Keyword.get(opts, :adapter, Cortex.LLM.Adapters.Anthropic)
    adapter_config = Keyword.get(opts, :adapter_config, %{model: "claude-3-5-haiku-20241022"})

    for topic <- topics do
      Phoenix.PubSub.subscribe(Cortex.PubSub, topic)
    end

    state = %{
      domain: name,
      system_prompt: Keyword.get(opts, :system_prompt, generate_prompt(name)),
      topics: topics,
      adapter: adapter,
      adapter_config: adapter_config,
      message_count: Keyword.get(opts, :message_count, 0),
      persisted_id: Keyword.get(opts, :persisted_id),
      created_at: DateTime.utc_now()
    }

    Logger.info("[Domain:#{name}] Online (dynamic). Topics: #{inspect(topics)}. Adapter: #{inspect(adapter)}")

    broadcast_event({:domain_ready, %{name: name, pid: self()}})
    {:ok, state}
  end

  @impl true
  def handle_info({:signal, %Cortex.Signal{} = signal}, state) do
    if signal.source == state.domain do
      {:noreply, state}
    else
      broadcast_event({:domain_processing, %{domain: state.domain, signal_id: signal.id}})

      domain_state = state
      Task.start(fn -> process_signal(signal, domain_state) end)

      new_count = state.message_count + 1
      persist_message_count(state.domain, new_count)
      {:noreply, %{state | message_count: new_count}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Map.take(state, [:domain, :message_count, :created_at, :topics]), state}
  end

  defp process_signal(signal, state) do
    trace =
      Cortex.Trace.start(
        state.domain,
        state.system_prompt,
        signal.content,
        state.adapter,
        Map.get(state.adapter_config, :model, "unknown")
      )

    case state.adapter.call(state.system_prompt, signal.content, state.adapter_config) do
      {:ok, %{output: output} = resp} ->
        completed =
          Cortex.Trace.complete(trace, output,
            tokens_in: resp[:tokens_in],
            tokens_out: resp[:tokens_out]
          )

        Cortex.Trace.Collector.log(completed)

        broadcast_event(
          {:domain_completed,
           %{
             domain: state.domain,
             output: output,
             duration_ms: completed.duration_ms,
             conversation_id: get_in(signal.metadata, [:conversation_id])
           }}
        )

      {:error, reason} ->
        failed = Cortex.Trace.fail(trace, inspect(reason))
        Cortex.Trace.Collector.log(failed)

        broadcast_event({:domain_error, %{domain: state.domain, error: inspect(reason)}})
    end
  end

  defp generate_prompt(name) do
    domain_str = name |> to_string() |> String.replace("_", " ") |> String.capitalize()

    """
    You are the #{domain_str} domain agent in the Cortex Engine.
    You specialize in #{String.downcase(domain_str)}-related topics.
    When you receive a message, respond with a brief, focused insight from your domain perspective.
    Keep responses to 2-3 sentences. Be direct, specific, and useful.
    Don't repeat the question. Don't hedge. State what you know.
    """
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(Cortex.PubSub, "cortex:events", event)
  end

  defp persist_message_count(domain_name, count) do
    Task.start(fn ->
      case Repo.get_by(StoredDomain, name: to_string(domain_name)) do
        nil -> :ok
        record -> Repo.update(StoredDomain.changeset(record, %{message_count: count}))
      end
    end)
  end
end
