defmodule SwarmCode.Daemon.Files.AtomicReplace do
  @moduledoc false

  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(path, contents, opts \\ []) do
    mode = Keyword.get(opts, :mode, 0o600)
    directory = Path.dirname(path)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp = Path.join(directory, ".#{Path.basename(path)}.tmp.#{nonce}")

    try do
      with :ok <- write_and_sync_temp(temp, contents, mode),
           :ok <- publish(temp, path, Keyword.get(opts, :replace, true)),
           :ok <- sync_directory(directory) do
        :ok
      end
    rescue
      error -> {:error, {:exception, error}}
    catch
      kind, reason -> {:error, {kind, reason}}
    after
      _ = File.rm(temp)
    end
  end

  defp write_and_sync_temp(temp, contents, mode) do
    case File.open(temp, [:write, :binary, :exclusive]) do
      {:ok, io} ->
        result =
          try do
            with :ok <- File.chmod(temp, mode),
                 :ok <- IO.binwrite(io, contents),
                 :ok <- :file.sync(io) do
              :ok
            end
          rescue
            error -> {:error, {:exception, error}}
          catch
            kind, reason -> {:error, {kind, reason}}
          end

        close_result = File.close(io)
        prefer_operation_error(result, close_result)

      {:error, _reason} = error ->
        error
    end
  end

  defp prefer_operation_error(:ok, close_result), do: close_result
  defp prefer_operation_error(error, _close_result), do: error

  defp publish(temp, path, true), do: File.rename(temp, path)

  defp publish(temp, path, false) do
    with :ok <- File.ln(temp, path),
         :ok <- File.rm(temp) do
      :ok
    end
  end

  defp sync_directory(path) do
    case :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      {:ok, io} ->
        try do
          :file.sync(io)
        after
          _ = :file.close(io)
        end

      {:error, _reason} = error ->
        error
    end
  end
end
