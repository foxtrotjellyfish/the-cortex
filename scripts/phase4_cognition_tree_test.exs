# Phase 4: Full Cognition Tree Test
#
# Tests the complete autonomous pipeline:
#   Human signal → Planner (llama3.2:3b) → Cortex.Graph (fan-out) →
#   N Workers (tinydolphin, parallel) → SQLite Memo → Synthesizer (llama3.2:3b)
#
# This is the first run where NO manual Graph.execute_plan/1 call is needed —
# the Planner is a real domain agent that decomposes the goal autonomously.
#
# Run with:
#   cd ~/Repositories/the-cortex && mix run scripts/phase4_cognition_tree_test.exs
#
# Pass criteria:
#   [ ] Planner receives signal, produces 3-5 numbered steps
#   [ ] Graph parses plan, spawns correct number of workers
#   [ ] All workers complete, memo entries persisted to SQLite
#   [ ] Synthesizer receives memo, produces coherent output
#   [ ] Total wall time reasonable for demo framing (~15-60s)

defmodule Phase4Test do
  @timeout_ms 120_000
  @research_question "How would you investigate when and where the BEAM virtual machine was invented?"

  def run do
    IO.puts("\n╔══════════════════════════════════════════════════════════╗")
    IO.puts("║       Phase 4: Full Cognition Tree Test                  ║")
    IO.puts("╠══════════════════════════════════════════════════════════╣")
    IO.puts("║  Planner → Graph → Workers → Synthesizer                 ║")
    IO.puts("║  llama3.2:3b plans + synthesizes; tinydolphin executes   ║")
    IO.puts("╚══════════════════════════════════════════════════════════╝\n")
    IO.puts("Question: #{@research_question}\n")

    # Subscribe before sending to catch everything
    Phoenix.PubSub.subscribe(Cortex.PubSub, "cortex:events")
    Phoenix.PubSub.subscribe(Cortex.PubSub, "synthesizer")
    Phoenix.PubSub.subscribe(Cortex.PubSub, "graph")

    # Verify Planner and Synthesizer are alive
    planner_pid = planner_pid()
    synthesizer_pid = synthesizer_pid()

    IO.puts("Planner PID:     #{inspect(planner_pid)}")
    IO.puts("Synthesizer PID: #{inspect(synthesizer_pid)}\n")

    unless planner_pid, do: raise("Planner not started — check application.ex")
    unless synthesizer_pid, do: raise("Synthesizer not started — check application.ex")

    start_ms = System.monotonic_time(:millisecond)

    # Send a signal directly to the "planner" topic.
    # Cortex.Router.route/1 broadcasts to the topic — Planner's PubSub
    # subscription picks it up.
    signal =
      Cortex.Signal.new(:human, "planner", @research_question,
        metadata: %{test: "phase4", source: "phase4_test"}
      )

    IO.puts("[#{elapsed(start_ms)}ms] Sending signal to Planner...")
    Cortex.Router.route(signal)

    # Collect events
    results = collect_events(start_ms, %{
      plan_id: nil,
      worker_count: nil,
      workers_done: 0,
      plan_complete: false,
      synthesis_received: false,
      synthesis_output: nil
    })

    wall_ms = System.monotonic_time(:millisecond) - start_ms

    IO.puts("\n╔══════════════════════════════════════════════════════════╗")
    IO.puts("║                     Results                              ║")
    IO.puts("╠══════════════════════════════════════════════════════════╣")

    plan_id = results.plan_id
    worker_count = results.worker_count || 0
    workers_done = results.workers_done

    passed = [
      check("Planner produced parseable plan", plan_id != nil),
      check("Workers spawned (3-5)", worker_count >= 3 and worker_count <= 5),
      check("All workers completed (#{workers_done}/#{worker_count})", workers_done == worker_count and worker_count > 0),
      check("Synthesizer received memo", results.synthesis_received),
      check("Synthesizer produced output", results.synthesis_output not in [nil, ""]),
      check("Wall time <120s (#{wall_ms}ms)", wall_ms < 120_000)
    ]

    IO.puts("╠══════════════════════════════════════════════════════════╣")

    if results.synthesis_output do
      IO.puts("║ Final synthesis:                                         ║")
      IO.puts("╚══════════════════════════════════════════════════════════╝\n")
      IO.puts(results.synthesis_output)
    else
      IO.puts("╚══════════════════════════════════════════════════════════╝")
    end

    pass_count = Enum.count(passed, & &1)
    IO.puts("\n[#{pass_count}/#{length(passed)} checks passed] Wall time: #{wall_ms}ms\n")

    # Verify memo entries in SQLite
    if plan_id do
      entries = Cortex.Memos.list_by_plan(plan_id)
      IO.puts("SQLite memo entries for plan #{String.slice(plan_id, 0, 12)}...: #{length(entries)}")
      Enum.each(entries, fn e ->
        IO.puts("  [#{e.worker_id}] #{String.slice(e.subtask, 0, 50)} → #{String.slice(e.content, 0, 80)}")
      end)
    end

    if pass_count == length(passed) do
      IO.puts("\n✓ PHASE 4 PASS — Cognition tree is autonomous end-to-end.")
      IO.puts("  Planner + Workers + Synthesizer form a complete OTP reasoning machine.")
    else
      IO.puts("\n⚠ PHASE 4 PARTIAL — #{length(passed) - pass_count} check(s) failed. Review output above.")
    end
  end

  defp collect_events(start_ms, acc) do
    receive do
      # Planner routed its plan to graph — plan_started fires from Graph
      {:plan_started, %{plan_id: plan_id, subtask_count: count}} ->
        IO.puts("[#{elapsed(start_ms)}ms] Plan started: #{plan_id} (#{count} sub-tasks)")
        collect_events(start_ms, %{acc | plan_id: plan_id, worker_count: count})

      {:worker_spawned, %{worker_id: worker_id, subtask: subtask}} ->
        IO.puts("[#{elapsed(start_ms)}ms]   Worker spawned: #{worker_id} → #{String.slice(subtask, 0, 60)}")
        collect_events(start_ms, acc)

      {:worker_done, %{worker_id: worker_id, done: done, total: total}} ->
        IO.puts("[#{elapsed(start_ms)}ms]   Worker done: #{worker_id} (#{done}/#{total})")
        collect_events(start_ms, %{acc | workers_done: done})

      {:plan_complete, %{plan_id: _pid, elapsed_ms: elapsed, worker_count: wc}} ->
        IO.puts("[#{elapsed(start_ms)}ms] Plan complete (fan-out took #{elapsed}ms, #{wc} workers)")
        collect_events(start_ms, %{acc | plan_complete: true})

      # Synthesizer output arrives as a {:signal, signal} on the "synthesizer" topic
      {:signal, %Cortex.Signal{source: :synthesizer, content: content}} ->
        IO.puts("[#{elapsed(start_ms)}ms] Synthesizer output received (#{String.length(content)} chars)")
        %{acc | synthesis_received: true, synthesis_output: content}

      # Raw plan signal arriving at Graph — print it for diagnostic purposes
      {:signal, %Cortex.Signal{source: :planner, content: plan_text}} ->
        IO.puts("[#{elapsed(start_ms)}ms] Raw Planner output (routed to graph):")
        IO.puts("───────────────────────────────────────────────")
        IO.puts(plan_text)
        IO.puts("───────────────────────────────────────────────")
        collect_events(start_ms, acc)

      _other ->
        collect_events(start_ms, acc)
    after
      @timeout_ms ->
        IO.puts("[#{elapsed(start_ms)}ms] Timeout (#{div(@timeout_ms, 1000)}s)")
        acc
    end
  end

  defp check(label, true) do
    IO.puts("║  ✓ #{String.pad_trailing(label, 52)}  ║")
    true
  end

  defp check(label, false) do
    IO.puts("║  ✗ #{String.pad_trailing(label, 52)}  ║")
    false
  end

  defp elapsed(start_ms), do: System.monotonic_time(:millisecond) - start_ms

  defp planner_pid do
    case Registry.lookup(Cortex.Domain.Registry, :planner) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp synthesizer_pid do
    case Registry.lookup(Cortex.Domain.Registry, :synthesizer) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end

Phase4Test.run()
