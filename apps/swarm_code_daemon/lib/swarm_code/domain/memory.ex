defmodule SwarmCode.Domain.Memory do
  @moduledoc """
  Durable facts the agents may save: a Markdown bullet list per project
  (`<root>/.swarm_code/MEMORY.md`) and one global list under the config dir.
  """

  alias SwarmCode.Domain.AtomicFile
  alias SwarmCode.Domain.Projects.Workspace

  @spec file(:project | :global, String.t() | nil) :: String.t()
  def file(:project, root) when is_binary(root), do: Workspace.memory_file(root)
  def file(_scope, _root), do: Workspace.global_memory_file()

  @spec read(:project | :global, String.t() | nil) :: String.t()
  def read(scope, root \\ nil) do
    # spec 60 T22: confined — a MEMORY.md linked out of the root reads as empty.
    case AtomicFile.read(allowed_root(scope, root), file(scope, root)) do
      {:ok, text} -> text
      _ -> ""
    end
  end

  @doc "Appends `- [YYYY-MM-DD] <text>` and returns the file path."
  @spec append(:project | :global, String.t() | nil, String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def append(scope, root, text) do
    line = "- [#{Date.to_iso8601(Date.utc_today())}] " <> one_line(text)
    path = file(scope, root)

    # Spec 13 §11 A-14: read-modify-write lost lines when two agents remembered
    # something at the same time. An `:append` write is one atomic write per line.
    # spec 60 T22: the target is resolved and confined first (`AtomicFile.target/2`).
    with :ok <- ensure_parent(scope, root, path),
         {:ok, target} <- resolve(scope, root, path) do
      current = read(scope, root)
      prefix = if current == "" or String.ends_with?(current, "\n"), do: "", else: "\n"

      case File.write(target, prefix <> line <> "\n", [:append]) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
      end
    end
  end

  @doc """
  Replaces the whole file. `append/3` keeps its `O_APPEND` write instead: that is
  what stops two agents remembering at the same time from losing a line
  (spec 13 §11 A-14), and a read-modify-write cannot promise the same.
  """
  @spec write(:project | :global, String.t() | nil, String.t()) :: :ok | {:error, String.t()}
  def write(scope, root, text) do
    path = file(scope, root)

    with :ok <- ensure_parent(scope, root, path) do
      case AtomicFile.replace(allowed_root(scope, root), path, text) do
        :ok -> :ok
        {:error, reason} -> {:error, "cannot write #{path}: #{AtomicFile.format_error(reason)}"}
      end
    end
  end

  defp allowed_root(:project, root) when is_binary(root), do: root
  defp allowed_root(_scope, _root), do: Workspace.global_dir()

  # spec 60 T22
  defp resolve(scope, root, path) do
    case AtomicFile.target(allowed_root(scope, root), path) do
      {:ok, target} -> {:ok, target}
      {:error, reason} -> {:error, "cannot write #{path}: #{AtomicFile.format_error(reason)}"}
    end
  end

  defp ensure_parent(:project, root, _path) when is_binary(root) do
    Workspace.ensure!(root)
    :ok
  end

  defp ensure_parent(_scope, _root, path) do
    File.mkdir_p(Path.dirname(path))
    :ok
  end

  defp one_line(text), do: text |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim()
end
