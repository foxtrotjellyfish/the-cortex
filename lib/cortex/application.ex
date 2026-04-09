defmodule Cortex.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CortexWeb.Telemetry,
      Cortex.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:cortex, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:cortex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Cortex.PubSub},
      {Registry, keys: :unique, name: Cortex.Domain.Registry},
      Cortex.Trace.Collector,
      Cortex.Router,
      Cortex.Domain.Supervisor,
      CortexWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cortex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CortexWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    System.get_env("RELEASE_NAME") == nil
  end
end
