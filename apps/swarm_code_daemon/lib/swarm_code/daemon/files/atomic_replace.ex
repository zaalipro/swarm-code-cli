defmodule SwarmCode.Daemon.Files.AtomicReplace do
  @moduledoc false

  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, term()}
  def write(path, contents, opts \\ []) do
    mode = Keyword.get(opts, :mode, 0o600)
    directory = Path.dirname(path)
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    temp = Path.join(directory, ".#{Path.basename(path)}.tmp.#{nonce}")

    publish = Keyword.get(opts, :publish, &publish/3)
    cleanup_temp = Keyword.get(opts, :cleanup_temp, &remove_temp/1)
    sync_directory = Keyword.get(opts, :sync_directory, &sync_directory/1)

    case write_and_sync_temp(temp, contents, mode) do
      :ok ->
        case invoke(publish, [temp, path, Keyword.get(opts, :replace, true)]) do
          :ok ->
            finish_published(temp, directory, cleanup_temp, sync_directory)

          {:error, reason} ->
            _ = cleanup_owned_temp(temp, cleanup_temp)
            {:error, {:pre_publication, reason}}
        end

      {:error, reason} ->
        _ = cleanup_owned_temp(temp, cleanup_temp)
        {:error, {:pre_publication, reason}}
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

  defp publish(temp, path, false), do: File.ln(temp, path)

  defp finish_published(temp, directory, cleanup_temp, sync_directory) do
    cleanup_result = cleanup_owned_temp(temp, cleanup_temp)
    sync_result = invoke(sync_directory, [directory])

    case {cleanup_result, sync_result} do
      {:ok, :ok} -> :ok
      {{:error, reason}, _sync_result} -> {:error, {:post_publication, reason}}
      {:ok, {:error, reason}} -> {:error, {:post_publication, reason}}
    end
  end

  defp cleanup_owned_temp(temp, cleanup_temp) do
    result = invoke(cleanup_temp, [temp])
    _ = remove_temp(temp)
    result
  end

  defp remove_temp(temp) do
    case File.rm(temp) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp invoke(function, arguments) do
    try do
      case apply(function, arguments) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:invalid_callback_result, other}}
      end
    rescue
      error -> {:error, {:exception, error}}
    catch
      kind, reason -> {:error, {kind, reason}}
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
