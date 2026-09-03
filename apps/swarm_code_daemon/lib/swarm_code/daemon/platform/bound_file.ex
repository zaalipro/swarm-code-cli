defmodule SwarmCode.Daemon.Platform.BoundFile do
  @moduledoc false

  import Bitwise

  alias Exqlite.Sqlite3

  @type identity ::
          {:regular, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer()}

  @type t :: %{path: Path.t(), io: term(), identity: identity()}

  @doc "Open a private regular file and bind the descriptor to its initial identity."
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(path, opts \\ [])

  def open(path, opts) when is_binary(path) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :read)
    expected = Keyword.get(opts, :expected)
    uid = Keyword.get(opts, :uid)
    sidecars = Keyword.get(opts, :sidecars, [])
    file_modes = if mode == :readwrite, do: [:read, :write], else: [:read]

    with {:ok, stat} <- File.lstat(path),
         :ok <- validate_stat(stat, uid),
         :ok <- expected_stat(stat, expected),
         {:ok, io} <- File.open(path, file_modes ++ [:binary, :raw]),
         {:ok, identity} <- identity(io),
         :ok <- same_object(identity, stat),
         :ok <- expected_identity(identity, expected) do
      {:ok, %{path: path, io: io, identity: identity, sidecars: sidecars}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :bound_file_changed}
    end
  rescue
    _error -> {:error, :bound_file_open_failed}
  catch
    _kind, _reason -> {:error, :bound_file_open_failed}
  end

  def open(_path, _opts), do: {:error, :bound_file_open_failed}

  @spec close(t()) :: :ok | {:error, term()}
  def close(%{io: io}) do
    case File.close(io) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :bound_file_close_failed}
  catch
    _kind, _reason -> {:error, :bound_file_close_failed}
  end

  @spec identity(term()) :: {:ok, identity()} | {:error, term()}
  def identity(io) do
    case :file.read_file_info(io) do
      {:ok,
       {:file_info, size, :regular, _access, _atime, _mtime, _ctime, mode, _links, major, minor,
        inode, uid, _gid}} ->
        {:ok, {:regular, major, minor, inode, uid, mode, size}}

      _other ->
        {:error, :bound_file_not_regular}
    end
  rescue
    _error -> {:error, :bound_file_not_regular}
  catch
    _kind, _reason -> {:error, :bound_file_not_regular}
  end

  @doc "Open SQLite through identity-pinned same-directory hard links."
  @spec open_sqlite(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open_sqlite(path, opts \\ [])

  def open_sqlite(path, opts) when is_binary(path) and is_list(opts) do
    mode = Keyword.get(opts, :mode, :readonly)
    uid = Keyword.get(opts, :uid)
    expected = Keyword.get(opts, :expected)
    sidecars = Keyword.get(opts, :sidecars, [])

    with {:ok, binding} <-
           open(
             path,
             mode: if(mode == :readwrite, do: :readwrite, else: :read),
             uid: uid,
             expected: expected
           ) do
      open_sqlite_from_binding(binding,
        mode: mode,
        sidecars: sidecars,
        uid: uid
      )
    end
  end

  def open_sqlite(_path, _opts), do: {:error, :bound_sqlite_open_failed}

  @doc false
  @spec open_sqlite_from_binding(t(), keyword()) :: {:ok, map()} | {:error, term()}
  def open_sqlite_from_binding(%{path: path, identity: identity} = binding, opts)
      when is_list(opts) do
    mode = Keyword.get(opts, :mode, :readonly)
    uid = Keyword.get(opts, :uid)
    sidecars = Keyword.get(opts, :sidecars, Map.get(binding, :sidecars, []))
    before_open = Keyword.get(opts, :before_open)

    result =
      with :ok <- invoke_hook(before_open, binding),
           :ok <- verify_path_identity(path, identity, uid),
           :ok <- verify_sidecar_set(path, sidecars, uid),
           {:ok, aliases} <- make_aliases(binding, sidecars, uid) do
        case Sqlite3.open(aliases.main.path, mode: mode) do
          {:ok, conn} ->
            case verify_alias(aliases.main.path, identity, uid) do
              :ok ->
                {:ok, %{connection: conn, binding: binding, aliases: aliases}}

              {:error, reason} ->
                _ = Sqlite3.close(conn)
                remove_aliases(aliases)
                {:error, reason}
            end

          {:error, reason} ->
            remove_aliases(aliases)
            {:error, reason}
        end
      else
        {:error, reason} -> {:error, reason}
        _other -> {:error, :bound_sqlite_open_failed}
      end

    case result do
      {:ok, _state} = success ->
        success

      {:error, _reason} = error ->
        _ = close(binding)
        error
    end
  rescue
    _error ->
      _ = close(binding)
      {:error, :bound_sqlite_open_failed}
  catch
    _kind, _reason ->
      _ = close(binding)
      {:error, :bound_sqlite_open_failed}
  end

  def open_sqlite_from_binding(_binding, _opts), do: {:error, :bound_sqlite_open_failed}

  @spec close_sqlite(map()) :: :ok
  def close_sqlite(%{connection: conn, binding: binding, aliases: aliases}) do
    _ = Sqlite3.close(conn)
    _ = close(binding)
    remove_aliases(aliases)
    :ok
  rescue
    _error ->
      remove_aliases(aliases)
      :ok
  catch
    _kind, _reason ->
      remove_aliases(aliases)
      :ok
  end

  def close_sqlite(_state), do: :ok

  @doc false
  @spec same_object(term(), term()) :: :ok | {:error, term()}
  def same_object(left, right) do
    if object_identity(left) == object_identity(right),
      do: :ok,
      else: {:error, :bound_file_changed}
  end

  @doc false
  @spec object_identity(term()) :: tuple()
  def object_identity({:regular, major, minor, inode, uid, _mode, _size}),
    do: {:regular, major, minor, inode, uid}

  def object_identity({:regular, major, minor, inode, uid}),
    do: {:regular, major, minor, inode, uid}

  def object_identity(%File.Stat{} = stat),
    do: {:regular, stat.major_device, stat.minor_device, stat.inode, stat.uid}

  def object_identity(_other), do: :invalid_object

  defp validate_stat(%File.Stat{type: :regular, mode: mode, uid: actual_uid}, uid)
       when is_integer(uid) and uid >= 0 and actual_uid == uid and band(mode, 0o7777) == 0o600,
       do: :ok

  defp validate_stat(%File.Stat{type: :regular, mode: mode}, nil)
       when band(mode, 0o7777) == 0o600,
       do: :ok

  defp validate_stat(_stat, _uid), do: {:error, :unsafe_bound_file}

  defp expected_stat(_stat, nil), do: :ok
  defp expected_stat(stat, expected), do: same_object(stat, expected)

  defp expected_identity(_identity, nil), do: :ok
  defp expected_identity(identity, expected), do: same_object(identity, expected)

  defp make_aliases(binding, sidecars, uid) do
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    basename = Path.basename(binding.path)
    prefix = ".#{basename}.bound.#{nonce}"
    main_path = Path.join(Path.dirname(binding.path), prefix)

    with :ok <- link_checked(binding.path, main_path, binding.identity, uid),
         {:ok, sidecar_aliases} <-
           make_sidecar_aliases(sidecars, Path.dirname(binding.path), prefix, uid) do
      {:ok,
       %{
         main: %{path: main_path, identity: binding.identity},
         sidecars: sidecar_aliases
       }}
    else
      _other ->
        _ = remove_if_same_object(main_path, binding.identity)
        {:error, :bound_alias_failed}
    end
  end

  defp make_sidecar_aliases(sidecars, directory, prefix, uid) when is_list(sidecars) do
    Enum.reduce_while(sidecars, {:ok, []}, fn
      {suffix, path, expected}, {:ok, acc}
      when suffix in ["-wal", "-shm"] and is_binary(path) ->
        alias_path = Path.join(directory, prefix <> suffix)

        case link_checked(path, alias_path, expected, uid) do
          :ok ->
            {:cont, {:ok, [%{path: alias_path, identity: expected} | acc]}}

          {:error, reason} ->
            Enum.each(acc, &remove_if_same_object(&1.path, &1.identity))
            {:halt, {:error, reason}}
        end

      _bad, _acc ->
        {:halt, {:error, :bound_sidecar_failed}}
    end)
  end

  defp make_sidecar_aliases(_sidecars, _directory, _prefix, _uid),
    do: {:error, :bound_sidecar_failed}

  defp link_checked(source, destination, expected, uid) do
    with {:error, :enoent} <- File.lstat(destination),
         :ok <- File.ln(source, destination),
         {:ok, stat} <- File.lstat(destination),
         :ok <- validate_stat(stat, uid),
         :ok <- same_object(stat, expected) do
      :ok
    else
      {:error, :eexist} -> {:error, :bound_alias_exists}
      _other -> {:error, :bound_alias_failed}
    end
  end

  defp verify_alias(path, expected, uid) do
    with {:ok, stat} <- File.lstat(path),
         :ok <- validate_stat(stat, uid),
         :ok <- same_object(stat, expected) do
      :ok
    end
  end

  defp verify_path_identity(path, expected, uid) do
    with {:ok, stat} <- File.lstat(path),
         :ok <- validate_stat(stat, uid),
         :ok <- same_object(stat, expected) do
      :ok
    end
  end

  # Capture the complete sidecar presence set at the same effect boundary as
  # the main-file identity.  A sidecar that appears or disappears between the
  # caller's initial lstat and alias creation is a changed database, not an
  # optional detail that may be silently ignored.
  defp verify_sidecar_set(path, expected_sidecars, uid) when is_list(expected_sidecars) do
    expected =
      Map.new(expected_sidecars, fn {suffix, _sidecar_path, identity} -> {suffix, identity} end)

    Enum.reduce_while(["-wal", "-shm"], :ok, fn suffix, :ok ->
      case {Map.fetch(expected, suffix), File.lstat(path <> suffix)} do
        {{:ok, identity}, {:ok, stat}}
        when stat.type == :regular and stat.uid == uid and
               band(stat.mode, 0o7777) == 0o600 ->
          if object_identity(stat) == object_identity(identity),
            do: {:cont, :ok},
            else: {:halt, {:error, :bound_sidecar_changed}}

        {:error, {:error, :enoent}} ->
          {:cont, :ok}

        _other ->
          {:halt, {:error, :bound_sidecar_changed}}
      end
    end)
  rescue
    _error -> {:error, :bound_sidecar_changed}
  catch
    _kind, _reason -> {:error, :bound_sidecar_changed}
  end

  defp verify_sidecar_set(_path, _expected_sidecars, _uid),
    do: {:error, :bound_sidecar_changed}

  defp invoke_hook(nil, _binding), do: :ok

  defp invoke_hook(hook, binding) when is_function(hook, 1) do
    case hook.(binding) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :bound_sqlite_hook_failed}
    end
  rescue
    _error -> {:error, :bound_sqlite_hook_failed}
  catch
    _kind, _reason -> {:error, :bound_sqlite_hook_failed}
  end

  defp invoke_hook(hook, binding) when is_function(hook, 2) do
    case hook.(:before_sqlite_open, binding.path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      _other -> {:error, :bound_sqlite_hook_failed}
    end
  rescue
    _error -> {:error, :bound_sqlite_hook_failed}
  catch
    _kind, _reason -> {:error, :bound_sqlite_hook_failed}
  end

  defp invoke_hook(_hook, _binding), do: {:error, :bound_sqlite_hook_failed}

  defp remove_aliases(%{main: main, sidecars: sidecars}) do
    remove_if_same_object(main.path, main.identity)

    Enum.each(sidecars, fn sidecar ->
      remove_if_same_object(sidecar.path, sidecar.identity)
    end)
  end

  defp remove_aliases(_aliases), do: :ok

  defp remove_if_same_object(path, expected) do
    case File.lstat(path) do
      {:ok, stat} ->
        if object_identity(stat) == object_identity(expected), do: File.rm(path)
        :ok

      _other ->
        :ok
    end
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end
end
