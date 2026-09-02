defmodule SwarmCode.Daemon.Platform.DatabaseFingerprint do
  @moduledoc false

  alias SwarmCode.Daemon.Platform.PhysicalPath

  @prefix "sqlite-file-v1:"
  @absent_prefix "sqlite-absent-v1:"

  @type resolved :: %{path: Path.t(), stat: File.Stat.t(), fingerprint: String.t()}

  @spec resolve(Path.t()) :: {:ok, resolved()} | {:error, term()}
  def resolve(path) do
    with {:ok, %{path: canonical_path, stat: stat}} <- PhysicalPath.resolve_regular(path) do
      {:ok,
       %{
         path: canonical_path,
         stat: stat,
         fingerprint: fingerprint(canonical_path, stat)
       }}
    end
  end

  @spec for_path(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def for_path(path) do
    with {:ok, resolved} <- resolve(path), do: {:ok, resolved.fingerprint}
  end

  @doc "Returns the versioned fingerprint for an absent canonical database path."
  @spec for_absent_path(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def for_absent_path(path) when is_binary(path) do
    expanded = Path.expand(path)
    basename = Path.basename(expanded)

    with true <- basename not in ["", ".", ".."],
         {:ok, %{path: canonical_parent}} <-
           expanded |> Path.dirname() |> PhysicalPath.resolve_directory(),
         canonical_path <- Path.join(canonical_parent, basename),
         {:error, :enoent} <- File.lstat(canonical_path) do
      {:ok, absent_fingerprint(canonical_path)}
    else
      {:ok, _stat} -> {:error, :database_path_present}
      _other -> {:error, :database_absent_path_unavailable}
    end
  end

  def for_absent_path(_path), do: {:error, :invalid_database_path}

  @doc "Returns the versioned fingerprint for an existing regular or absent path."
  @spec for_path_or_absent(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def for_path_or_absent(path) when is_binary(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> for_path(path)
      {:error, :enoent} -> for_absent_path(path)
      {:ok, _stat} -> {:error, :database_not_regular}
      {:error, reason} -> {:error, {:database_lstat_failed, reason}}
    end
  end

  def for_path_or_absent(_path), do: {:error, :invalid_database_path}

  @doc false
  @spec for_existing_or_absent(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def for_existing_or_absent(path), do: for_path_or_absent(path)

  @spec verify_resolved(Path.t(), String.t()) :: :ok | {:error, term()}
  def verify_resolved(path, expected_fingerprint)
      when is_binary(path) and is_binary(expected_fingerprint) do
    case resolve(path) do
      {:ok, %{fingerprint: ^expected_fingerprint}} -> :ok
      _other -> {:error, :database_fingerprint_changed}
    end
  end

  @spec verify_path_or_absent(Path.t(), String.t()) :: :ok | {:error, term()}
  def verify_path_or_absent(path, expected_fingerprint)
      when is_binary(path) and is_binary(expected_fingerprint) do
    case for_path_or_absent(path) do
      {:ok, ^expected_fingerprint} -> :ok
      _other -> {:error, :database_fingerprint_changed}
    end
  end

  def verify_path_or_absent(_path, _expected_fingerprint),
    do: {:error, :database_fingerprint_changed}

  defp fingerprint(canonical_path, stat) do
    payload = [
      "swarm-code-sqlite-file-fingerprint\n",
      "version=1\n",
      "path=",
      Integer.to_string(byte_size(canonical_path)),
      ?:,
      canonical_path,
      ?\n,
      "device=",
      Integer.to_string(stat.major_device),
      ?:,
      Integer.to_string(stat.minor_device),
      ?\n,
      "inode=",
      Integer.to_string(stat.inode),
      ?\n
    ]

    digest =
      :crypto.hash(:sha256, payload)
      |> Base.encode16(case: :lower)

    @prefix <> digest
  end

  defp absent_fingerprint(canonical_path) do
    payload = [
      "swarm-code-sqlite-absent-fingerprint\n",
      "version=1\n",
      "path=",
      Integer.to_string(byte_size(canonical_path)),
      ?:,
      canonical_path,
      ?\n
    ]

    digest =
      :crypto.hash(:sha256, payload)
      |> Base.encode16(case: :lower)

    @absent_prefix <> digest
  end
end
