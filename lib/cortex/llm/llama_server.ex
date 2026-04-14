defmodule Cortex.LLM.LlamaServer do
  @moduledoc """
  OTP supervisor for the llama-server process.

  Starts llama-server as a Port child. If the process crashes, the supervisor
  restarts it automatically — inference resumes without manual intervention.

  Config (in application.ex or config.exs):
    {Cortex.LLM.LlamaServer,
     model_path: "/path/to/model.gguf",
     port: 8080,
     ctx_size: 2048}

  The GenServer does NOT attempt inference — it only starts and monitors
  llama-server. The LlamaCpp adapter handles HTTP calls to its endpoint.
  """

  use GenServer, restart: :permanent

  require Logger

  @default_port 8080
  @default_ctx_size 2048
  @startup_wait_ms 3_000
  @health_check_interval_ms 5_000

  defstruct [:model_path, :port, :ctx_size, :os_pid, :port_ref, :ready]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true once llama-server has passed its health check."
  def ready? do
    GenServer.call(__MODULE__, :ready?, 5_000)
  rescue
    _ -> false
  end

  @doc "Returns the base URL clients should use."
  def base_url do
    port = GenServer.call(__MODULE__, :port, 1_000)
    "http://localhost:#{port}"
  rescue
    _ -> "http://localhost:#{@default_port}"
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    model_path = Keyword.fetch!(opts, :model_path)
    port = Keyword.get(opts, :port, @default_port)
    ctx_size = Keyword.get(opts, :ctx_size, @default_ctx_size)

    state = %__MODULE__{
      model_path: model_path,
      port: port,
      ctx_size: ctx_size,
      ready: false
    }

    {:ok, state, {:continue, :start_server}}
  end

  @impl true
  def handle_continue(:start_server, state) do
    Logger.info("[LlamaServer] Starting llama-server on port #{state.port}")
    Logger.info("[LlamaServer] Model: #{state.model_path}")

    cmd = System.find_executable("llama-server")

    unless cmd do
      Logger.error("[LlamaServer] llama-server not found in PATH — install via `brew install llama.cpp`")
      {:stop, :llama_server_not_found, state}
    else
      args = [
        "--model", state.model_path,
        "--port", to_string(state.port),
        "--ctx-size", to_string(state.ctx_size),
        "--log-disable"
      ]

      port_ref =
        Port.open({:spawn_executable, cmd}, [
          :binary,
          :stderr_to_stdout,
          {:args, args},
          {:line, 2048}
        ])

      {:ok, os_pid} = fetch_os_pid(port_ref)

      Logger.info("[LlamaServer] Started with OS PID #{os_pid}")

      Process.send_after(self(), :check_health, @startup_wait_ms)

      {:noreply, %{state | port_ref: port_ref, os_pid: os_pid}}
    end
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.ready, state}

  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info(:check_health, state) do
    url = "http://localhost:#{state.port}/health"

    case Req.get(url, receive_timeout: 2_000) do
      {:ok, %{status: 200}} ->
        Logger.info("[LlamaServer] Health check passed — server is ready")
        {:noreply, %{state | ready: true}}

      _ ->
        Logger.debug("[LlamaServer] Not ready yet, retrying in #{@health_check_interval_ms}ms")
        Process.send_after(self(), :check_health, @health_check_interval_ms)
        {:noreply, state}
    end
  end

  def handle_info({port_ref, {:data, {:eol, line}}}, %{port_ref: port_ref} = state) do
    Logger.debug("[LlamaServer] #{line}")
    {:noreply, state}
  end

  def handle_info({:DOWN, _, :port, port_ref, reason}, %{port_ref: port_ref} = state) do
    Logger.warning("[LlamaServer] Port exited: #{inspect(reason)} — OTP will restart")
    {:stop, {:port_down, reason}, state}
  end

  def handle_info({port_ref, :closed}, %{port_ref: port_ref} = state) do
    Logger.warning("[LlamaServer] Port closed — OTP will restart")
    {:stop, :port_closed, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{os_pid: os_pid}) when is_integer(os_pid) do
    Logger.info("[LlamaServer] Terminating, sending SIGTERM to OS PID #{os_pid}")
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # --- Helpers ---

  defp fetch_os_pid(port_ref) do
    case Port.info(port_ref, :os_pid) do
      {:os_pid, pid} -> {:ok, pid}
      nil -> {:error, :no_os_pid}
    end
  end
end
