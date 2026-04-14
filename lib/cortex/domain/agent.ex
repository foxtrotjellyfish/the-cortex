defmodule Cortex.Domain.Agent do
  @moduledoc """
  The core abstraction. A domain agent is a GenServer with a system prompt,
  PubSub subscriptions, and an LLM adapter. Each micro-transaction is one
  message in, one LLM call, one output, done.
  """

  @callback domain_name() :: atom()
  @callback system_prompt(state :: map()) :: String.t()
  @callback subscriptions() :: [String.t()]
  @callback assess(signal :: Cortex.Signal.t(), state :: map()) :: :relevant | :discard

  @doc """
  The PubSub topic the agent's output signal is routed to.
  Defaults to `to_string(domain_name())`. Override in agents that route to a
  different consumer (e.g. Planner routes to "graph" rather than "planner").
  """
  @callback output_topic() :: String.t()
  @optional_callbacks output_topic: 0

  defmacro __using__(opts) do
    quote location: :keep do
      use GenServer
      @behaviour Cortex.Domain.Agent
      require Logger

      def start_link(config) do
        GenServer.start_link(__MODULE__, config, name: via_tuple())
      end

      def via_tuple do
        {:via, Registry, {Cortex.Domain.Registry, domain_name()}}
      end

      def send_signal(%Cortex.Signal{} = signal) do
        GenServer.cast(via_tuple(), {:signal, signal})
      end

      @impl GenServer
      def init(config) do
        adapter = Keyword.get(config, :adapter, Cortex.LLM.Adapters.Ollama)
        adapter_config = Keyword.get(config, :adapter_config, %{model: "tinydolphin"})
        workspace_path = Keyword.get(config, :workspace_path)
        extra = Keyword.get(config, :extra, %{})

        state = %{
          domain: domain_name(),
          adapter: adapter,
          adapter_config: adapter_config,
          workspace_path: workspace_path,
          message_count: 0,
          extra: extra
        }

        for topic <- subscriptions() do
          Phoenix.PubSub.subscribe(Cortex.PubSub, topic)
        end

        Logger.info("[Domain:#{domain_name()}] Online. Subscribed to: #{inspect(subscriptions())}")
        {:ok, state}
      end

      @impl GenServer
      def handle_cast({:signal, %Cortex.Signal{} = signal}, state) do
        case assess(signal, state) do
          :relevant -> process_signal(signal, state)
          :discard -> :ok
        end

        {:noreply, %{state | message_count: state.message_count + 1}}
      end

      @impl GenServer
      def handle_info({:signal, %Cortex.Signal{} = signal}, state) do
        handle_cast({:signal, signal}, state)
      end

      def handle_info(_msg, state), do: {:noreply, state}

      defp process_signal(signal, state) do
        sys_prompt = system_prompt(state)

        trace =
          Cortex.Trace.start(
            state.domain,
            sys_prompt,
            signal.content,
            state.adapter,
            adapter_model(state)
          )

        case state.adapter.call(sys_prompt, signal.content, state.adapter_config) do
          {:ok, %{output: output} = resp} ->
            completed =
              Cortex.Trace.complete(trace, output,
                tokens_in: resp[:tokens_in],
                tokens_out: resp[:tokens_out]
              )

            Cortex.Trace.Collector.log(completed)

            output_signal =
              Cortex.Signal.new(state.domain, output_topic(), output,
                metadata: %{parent_trace_id: trace.id}
              )

            Cortex.Router.route(output_signal)

          {:error, reason} ->
            failed = Cortex.Trace.fail(trace, inspect(reason))
            Cortex.Trace.Collector.log(failed)
        end
      end

      defp adapter_model(state) do
        Map.get(state.adapter_config, :model, "unknown")
      end

      defoverridable init: 1

      def output_topic, do: to_string(domain_name())
      defoverridable output_topic: 0

      unquote(Keyword.get(opts, :extra_code, nil))
    end
  end
end
