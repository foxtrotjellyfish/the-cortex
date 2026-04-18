defmodule Cortex.Benchmark do
  @moduledoc """
  Solo vs. collective comparison harness.

  Runs a question through individual models (solo baseline) and through the
  viewpoint-diverse debate pipeline (collective), returning structured results
  for analysis and markdown export.

  Usage from IEx:

      result = Cortex.Benchmark.run("A farmer has 15 sheep. All but 8 die. How many sheep does the farmer have left?")
      IO.puts(Cortex.Benchmark.format_markdown(result))

  """

  require Logger

  @events_topic "cortex:events"
  @traces_topic "traces"

  @default_solo_prompt """
  Answer the following question directly in 1-2 sentences. Be specific. No preamble.
  """

  @default_timeout 120_000

  # -- Public API -------------------------------------------------------------

  @doc """
  Run a full benchmark: solo baselines for each model, then collective debate.

  Options:
    - `:solo_models`  — list of model names (default: tinydolphin, llama3.2:3b)
    - `:workers`      — number of debate workers (default: 5)
    - `:viewpoints`   — list of `{label, prompt}` tuples for custom viewpoints.
      Omit to use Graph's built-in 5-role panel.
    - `:adapter`      — LLM adapter module (default: Ollama)
    - `:adapter_config` — base adapter config map
    - `:timeout`      — max wait for collective in ms (default: 120_000)
    - `:solo_prompt`  — system prompt for solo runs
    - `:solo_only`    — if true, skip collective debate (solo baseline sweep only)
    - `:synthesizer_config` — map merged into synthesizer adapter_config for this run
      (e.g. `%{model: "phi3:mini"}` to swap the synthesizer model)
  """
  def run(question, opts \\ []) do
    models = Keyword.get(opts, :solo_models, default_solo_models())
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    solo_only = Keyword.get(opts, :solo_only, false)

    Logger.info("[Benchmark] Starting: #{String.slice(question, 0, 60)}")
    started_at = DateTime.utc_now()

    solo_results = run_solo(question, models, opts)

    collective_result =
      if solo_only do
        skipped_collective()
      else
        run_collective(question, timeout, opts)
      end

    viewpoint_labels =
      case Keyword.get(opts, :viewpoints) do
        nil -> :default
        vps -> Enum.map(vps, &elem(&1, 0))
      end

    %{
      question: question,
      started_at: started_at,
      completed_at: DateTime.utc_now(),
      solo: solo_results,
      collective: collective_result,
      config: %{
        solo_models: models,
        solo_only: solo_only,
        worker_count: Keyword.get(opts, :workers, 5),
        viewpoints: viewpoint_labels,
        synthesizer_config: Keyword.get(opts, :synthesizer_config),
        adapter: Keyword.get(opts, :adapter, Cortex.LLM.Adapters.Ollama) |> to_string(),
        timeout: timeout
      }
    }
  end

  @doc """
  Run solo baselines only. One LLM call per model, sequential.
  Returns a list of result maps.
  """
  def run_solo(question, models \\ nil, opts \\ []) do
    models = models || default_solo_models()
    adapter = Keyword.get(opts, :adapter, Cortex.LLM.Adapters.Ollama)
    system_prompt = Keyword.get(opts, :solo_prompt, @default_solo_prompt)

    Enum.map(models, fn model ->
      Logger.info("[Benchmark] Solo: #{model}")
      config = %{model: model}
      t0 = System.monotonic_time(:millisecond)

      result = adapter.call(system_prompt, question, config)

      latency_ms = System.monotonic_time(:millisecond) - t0

      case result do
        {:ok, %{output: output} = resp} ->
          Logger.info("[Benchmark] Solo #{model} done in #{latency_ms}ms")

          %{
            model: model,
            answer: String.trim(output),
            tokens_in: resp[:tokens_in],
            tokens_out: resp[:tokens_out],
            latency_ms: latency_ms,
            status: :ok
          }

        {:error, reason} ->
          Logger.error("[Benchmark] Solo #{model} failed: #{inspect(reason)}")

          %{
            model: model,
            answer: nil,
            error: inspect(reason),
            latency_ms: latency_ms,
            status: :error
          }
      end
    end)
  end

  @doc """
  Run the collective debate and wait for synthesizer output.
  Returns a result map with worker outputs, synthesizer answer, and timing.
  """
  def run_collective(question, timeout \\ @default_timeout, opts \\ []) do
    Phoenix.PubSub.subscribe(Cortex.PubSub, @events_topic)
    Phoenix.PubSub.subscribe(Cortex.PubSub, @traces_topic)

    debate_opts = Keyword.take(opts, [:workers, :adapter, :adapter_config, :viewpoints, :synthesizer_config])
    t0 = System.monotonic_time(:millisecond)

    Logger.info("[Benchmark] Collective: starting debate")

    case Cortex.Graph.debate(question, debate_opts) do
      {:ok, plan_id} ->
        result = await_collective(plan_id, t0, timeout)

        Phoenix.PubSub.unsubscribe(Cortex.PubSub, @events_topic)
        Phoenix.PubSub.unsubscribe(Cortex.PubSub, @traces_topic)

        worker_memos = Cortex.Memos.list_by_plan(plan_id)

        Map.merge(result, %{
          plan_id: plan_id,
          worker_outputs:
            Enum.map(worker_memos, fn memo ->
              %{worker_id: memo.worker_id, content: String.trim(memo.content)}
            end)
        })

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Cortex.PubSub, @events_topic)
        Phoenix.PubSub.unsubscribe(Cortex.PubSub, @traces_topic)

        %{
          status: :error,
          error: inspect(reason),
          plan_id: nil,
          worker_outputs: [],
          total_latency_ms: System.monotonic_time(:millisecond) - t0
        }
    end
  end

  @doc """
  Format a benchmark result as markdown matching the benchmark-matrix.md run template.
  """
  def format_markdown(result) do
    timestamp = format_timestamp(result[:started_at] || result[:completed_at])
    collective = result.collective

    solo_section =
      result.solo
      |> Enum.map_join("\n", fn s ->
        status = if s.status == :ok, do: s.answer, else: "(error: #{s[:error]})"

        """
        - **#{s.model}:** #{status}
          - Tokens: #{s[:tokens_in] || "?"}/#{s[:tokens_out] || "?"}
          - Latency: #{s.latency_ms}ms\
        """
      end)

    worker_section =
      (collective[:worker_outputs] || [])
      |> Enum.map_join("\n", fn w ->
        "  - #{w.worker_id}: #{String.slice(w.content, 0, 120)}"
      end)

    synth_answer = collective[:synthesizer_answer] || "(none)"
    synth_model = collective[:synthesizer_model] || "?"
    total_ms = collective[:total_latency_ms] || "?"
    worker_count = collective[:worker_count] || "?"

    viewpoint_desc =
      case result.config[:viewpoints] do
        :default -> "default (5-role panel)"
        nil -> "default (5-role panel)"
        labels -> "custom: #{Enum.join(labels, ", ")}"
      end

    """
    ### #{timestamp}

    **Question:** #{result.question}

    **Config:**
    - Worker count: #{worker_count} × viewpoint-diverse
    - Viewpoints: #{viewpoint_desc}
    - Synthesizer: #{synth_model}
    - Adapter: #{result.config.adapter}

    **Solo results:**
    #{solo_section}

    **Collective result:**
    - Synthesizer answer: #{synth_answer}
    - Synthesizer tokens: #{collective[:synthesizer_tokens_in] || "?"}/#{collective[:synthesizer_tokens_out] || "?"}
    - Synthesizer latency: #{collective[:synthesizer_latency_ms] || "?"}ms
    - Total wall time: #{total_ms}ms
    - Worker outputs:
    #{worker_section}

    **Delta:** (manual assessment)
    **Notes:**
    """
  end

  @doc """
  Export a benchmark result as a JSON-serializable map.
  Writes to priv/benchmark_traces/ if a path is provided.
  """
  def export_trace(result, opts \\ []) do
    json_safe =
      result
      |> sanitize_for_json()
      |> Jason.encode!(pretty: true)

    case Keyword.get(opts, :path) do
      nil ->
        json_safe

      path ->
        dir = Path.dirname(path)
        File.mkdir_p!(dir)
        File.write!(path, json_safe)
        Logger.info("[Benchmark] Trace exported to #{path}")
        :ok
    end
  end

  # -- Private ----------------------------------------------------------------

  defp await_collective(plan_id, t0, timeout) do
    receive do
      {:plan_complete, %{plan_id: ^plan_id} = meta} ->
        workers_ms = System.monotonic_time(:millisecond) - t0
        Logger.info("[Benchmark] Workers done in #{workers_ms}ms, awaiting synthesizer...")

        remaining = max(timeout - workers_ms, 5_000)
        await_synthesizer(t0, remaining, meta)
    after
      timeout ->
        Logger.warning("[Benchmark] Workers timed out after #{timeout}ms")

        %{
          status: :timeout,
          error: "Workers did not complete within #{timeout}ms",
          total_latency_ms: System.monotonic_time(:millisecond) - t0,
          worker_count: 0
        }
    end
  end

  defp await_synthesizer(t0, timeout, plan_meta) do
    receive do
      {:new_trace, %Cortex.Trace{domain: :synthesizer} = trace} ->
        total_ms = System.monotonic_time(:millisecond) - t0
        Logger.info("[Benchmark] Synthesizer done. Total: #{total_ms}ms")

        %{
          status: :ok,
          synthesizer_answer: String.trim(trace.output || ""),
          synthesizer_model: trace.model,
          synthesizer_tokens_in: trace.tokens_in,
          synthesizer_tokens_out: trace.tokens_out,
          synthesizer_latency_ms: trace.duration_ms,
          total_latency_ms: total_ms,
          worker_count: plan_meta[:worker_count]
        }
    after
      timeout ->
        Logger.warning("[Benchmark] Synthesizer timed out")

        %{
          status: :synthesizer_timeout,
          error: "Synthesizer did not complete within timeout",
          total_latency_ms: System.monotonic_time(:millisecond) - t0,
          worker_count: plan_meta[:worker_count]
        }
    end
  end

  defp default_solo_models do
    ["tinydolphin", "llama3.2:3b"]
  end

  defp skipped_collective do
    %{
      status: :skipped,
      synthesizer_answer: "(solo-only — collective not run)",
      synthesizer_model: nil,
      synthesizer_tokens_in: nil,
      synthesizer_tokens_out: nil,
      synthesizer_latency_ms: nil,
      total_latency_ms: 0,
      worker_count: 0,
      worker_outputs: [],
      plan_id: nil
    }
  end

  defp format_timestamp(nil), do: "RUN — (no timestamp)"

  defp format_timestamp(%DateTime{} = dt) do
    Calendar.strftime(dt, "RUN — %Y-%m-%d ~%H:%M UTC")
  end

  defp sanitize_for_json(map) when is_map(map) do
    Map.new(map, fn
      {k, %DateTime{} = v} -> {k, DateTime.to_iso8601(v)}
      {k, v} when is_map(v) -> {k, sanitize_for_json(v)}
      {k, v} when is_list(v) -> {k, Enum.map(v, &sanitize_for_json/1)}
      {k, v} when is_atom(v) -> {k, to_string(v)}
      {k, v} -> {k, v}
    end)
  end

  defp sanitize_for_json(list) when is_list(list), do: Enum.map(list, &sanitize_for_json/1)
  defp sanitize_for_json(atom) when is_atom(atom), do: to_string(atom)
  defp sanitize_for_json(other), do: other
end
