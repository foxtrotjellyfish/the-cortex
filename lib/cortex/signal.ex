defmodule Cortex.Signal do
  @moduledoc """
  The message unit. Fire-and-forget. The sender doesn't know or care who receives it.
  """

  @type priority :: :urgent | :normal | :low

  @type t :: %__MODULE__{
          id: String.t(),
          source: atom(),
          topic: String.t(),
          content: String.t(),
          priority: priority(),
          metadata: map()
        }

  @enforce_keys [:id, :source, :topic, :content]
  defstruct [
    :id,
    :source,
    :topic,
    :content,
    priority: :normal,
    metadata: %{}
  ]

  def new(source, topic, content, opts \\ []) do
    %__MODULE__{
      id: gen_id(),
      source: source,
      topic: topic,
      content: content,
      priority: Keyword.get(opts, :priority, :normal),
      metadata:
        Keyword.get(opts, :metadata, %{})
        |> Map.put(:timestamp, DateTime.utc_now())
        |> Map.put(:machine, node())
    }
  end

  defp gen_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
