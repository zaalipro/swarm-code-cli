defmodule SwarmCode.Domain.AtomicFile do
  @moduledoc """
  The one way SwarmCode replaces the content of a file it owns (spec 31 §2.1).

  Two properties, and one deliberate non-property.

  **Atomic.** The bytes go to a temporary file in the *same directory*, are
  flushed, closed, given the old file's mode and then `rename`d over the target.
  A reader — the model reading back what it wrote, the editor, git — sees either
  the old file or the new one, never a half-written one, and a crash between the
  two leaves the old file intact. `File.write/2` truncates first, so a large
  write that fails halfway used to leave a broken file behind.

  **Confined.** The target is validated against a root the *caller* supplies,
  both lexically and after resolving every symlink, so a link inside the tree
  cannot be used to write outside it.

  The non-property: this **follows** an in-root symlink instead of replacing it.
  `SwarmCode.Domain.Tools.Path.resolve/2` already refuses a link that escapes the root,
  and a link that stays inside it is a legitimate thing to have in a repository —
  `README.md -> docs/README.md` is somebody's actual layout. Replacing the link
  with a regular file would be a silent, unasked-for change to the user's tree,
  so the write goes to the file the link points at, exactly as `File.write/2`
  would have done.

  There is no lock. `replace/3` is atomic per call, and `update/4` has the same
  read-modify-write window it had before — a serializer belongs at the level that
  knows what a conflict *means*, not under every write. `SwarmCode.Domain.Memory`, where
  two agents really do append at the same time, keeps its `O_APPEND` writes for
  that reason (spec 13 §11 A-14).
  """

  alias SwarmCode.Domain.Tools.Path, as: SafePath

  @type reason :: :outside_root | :symlink_cycle | :not_regular | File.posix()

  # The temp is unreadable to anyone else while it is being written: content on
  # its way into a mode-0600 file must not be world-readable in the meantime.
  @temp_mode 0o600

  @doc """
  The real, confined file this write lands on.

  Symlinks are resolved (so the answer may be a different path than asked for),
  and the answer is always inside `root`.
  """
  @spec target(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason()}
  def target(root, path) do
    root = Path.expand(root)
    expanded = Path.expand(to_string(path || ""), root)

    with true <- SafePath.inside?(root, expanded),
         {:ok, real_root} <- SafePath.real_path(root),
         {:ok, real} <- SafePath.real_path(expanded),
         true <- SafePath.inside?(real_root, real) do
      {:ok, real}
    else
      false -> {:error, :outside_root}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Replaces the whole content of `path`, atomically."
  @spec replace(String.t(), String.t(), iodata()) :: :ok | {:error, reason()}
  def replace(root, path, data) do
    with {:ok, target} <- target(root, path), do: write(target, data)
  end

  @doc """
  Reads `path`, hands the content to `fun` and replaces it with what comes back.

  `missing: :empty` treats an absent file as `""` instead of failing.
  """
  @spec update(
          String.t(),
          String.t(),
          (binary() -> {:ok, iodata()} | {:error, String.t()}),
          keyword()
        ) :: :ok | {:error, reason() | String.t()}
  def update(root, path, fun, opts \\ []) when is_function(fun, 1) do
    with {:ok, target} <- target(root, path),
         {:ok, current} <- current(target, Keyword.get(opts, :missing, :error)),
         {:ok, replacement} <- fun.(current) do
      write(target, replacement)
    end
  end

  @doc "The content of a confined file; `{:error, :enoent}` when it is not there."
  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, reason()}
  def read(root, path) do
    with {:ok, target} <- target(root, path), do: File.read(target)
  end

  @doc "Removes a confined file. Already gone is success."
  @spec remove(String.t(), String.t()) :: :ok | {:error, reason()}
  def remove(root, path) do
    with {:ok, target} <- target(root, path) do
      case File.rm(target) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "A reason as a sentence, for a tool result or a flash."
  @spec format_error(reason() | String.t()) :: String.t()
  def format_error(:outside_root), do: "path is outside the allowed root"
  def format_error(:symlink_cycle), do: "the path links to itself"
  def format_error(:not_regular), do: "not a regular file"
  def format_error(reason) when is_binary(reason), do: reason

  def format_error(reason) when is_atom(reason),
    do: reason |> :file.format_error() |> to_string()

  def format_error(reason), do: inspect(reason)

  ## ------------------------------------------------------------------ private

  defp current(target, missing) do
    case File.read(target) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} when missing == :empty -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write(target, data) do
    dir = Path.dirname(target)

    with :ok <- File.mkdir_p(dir),
         {:ok, temp} <- open_temp(dir, Path.basename(target)) do
      try do
        with :ok <- fill(temp, data),
             :ok <- File.chmod(temp.path, mode(target)),
             :ok <- File.rename(temp.path, target) do
          :ok
        end
      after
        # Only ever this invocation's own temp: another one's is not ours to
        # judge stale.
        File.rm(temp.path)
      end
    end
  end

  defp open_temp(dir, basename, attempt \\ 0) do
    path = Path.join(dir, ".#{basename}.swarm-code-#{System.unique_integer([:positive])}.tmp")

    case File.open(path, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        File.chmod(path, @temp_mode)
        {:ok, %{path: path, io: io}}

      {:error, :eexist} when attempt < 5 ->
        open_temp(dir, basename, attempt + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fill(temp, data) do
    with :ok <- IO.binwrite(temp.io, data),
         :ok <- :file.sync(temp.io) do
      :ok
    end
  after
    File.close(temp.io)
  end

  # A file that is already there keeps its permissions; a new one is the
  # user's own.
  defp mode(target) do
    case File.stat(target) do
      {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o7777)
      _other -> @temp_mode
    end
  end
end
