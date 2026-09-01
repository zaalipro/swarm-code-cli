defmodule SwarmCode.Daemon.Platform.DatabaseFingerprint do
  @moduledoc false

  alias SwarmCode.Daemon.Platform.PhysicalPath

  @prefix "sqlite-file-v1:"

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

  @spec verify_resolved(Path.t(), String.t()) :: :ok | {:error, term()}
  def verify_resolved(path, expected_fingerprint)
      when is_binary(path) and is_binary(expected_fingerprint) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular} = stat} ->
        if fingerprint(path, stat) == expected_fingerprint,
          do: :ok,
          else: {:error, :database_fingerprint_changed}

      _other ->
        {:error, :database_fingerprint_changed}
    end
  end

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
end
