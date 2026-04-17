defmodule Cortex.Demo do
  @moduledoc """
  Quick demo functions for exercising the Cortex from IEx or scripts.
  """

  def boot_echo do
    Cortex.Domain.Supervisor.start_agent(Cortex.Domains.Echo,
      adapter: Cortex.LLM.Adapters.Ollama,
      adapter_config: %{model: "tinydolphin"}
    )
  end

  def pulse(message, opts \\ []) do
    topic = Keyword.get(opts, :topic, "echo")
    source = Keyword.get(opts, :source, :human)

    signal = Cortex.Signal.new(source, topic, message)
    Cortex.Router.route(signal)
    signal
  end

  @doc """
  Run a debate: fan out the same question to viewpoint-diverse workers,
  then synthesize. Returns {:ok, plan_id} immediately; watch cortex:events
  for completion, or poll Cortex.Memos.list_by_plan(plan_id).
  """
  def debate(question, opts \\ []) do
    Cortex.Graph.debate(question, opts)
  end

  def traces, do: Cortex.Trace.Collector.all()
  def trace_count, do: Cortex.Trace.Collector.count()
  def router_stats, do: Cortex.Router.stats()

  def status do
    agents = Cortex.Domain.Supervisor.running_agents()

    %{
      agents_running: length(agents),
      traces_logged: trace_count(),
      router: router_stats()
    }
  end

  def full_demo do
    IO.puts("=== Cortex Engine Demo ===\n")

    IO.puts("1. Booting Echo domain agent...")
    {:ok, pid} = boot_echo()
    IO.puts("   Echo agent online: #{inspect(pid)}\n")

    Process.sleep(500)

    IO.puts("2. Sending first signal through the hive...")
    signal = pulse("The Cortex Engine is alive. This is the first micro-transaction.")
    IO.puts("   Signal ID: #{signal.id}")
    IO.puts("   Topic: #{signal.topic}\n")

    IO.puts("3. Waiting for TinyDolphin to think...")
    Process.sleep(30_000)

    IO.puts("\n4. Checking traces...")
    traces = traces()
    IO.puts("   Traces logged: #{length(traces)}\n")

    for trace <- traces do
      IO.puts("   --- Trace #{trace.id} ---")
      IO.puts("   Domain: #{trace.domain}")
      IO.puts("   Model: #{trace.model}")
      IO.puts("   Outcome: #{trace.outcome}")
      IO.puts("   Duration: #{trace.duration_ms}ms")
      IO.puts("   Output: #{String.slice(trace.output || "(none)", 0, 200)}")
      IO.puts("")
    end

    IO.puts("5. Router stats:")
    stats = router_stats()
    IO.puts("   Routed: #{stats.routed}")
    IO.puts("   Topics seen: #{inspect(stats.topics_seen)}")
    IO.puts("\n=== Demo complete ===")
  end
end
