defmodule SwarmCode.Tools.WriteFile do
  @moduledoc "Create or overwrite a file."
  @behaviour SwarmCode.Tools.Tool

  alias SwarmCode.Tools.AtomicFile
  alias SwarmCode.Tools.Path

  @impl true
  def name, do: "write_file"

  @impl true
  def description,
    do: "Create or overwrite a file with the given content (creates parent directories)."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the project root"},
        "content" => %{"type" => "string", "description" => "Full file content"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def permission(_args), do: :write

  @impl true
  def title(args), do: "write " <> (args["path"] || "")

  @impl true
  def run(args, ctx, progress) do
    with {:ok, abs} <- Path.resolve(ctx.project_root, args["path"]) do
      rel = Path.relative(ctx.project_root, abs)
      content = args["content"]
      progress.(50, "writing")

      case AtomicFile.replace(ctx.project_root, abs, content) do
        :ok ->
          progress.(100, "#{byte_size(content)} bytes")
          {:ok, "wrote #{byte_size(content)} bytes to #{rel}"}

        {:error, reason} ->
          {:error, "cannot write #{rel}: #{AtomicFile.format_error(reason)}"}
      end
    end
  end
end
