defmodule Phase5LlamaCppTest do
  @moduledoc """
  Phase 5 validation: LlamaCpp adapter against a live llama-server instance.

  Test plan:
  1. Start llama-server as an OS subprocess pointing at the Qwen model
  2. Wait for the /health endpoint to come up
  3. Run 3 inference calls through Cortex.LLM.Adapters.LlamaCpp
     A. Worker prompt — short factual sentence
     B. NL Planner prompt — numbered step decomposition (Phase 1B format)
     C. Synthesizer prompt — compose from fragments
  4. Assert each call returns non-empty output
  5. Kill llama-server, verify connection errors cleanly
  6. Print pass/fail summary and wall time

  Pass criteria:
  - All 3 inference calls return {:ok, %{output: non_empty_string}}
  - Adapter correctly maps tokens_in / tokens_out from the OpenAI response
  - Connection failure after kill returns {:error, _} (not a crash)
  """

  @model_path System.get_env("LLAMA_MODEL", Path.expand("~/models/qwen2.5-0.5b-instruct-q4_k_m.gguf"))
  @server_port 8081
  @base_url "http://localhost:#{@server_port}"

  def run do
    IO.puts("\n=== Phase 5: LlamaCpp Adapter Test ===")
    IO.puts("Model: #{@model_path}")
    IO.puts("Server port: #{@server_port}\n")

    unless File.exists?(@model_path) do
      IO.puts("❌  Model file not found: #{@model_path}")
      IO.puts("    Download with:")
      IO.puts("    curl -L https://huggingface.co/bartowski/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/Qwen2.5-0.5B-Instruct-Q4_K_M.gguf -o #{@model_path}")
      exit(:model_not_found)
    end

    start_ms = System.monotonic_time(:millisecond)

    {server_pid, port_ref} = start_llama_server()
    IO.puts("⏳  Waiting for llama-server to start...")
    wait_for_health(@base_url)
    IO.puts("✅  llama-server ready\n")

    results = run_inference_checks()

    IO.puts("\n--- Killing llama-server ---")
    kill_llama_server(server_pid, port_ref)
    Process.sleep(500)
    connection_error_result = check_connection_failure()

    elapsed = System.monotonic_time(:millisecond) - start_ms

    print_summary(results, connection_error_result, elapsed)
  end

  defp start_llama_server do
    cmd = System.find_executable("llama-server")

    unless cmd do
      IO.puts("❌  llama-server not found in PATH. Install: brew install llama.cpp")
      exit(:no_llama_server)
    end

    args = [
      "--model", @model_path,
      "--port", to_string(@server_port),
      "--ctx-size", "2048",
      "--log-disable"
    ]

    port_ref =
      Port.open({:spawn_executable, cmd}, [
        :binary,
        :stderr_to_stdout,
        {:args, args},
        {:line, 2048}
      ])

    {:os_pid, os_pid} = Port.info(port_ref, :os_pid)
    IO.puts("Started llama-server (OS PID #{os_pid})")
    {os_pid, port_ref}
  end

  defp wait_for_health(base_url, attempts \\ 0) do
    if attempts > 60 do
      IO.puts("❌  llama-server did not start within 60s")
      exit(:timeout)
    end

    case Req.get("#{base_url}/health", receive_timeout: 2_000) do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        Process.sleep(1_000)
        wait_for_health(base_url, attempts + 1)
    end
  end

  defp kill_llama_server(os_pid, port_ref) do
    Port.close(port_ref)
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    IO.puts("Sent SIGTERM to OS PID #{os_pid}")
  end

  defp run_inference_checks do
    config = %{base_url: @base_url, model: "local", max_tokens: 128}
    adapter = Cortex.LLM.Adapters.LlamaCpp

    checks = [
      {
        :worker_prompt,
        "Answer in 1-2 sentences only.",
        "What programming paradigm does Erlang/OTP primarily use?",
        &(&1 != "")
      },
      {
        :planner_prompt,
        "You are a research planner. Break the given goal into exactly 3-5 concrete research steps. Number each step. One step per line. Plain English only. No explanation, no intro, just the numbered steps.",
        "How would you investigate the history of actor-based concurrency models?",
        fn output ->
          lines = output |> String.split("\n") |> Enum.filter(&(&1 != "")) |> length()
          lines >= 2
        end
      },
      {
        :synthesizer_prompt,
        "Given these research fragments, compose a coherent 2-3 sentence answer. Be concise.",
        "[BEAM history]\nThe BEAM VM was created by Ericsson in the 1980s for telecom reliability.\n[Actor model]\nThe actor model provides lightweight process isolation with message passing.",
        &(&1 != "")
      }
    ]

    Enum.map(checks, fn {name, system, input, validator} ->
      IO.puts("🔸  #{name}...")
      t0 = System.monotonic_time(:millisecond)
      result = adapter.call(system, input, config)
      elapsed = System.monotonic_time(:millisecond) - t0

      case result do
        {:ok, %{output: output, tokens_in: tin, tokens_out: tout}} when output != nil ->
          trimmed = String.trim(output)
          passed = validator.(trimmed)
          status = if passed, do: "✅", else: "⚠️ "
          IO.puts("#{status}  #{name}: #{elapsed}ms | #{tin}→#{tout} tokens")
          IO.puts("    #{String.slice(trimmed, 0, 120)}#{if String.length(trimmed) > 120, do: "…", else: ""}")
          {name, passed, elapsed, trimmed}

        {:error, reason} ->
          IO.puts("❌  #{name} FAILED: #{inspect(reason)}")
          {name, false, elapsed, nil}
      end
    end)
  end

  defp check_connection_failure do
    result = Cortex.LLM.Adapters.LlamaCpp.call("test", "test", %{base_url: @base_url})
    case result do
      {:error, _reason} ->
        IO.puts("✅  Post-kill connection correctly returns {:error, _}")
        true
      {:ok, _} ->
        IO.puts("❌  Post-kill call unexpectedly succeeded")
        false
    end
  end

  defp print_summary(results, connection_error_ok, elapsed_ms) do
    IO.puts("\n=== Phase 5 Summary ===")
    IO.puts("Wall time: #{elapsed_ms}ms\n")

    all_passed = Enum.all?(results, fn {_, passed, _, _} -> passed end) and connection_error_ok

    Enum.each(results, fn {name, passed, ms, _} ->
      status = if passed, do: "✅ PASS", else: "❌ FAIL"
      IO.puts("  #{status}  #{name} (#{ms}ms)")
    end)

    IO.puts("  #{if connection_error_ok, do: "✅ PASS", else: "❌ FAIL"}  connection_failure_on_kill")

    IO.puts("\n#{if all_passed, do: "✅  Phase 5 PASS — LlamaCpp adapter validated", else: "❌  Phase 5 FAIL — review output above"}")
  end
end

Phase5LlamaCppTest.run()
