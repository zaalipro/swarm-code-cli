defmodule SwarmCode.Domain.Repo do
  use Ecto.Repo,
    otp_app: :swarm_code_daemon,
    adapter: Ecto.Adapters.SQLite3

  @database_mode 0o600
  @fixture_build Mix.env() == :test

  @impl true
  def init(:supervisor, config) do
    case Keyword.fetch(config, :guarded_repo) do
      {:ok, {lease, generation}} when is_pid(lease) and is_reference(generation) ->
        allowed = [:guarded_repo, :name, :otp_app, :pool_size, :timeout, :telemetry_prefix]

        if Enum.all?(Keyword.keys(config), &(&1 in allowed)) and config[:name] == nil do
          SwarmCode.Daemon.CrossAppLease.admit_repo(lease, generation)
        else
          {:error, :guarded_database_required}
        end

      :error ->
        if @fixture_build and Keyword.get(config, :domain_fixture, false),
          do: fixture_config(config),
          else: {:error, :guarded_database_required}

      _ ->
        {:error, :guarded_database_required}
    end
  end

  def init(:runtime, config), do: {:ok, config}

  defp fixture_config(config) do
    case config[:database] do
      path when is_binary(path) and path not in ["", ":memory:"] ->
        ensure_database_permissions!(path)

        {:ok, Keyword.put(config, :after_connect, {__MODULE__, :secure_sidecars, [path]})}

      _ ->
        {:ok, config}
    end
  end

  @busy_attempts 5
  @busy_backoff_ms 20..150

  @doc """
  Runs `fun` and retries it when the database was busy (spec 55 T3, 55a A4/A-P2/A-P6).
  `tag` names the call site for the `:busy_write_seam`. The sleep happens outside any
  transaction: `fun` must wrap the whole transaction, never a statement inside one.
  """
  @spec retry(atom(), (-> result), pos_integer()) :: result | {:error, :database_busy}
        when result: term()
  def retry(tag, fun, attempts \\ @busy_attempts) when is_atom(tag) and is_function(fun, 0) do
    busy_seam(tag)
    fun.()
  rescue
    error ->
      cond do
        not busy_error?(error) ->
          reraise error, __STACKTRACE__

        attempts > 1 ->
          Process.sleep(Enum.random(@busy_backoff_ms))
          retry(tag, fun, attempts - 1)

        true ->
          {:error, :database_busy}
      end
  end

  @doc false
  def busy_error?(%DBConnection.ConnectionError{message: m}) do
    String.contains?(m, "connection not available") or String.contains?(m, "dropped from queue")
  end

  def busy_error?(error) do
    message = error |> Exception.message() |> String.downcase()
    String.contains?(message, "database busy") or String.contains?(message, "database is locked")
  end

  # The test seam (spec 54 §1.1, widened): an arity-1 function is called with the tag
  # before every attempt; an arity-0 function keeps its pass-48 scope, `:flush_run_writes`.
  defp busy_seam(tag) do
    case Application.get_env(:swarm_code_daemon, :busy_write_seam) do
      fun when is_function(fun, 1) -> fun.(tag)
      fun when is_function(fun, 0) and tag == :flush_run_writes -> fun.()
      _other -> :ok
    end
  end

  @doc false
  def ensure_database_permissions!(path) when is_binary(path) do
    File.mkdir_p!(Path.dirname(path))

    unless File.exists?(path) do
      temporary = path <> ".permissions-#{System.unique_integer([:positive])}"

      try do
        File.write!(temporary, "", [:exclusive, :binary])
        File.chmod!(temporary, @database_mode)

        # Linking publishes the secured inode atomically and, unlike rename,
        # cannot replace a database another simultaneous starter just made.
        case File.ln(temporary, path) do
          :ok -> :ok
          {:error, :eexist} -> :ok
          {:error, reason} -> raise File.Error, reason: reason, action: "create", path: path
        end
      after
        File.rm(temporary)
      end
    end

    chmod_existing!([path, path <> "-wal", path <> "-shm"])
    :ok
  end

  @doc false
  def secure_sidecars(_connection, path) do
    chmod_existing!([path, path <> "-wal", path <> "-shm"])
    :ok
  end

  defp chmod_existing!(paths) do
    Enum.each(paths, fn path ->
      if File.exists?(path), do: File.chmod!(path, @database_mode)
    end)
  end
end
