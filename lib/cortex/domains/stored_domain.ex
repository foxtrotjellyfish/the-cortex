defmodule Cortex.Domains.StoredDomain do
  @moduledoc """
  Ecto schema for persisted domain configuration. Domains survive restarts.
  The BootLoader reads these on startup and spawns Dynamic agents.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @adapter_modules %{
    "anthropic" => Cortex.LLM.Adapters.Anthropic,
    "ollama" => Cortex.LLM.Adapters.Ollama,
    "auto" => Cortex.LLM.Adapters.Auto
  }

  @adapter_names %{
    Cortex.LLM.Adapters.Anthropic => "anthropic",
    Cortex.LLM.Adapters.Ollama => "ollama",
    Cortex.LLM.Adapters.Auto => "auto"
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "domains" do
    field :name, :string
    field :system_prompt, :string
    field :topics, {:array, :string}, default: []
    field :adapter, :string, default: "anthropic"
    field :adapter_config, :map, default: %{}
    field :message_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:name, :system_prompt, :topics, :adapter, :adapter_config, :message_count])
    |> validate_required([:name, :adapter])
    |> unique_constraint(:name)
  end

  def adapter_module(%__MODULE__{adapter: name}), do: Map.get(@adapter_modules, name)
  def adapter_module(name) when is_binary(name), do: Map.get(@adapter_modules, name)

  def adapter_name(module) when is_atom(module), do: Map.get(@adapter_names, module, "anthropic")

  def to_spawn_opts(%__MODULE__{} = domain) do
    adapter = adapter_module(domain)
    config = atomize_keys(domain.adapter_config || %{})

    [
      name: String.to_atom(domain.name),
      topics: domain.topics,
      system_prompt: domain.system_prompt,
      adapter: adapter,
      adapter_config: config,
      message_count: domain.message_count || 0,
      persisted_id: domain.id
    ]
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end
end
