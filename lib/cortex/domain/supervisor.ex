defmodule Cortex.Domain.Supervisor do
  @moduledoc """
  DynamicSupervisor for domain agent GenServers.
  Spawns whatever domains the configuration asks for.
  """

  use DynamicSupervisor
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_agent(module, config \\ []) do
    spec = {module, config}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_agent(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  def running_agents do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.map(fn {_, pid, _, _} -> pid end)
    |> Enum.filter(&is_pid/1)
  end

  @impl true
  def init(_init_arg) do
    Logger.info("[Cortex.Domain.Supervisor] Online. Ready for domain agents.")
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
