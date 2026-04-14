defmodule Cortex.Repo.Migrations.CreateMemos do
  use Ecto.Migration

  def change do
    create table(:cortex_memos, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :plan_id, :string, null: false
      add :worker_id, :string, null: false
      add :subtask, :text, null: false
      add :content, :text, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:cortex_memos, [:plan_id])
  end
end
