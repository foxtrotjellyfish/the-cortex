defmodule Cortex.Repo.Migrations.CreateDomains do
  use Ecto.Migration

  def change do
    create table(:domains, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :system_prompt, :text
      add :topics, :text, default: "[]"
      add :adapter, :string, null: false, default: "anthropic"
      add :adapter_config, :text, default: "{}"
      add :message_count, :integer, default: 0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:domains, [:name])
  end
end
