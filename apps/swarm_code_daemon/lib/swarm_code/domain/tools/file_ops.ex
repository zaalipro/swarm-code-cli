defmodule SwarmCode.Domain.Tools.FileOps do
  @moduledoc """
  spec 66 T12: renaming and deleting a file as confined, checkpointed `:write`
  tool calls (`move_file`, `delete_file`) instead of a `run_command` with `mv`
  or `rm`, which is a different permission class, is not confined to the project
  root, and leaves no rewind point behind.

  Both tools live in one module; each `Tools.Tool` implementation is a submodule.
  """

  alias SwarmCode.Domain.Checkpoints
  alias SwarmCode.Domain.Tools.Path

  @doc false
  # The shared guard: no write without a rewind point (spec 55 T16 / spec 60 T26).
  @spec checkpoint(map(), [String.t()]) :: :ok | {:error, String.t()}
  def checkpoint(ctx, paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case Checkpoints.snapshot(ctx, path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, Checkpoints.error_message(reason)}}
      end
    end)
  end

  @doc false
  def resolve_pair(root, from, to) do
    with {:ok, from_abs} <- Path.resolve_write(root, from),
         {:ok, to_abs} <- Path.resolve_write(root, to) do
      {:ok, from_abs, to_abs}
    end
  end

  defmodule MoveFile do
    @moduledoc "Rename or move a file inside the project root."
    @behaviour SwarmCode.Domain.Tools.Tool

    alias SwarmCode.Domain.Tools.FileOps
    alias SwarmCode.Domain.Tools.Path

    @impl true
    def name, do: "move_file"

    @impl true
    def description,
      do:
        "Rename or move a file inside the project root. Both paths are relative to the " <>
          "project root; the destination must not exist unless overwrite is true, and its " <>
          "parent directories are created. The file's previous location is snapshotted, so " <>
          "the move can be rewound. Use this instead of run_command with mv."

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "from" => %{"type" => "string", "description" => "Existing path, relative to the root"},
          "to" => %{"type" => "string", "description" => "New path, relative to the root"},
          "overwrite" => %{"type" => "boolean", "description" => "Replace an existing target"}
        },
        "required" => ["from", "to"]
      }
    end

    @impl true
    def permission(_args), do: :write

    # spec 66 T20
    @impl true
    def parallel?, do: false

    @impl true
    def title(args), do: "move " <> (args["from"] || "") <> " → " <> (args["to"] || "")

    @impl true
    def run(args, ctx, progress) do
      root = ctx.project_root

      with {:ok, from, to} <- FileOps.resolve_pair(root, args["from"], args["to"]) do
        from_rel = Path.relative(root, from)
        to_rel = Path.relative(root, to)

        cond do
          not File.exists?(from) ->
            {:error, "file not found: #{from_rel}"}

          File.dir?(from) ->
            {:error,
             "move_file works on files; use run_command with mv for a directory: #{from_rel}"}

          File.exists?(to) and args["overwrite"] != true ->
            {:error, "#{to_rel} already exists — pass overwrite=true to replace it"}

          File.dir?(to) ->
            {:error, "#{to_rel} is a directory"}

          true ->
            move(ctx, from, to, from_rel, to_rel, progress)
        end
      end
    end

    defp move(ctx, from, to, from_rel, to_rel, progress) do
      # The destination is checkpointed too, existing or not: a checkpoint of a
      # file that did not exist rewinds by deleting it again, which is exactly
      # what undoing a move needs.
      with :ok <- FileOps.checkpoint(ctx, [from, to]),
           :ok <- File.mkdir_p(Elixir.Path.dirname(to)),
           :ok <- File.rename(from, to) do
        progress.(100, to_rel)
        {:ok, "moved #{from_rel} → #{to_rel}"}
      else
        {:error, message} when is_binary(message) -> {:error, message}
        {:error, reason} -> {:error, "cannot move #{from_rel}: #{:file.format_error(reason)}"}
      end
    end
  end

  defmodule DeleteFile do
    @moduledoc "Delete a file inside the project root."
    @behaviour SwarmCode.Domain.Tools.Tool

    alias SwarmCode.Domain.Tools.FileOps
    alias SwarmCode.Domain.Tools.Path

    @impl true
    def name, do: "delete_file"

    @impl true
    def description,
      do:
        "Delete a file inside the project root. The path is relative to the project root and " <>
          "must be a file, not a directory. The content is snapshotted first, so the delete " <>
          "can be rewound. Use this instead of run_command with rm."

    @impl true
    def parameters do
      %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path relative to the project root"}
        },
        "required" => ["path"]
      }
    end

    @impl true
    def permission(_args), do: :write

    # spec 66 T20
    @impl true
    def parallel?, do: false

    @impl true
    def title(args), do: "delete " <> (args["path"] || "")

    @impl true
    def run(args, ctx, progress) do
      root = ctx.project_root

      with {:ok, abs} <- Path.resolve_write(root, args["path"]) do
        rel = Path.relative(root, abs)

        cond do
          File.dir?(abs) ->
            {:error, "delete_file works on files; use run_command with rm -r for a directory"}

          not File.exists?(abs) ->
            {:error, "file not found: #{rel}"}

          true ->
            delete(ctx, abs, rel, progress)
        end
      end
    end

    defp delete(ctx, abs, rel, progress) do
      size =
        case File.stat(abs) do
          {:ok, %{size: size}} -> size
          _error -> 0
        end

      with :ok <- FileOps.checkpoint(ctx, [abs]),
           :ok <- File.rm(abs) do
        progress.(100, rel)
        {:ok, "deleted #{rel} (#{size} bytes)"}
      else
        {:error, message} when is_binary(message) -> {:error, message}
        {:error, reason} -> {:error, "cannot delete #{rel}: #{:file.format_error(reason)}"}
      end
    end
  end
end
