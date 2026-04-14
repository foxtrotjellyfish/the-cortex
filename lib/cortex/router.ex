defmodule Cortex.Router do
  @moduledoc """
  The Router is deliberately unintelligent. It classifies topics via keyword
  matching, ensures domain agents exist (spawning new ones on the fly),
  and addresses envelopes. It does not reason about content.

  When the Router encounters a topic with no existing domain, it spawns one
  through the DynamicSupervisor — the system grows new cognitive domains
  from signal pressure, not planning.
  """

  use GenServer
  require Logger

  alias Cortex.Domains.StoredDomain
  alias Cortex.Repo

  # Topic keywords are instance-specific — configured via
  # Application.get_env(:cortex, :topic_keywords, %{}).
  # See config/instance.exs.example for the format.

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def route(%Cortex.Signal{} = signal) do
    GenServer.cast(__MODULE__, {:route, signal})
  end

  def process_input(text, conversation_id \\ nil) do
    conv_id = conversation_id || gen_id()
    GenServer.cast(__MODULE__, {:human_input, text, conv_id})
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  def get_domains do
    GenServer.call(__MODULE__, :domains)
  end

  @impl true
  def init(_opts) do
    Logger.info("[Cortex.Router] Online. Keyword classification + dynamic spawning.")
    {:ok, %{routed: 0, created: 0, domains: %{}}}
  end

  @impl true
  def handle_cast({:human_input, text, conv_id}, state) do
    topics = classify(text)
    Logger.info("[Router] \"#{String.slice(text, 0, 60)}...\" → #{inspect(topics)}")

    broadcast_event({:router_classifying, %{topics: topics, text: text}})

    state =
      Enum.reduce(topics, state, fn topic, acc ->
        ensure_domain(topic, acc)
      end)

    for topic <- topics do
      signal =
        Cortex.Signal.new(:human, to_string(topic), text,
          metadata: %{conversation_id: conv_id}
        )

      broadcast_event(
        {:signal_routed,
         %{
           signal_id: signal.id,
           from: :human,
           to: topic
         }}
      )

      Phoenix.PubSub.broadcast(Cortex.PubSub, to_string(topic), {:signal, signal})
    end

    {:noreply, %{state | routed: state.routed + length(topics)}}
  end

  def handle_cast({:route, %Cortex.Signal{} = signal}, state) do
    Logger.debug("[Router] Agent signal from :#{signal.source} → '#{signal.topic}'")

    Phoenix.PubSub.broadcast(Cortex.PubSub, signal.topic, {:signal, signal})
    Phoenix.PubSub.broadcast(Cortex.PubSub, "all_signals", {:signal, signal})

    {:noreply, %{state | routed: state.routed + 1}}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       routed: state.routed,
       domains: map_size(state.domains),
       traces: Cortex.Trace.Collector.count()
     }, state}
  end

  def handle_call(:domains, _from, state) do
    {:reply, state.domains, state}
  end

  defp classify(text) do
    words = text |> String.downcase() |> String.split(~r/[\s,.\-!?;:'"()]+/, trim: true)

    matched =
      topic_keywords()
      |> Enum.map(fn {topic, keywords} ->
        score = Enum.count(keywords, fn kw -> kw in words end)
        {topic, score}
      end)
      |> Enum.filter(fn {_topic, score} -> score > 0 end)
      |> Enum.sort_by(fn {_topic, score} -> score end, :desc)
      |> Enum.take(4)
      |> Enum.map(fn {topic, _score} -> topic end)

    case matched do
      [] -> [:general]
      topics -> topics
    end
  end

  defp topic_keywords do
    Application.get_env(:cortex, :topic_keywords, %{})
  end

  defp default_adapter do
    Application.get_env(:cortex, :default_adapter, Cortex.LLM.Adapters.Anthropic)
  end

  defp default_adapter_config do
    Application.get_env(:cortex, :default_adapter_config, %{model: "claude-3-5-haiku-20241022"})
  end

  defp ensure_domain(topic, state) do
    case Registry.lookup(Cortex.Domain.Registry, topic) do
      [{_pid, _}] ->
        state

      [] ->
        adapter = default_adapter()
        adapter_config = default_adapter_config()

        opts = [
          name: topic,
          topics: [to_string(topic)],
          adapter: adapter,
          adapter_config: adapter_config
        ]

        case Cortex.Domain.Supervisor.start_agent(Cortex.Domains.Dynamic, opts) do
          {:ok, pid} ->
            Logger.info("[Router] Spawned new domain: #{topic} (#{inspect(pid)})")

            persist_domain(topic, opts)
            broadcast_event({:domain_spawned, %{name: topic, pid: pid}})

            put_in(state, [:domains, topic], %{
              created_at: DateTime.utc_now(),
              pid: pid
            })

          {:error, reason} ->
            Logger.error("[Router] Failed to spawn #{topic}: #{inspect(reason)}")
            state
        end
    end
  end

  defp persist_domain(topic, opts) do
    adapter = Keyword.get(opts, :adapter)
    adapter_config = Keyword.get(opts, :adapter_config, %{})

    attrs = %{
      name: to_string(topic),
      system_prompt: Keyword.get(opts, :system_prompt),
      topics: Keyword.get(opts, :topics, [to_string(topic)]),
      adapter: StoredDomain.adapter_name(adapter),
      adapter_config: stringify_keys(adapter_config)
    }

    case Repo.get_by(StoredDomain, name: to_string(topic)) do
      nil ->
        case Repo.insert(StoredDomain.changeset(%StoredDomain{}, attrs)) do
          {:ok, _} -> Logger.debug("[Router] Persisted domain: #{topic}")
          {:error, cs} -> Logger.warning("[Router] Failed to persist #{topic}: #{inspect(cs.errors)}")
        end

      _existing ->
        :ok
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp broadcast_event(event) do
    Phoenix.PubSub.broadcast(Cortex.PubSub, "cortex:events", event)
  end

  defp gen_id, do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
end
