defmodule Cortex.Domains.BootLoader do
  @moduledoc """
  Restores persisted domains on application start. Reads from the domains
  table and spawns Dynamic agents through the DynamicSupervisor.

  Also handles seeding initial domains from config on first boot.
  """

  use GenServer
  require Logger

  alias Cortex.Domains.StoredDomain
  alias Cortex.Repo

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    send(self(), :boot)
    {:ok, %{restored: 0}}
  end

  @impl true
  def handle_info(:boot, state) do
    seed_count = maybe_seed_domains()
    restore_count = restore_persisted_domains()

    total = seed_count + restore_count
    Logger.info("[BootLoader] Boot complete: #{total} domains active (#{seed_count} seeded, #{restore_count} restored)")

    {:noreply, %{state | restored: total}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_seed_domains do
    seeds = Application.get_env(:cortex, :seed_domains, [])
    existing = Repo.all(StoredDomain) |> Enum.map(& &1.name) |> MapSet.new()

    seeds
    |> Enum.reject(fn seed -> MapSet.member?(existing, to_string(seed.name)) end)
    |> Enum.map(fn seed ->
      attrs = %{
        name: to_string(seed.name),
        system_prompt: seed.system_prompt,
        topics: Enum.map(seed[:topics] || [to_string(seed.name)], &to_string/1),
        adapter: StoredDomain.adapter_name(seed[:adapter] || Cortex.LLM.Adapters.Anthropic),
        adapter_config: stringify_keys(seed[:adapter_config] || %{})
      }

      case Repo.insert(StoredDomain.changeset(%StoredDomain{}, attrs)) do
        {:ok, _record} ->
          Logger.info("[BootLoader] Seeded domain: #{attrs.name}")
          :ok

        {:error, changeset} ->
          Logger.warning("[BootLoader] Failed to seed #{attrs.name}: #{inspect(changeset.errors)}")
          :error
      end
    end)
    |> Enum.count(&(&1 == :ok))
  end

  defp restore_persisted_domains do
    Repo.all(StoredDomain)
    |> Enum.map(fn domain ->
      opts = StoredDomain.to_spawn_opts(domain)

      case Cortex.Domain.Supervisor.start_agent(Cortex.Domains.Dynamic, opts) do
        {:ok, pid} ->
          Logger.info("[BootLoader] Restored: #{domain.name} (#{inspect(pid)})")
          :ok

        {:error, {:already_started, _pid}} ->
          Logger.debug("[BootLoader] Already running: #{domain.name}")
          :ok

        {:error, reason} ->
          Logger.error("[BootLoader] Failed to restore #{domain.name}: #{inspect(reason)}")
          :error
      end
    end)
    |> Enum.count(&(&1 == :ok))
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
