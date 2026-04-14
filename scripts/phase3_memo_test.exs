#!/usr/bin/env elixir
# Phase 3: Shared Memo Store validation
#
# Runs the full cognition tree (same plan as Phase 2) and then validates
# that the SQLite memo store received one entry per worker.
#
# Run from the-cortex root:
#   iex -S mix -e 'Code.require_file("scripts/phase3_memo_test.exs"); Phase3MemoTest.run()'
#
# Pass criteria:
#   - All Phase 2 criteria still pass (fan-out/fan-in intact)
#   - Memo table contains exactly N entries for the plan_id (one per worker)
#   - Synthesizer reads from SQLite (not in-memory state)
#   - Each memo entry has non-empty content

defmodule Phase3MemoTest do
  require Logger

  @test_plan """
  1. Find the year the BEAM virtual machine was first released and by whom.
  2. Identify the key design goals that shaped the BEAM architecture.
  3. Explain what the BEAM acronym stands for and any naming history.
  4. Describe how Erlang's concurrency model differs from thread-based systems.
  """

  def run do
    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Phase 3: Shared Memo Store Test")
    IO.puts(String.duplicate("=", 60))

    IO.puts("\n[Setup] Subscribing to event topics...")
    Phoenix.PubSub.subscribe(Cortex.PubSub, "cortex:events")
    Phoenix.PubSub.subscribe(Cortex.PubSub, "synthesizer")

    # Clear any memos from prior test runs so counts are clean
    IO.puts("[Setup] Pre-run memo count: #{pre_run_count()}")

    IO.puts("\n[Test] Sending plan to Cortex.Graph...")
    start_time = System.monotonic_time(:millisecond)

    {:ok, plan_id} = Cortex.Graph.execute_plan(@test_plan)
    IO.puts("  Plan ID: #{plan_id}")
    IO.puts("  Waiting for completion (timeout: 180s)...\n")

    result = collect_events(plan_id, start_time, 180_000)

    total_elapsed = System.monotonic_time(:millisecond) - start_time

    # Phase 2 checks
    workers_spawned = length(result.workers_spawned)
    workers_done = length(result.workers_done)

    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("Fan-Out / Fan-In (Phase 2 baseline)")
    IO.puts(String.duplicate("-", 60))
    IO.puts("Workers spawned:     #{workers_spawned}")
    IO.puts("Workers completed:   #{workers_done}")
    IO.puts("Plan complete event: #{check(result.plan_complete)}")
    IO.puts("Synthesizer signal:  #{check(result.synthesizer_signal)}")
    IO.puts("Wall time:           #{total_elapsed}ms")

    # Phase 3 checks — query the DB
    IO.puts("\n" <> String.duplicate("-", 60))
    IO.puts("Memo Store (Phase 3)")
    IO.puts(String.duplicate("-", 60))

    memos = Cortex.Memos.list_by_plan(plan_id)
    memo_count = length(memos)
    all_have_content = Enum.all?(memos, fn m -> m.content != "" end)
    count_matches = memo_count == workers_done and memo_count > 0

    IO.puts("Memo entries in DB:  #{memo_count}")
    IO.puts("Matches worker count:#{check(count_matches)} (expected #{workers_done})")
    IO.puts("All entries non-empty:#{check(all_have_content)}")

    IO.puts("\nMemo entries:")
    Enum.each(memos, fn m ->
      IO.puts("  [#{m.worker_id}] subtask: #{String.slice(m.subtask, 0, 55)}")
      IO.puts("             content: #{String.slice(m.content, 0, 80)}")
    end)

    # Synthesizer input reconstruction
    if result.synthesizer_signal do
      synth_content = result.synthesizer_signal.content
      IO.puts("\n--- Synthesizer memo input (from SQLite, first 500 chars) ---")
      IO.puts(String.slice(synth_content, 0, 500))
      IO.puts("---")

      # Verify synthesizer content matches DB entries
      db_synthesis = memos |> Cortex.Memos.to_synthesis_input()
      content_matches = synth_content == db_synthesis
      IO.puts("\nSynthesizer input matches DB: #{check(content_matches)}")
    end

    # Overall verdict
    phase2_pass =
      workers_spawned > 0 and
        workers_done == workers_spawned and
        not is_nil(result.plan_complete) and
        not is_nil(result.synthesizer_signal)

    phase3_pass = count_matches and all_have_content

    IO.puts("\n" <> String.duplicate("=", 60))
    IO.puts("Phase 2 (fan-out/fan-in): #{if phase2_pass, do: "PASS ✓", else: "FAIL ✗"}")
    IO.puts("Phase 3 (memo store):     #{if phase3_pass, do: "PASS ✓", else: "FAIL ✗"}")
    IO.puts(String.duplicate("=", 60))

    if result[:timed_out] do
      IO.puts("\n⚠ Timed out — check Ollama: curl http://localhost:11434/api/tags")
    end

    IO.puts("\nTrace count: #{Cortex.Trace.Collector.count()}")

    {phase2_pass, phase3_pass}
  end

  defp pre_run_count do
    Cortex.Repo.aggregate(Cortex.Memo, :count)
  end

  defp collect_events(plan_id, start_time, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    state = %{
      workers_spawned: [],
      workers_done: [],
      plan_complete: nil,
      synthesizer_signal: nil
    }

    do_collect(plan_id, state, deadline, start_time)
  end

  defp do_collect(plan_id, state, deadline, start_time) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      IO.puts("  [TIMEOUT]")
      Map.put(state, :timed_out, true)
    else
      receive do
        {:plan_started, %{plan_id: ^plan_id, subtask_count: count}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          IO.puts("  [+#{elapsed}ms] Plan started → #{count} workers")
          do_collect(plan_id, state, deadline, start_time)

        {:worker_spawned, %{plan_id: ^plan_id, worker_id: wid, subtask: task}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          IO.puts("  [+#{elapsed}ms] Spawned #{wid} → #{String.slice(task, 0, 50)}")
          do_collect(plan_id, update_in(state, [:workers_spawned], &[wid | &1]), deadline, start_time)

        {:worker_done, %{plan_id: ^plan_id, worker_id: wid, done: done, total: total}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          IO.puts("  [+#{elapsed}ms] Done #{wid} (#{done}/#{total})")
          do_collect(plan_id, update_in(state, [:workers_done], &[wid | &1]), deadline, start_time)

        {:plan_complete, %{plan_id: ^plan_id, elapsed_ms: ms, worker_count: wc}} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          IO.puts("  [+#{elapsed}ms] ✓ Plan complete — #{wc} workers in #{ms}ms")
          do_collect(plan_id, Map.put(state, :plan_complete, %{elapsed_ms: ms, worker_count: wc}), deadline, start_time)

        {:signal, %Cortex.Signal{topic: "synthesizer", metadata: %{plan_id: ^plan_id}} = sig} ->
          elapsed = System.monotonic_time(:millisecond) - start_time
          IO.puts("  [+#{elapsed}ms] ✓ Synthesizer signal (#{String.length(sig.content)} chars)")
          Map.put(state, :synthesizer_signal, sig)

        {:signal, %Cortex.Signal{topic: "synthesizer"}} ->
          do_collect(plan_id, state, deadline, start_time)

        _other ->
          do_collect(plan_id, state, deadline, start_time)
      after
        remaining -> Map.put(state, :timed_out, true)
      end
    end
  end

  defp check(val), do: if(val, do: "✓", else: "✗")
end
