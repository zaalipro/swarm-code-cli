defmodule SwarmCode.Domain.Tools.Remember do
  @moduledoc "Saves a durable fact to the project or global memory file."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Memory

  @impl true
  def name, do: "remember"

  @impl true
  def description,
    do:
      "Save a durable fact to memory so future turns and agents know it. " <>
        "Use scope \"project\" for facts about this repository and \"global\" for the user's " <>
        "own preferences. Never save secrets or transient details."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "text" => %{"type" => "string", "description" => "The fact, one sentence"},
        "scope" => %{
          "type" => "string",
          "enum" => ["project", "global"],
          "description" => "project (default) or global"
        }
      },
      "required" => ["text"]
    }
  end

  @impl true
  def permission(_args), do: :write

  @impl true
  def title(args), do: "remember: " <> String.slice(to_string(args["text"] || ""), 0, 40)

  @impl true
  def run(args, ctx, progress) do
    scope = if to_string(args["scope"]) == "global", do: :global, else: :project
    progress.(50, "saving")

    case Memory.append(scope, ctx.project_root, args["text"]) do
      {:ok, _path} ->
        progress.(100, "saved")
        {:ok, "Saved to #{scope} memory."}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
