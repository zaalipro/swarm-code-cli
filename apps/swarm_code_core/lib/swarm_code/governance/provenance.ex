defmodule SwarmCode.Governance.Provenance do
  @moduledoc false

  @baseline "dbb8804b3d7293178e571fa7afdf6bd47d06a51c"
  @authorization_flags ~w(public_source_copying_allowed copyright_terms_recorded license_terms_recorded notice_terms_recorded)
  @classifications ~w(source test spec)
  @entry_keys ~w(classification destination sha256 upstream_commit upstream_path)
  @sha256_regex ~r/\A[0-9a-f]{64}\z/

  @spec verify(Path.t()) :: :ok | {:error, [String.t()]}
  def verify(root) when is_binary(root) do
    with {:ok, policy} <- read_json(Path.join(root, "governance/source-policy.json")),
         {:ok, ledger} <- read_json(Path.join(root, "provenance/extracted-files.json")) do
      errors =
        policy_errors(policy) ++
          authorization_file_errors(root, policy) ++ ledger_errors(root, policy, ledger)

      if errors == [], do: :ok, else: {:error, errors}
    else
      {:error, message} -> {:error, [message]}
    end
  end

  def verify(_root), do: {:error, ["provenance root must be a path"]}

  defp policy_errors(policy) when is_map(policy) do
    []
    |> add(policy["version"] != 1, "source policy version must be 1")
    |> add(policy["audit_baseline"] != @baseline, "audit baseline is not pinned")
    |> add(
      policy["authorization_status"] not in ~w(pending authorized clean_room),
      "invalid authorization status"
    )
    |> add(
      policy["authorization_status"] == "authorized" and
        not Enum.all?(@authorization_flags, &(policy[&1] === true)),
      "authorized extraction requires copying, copyright, license, and NOTICE records"
    )
  end

  defp policy_errors(_policy), do: ["source policy has an invalid shape"]

  defp authorization_file_errors(root, %{"authorization_status" => "authorized"}) do
    for file <- ~w(LICENSE NOTICE SOURCE_AUTHORIZATION.md),
        not File.regular?(Path.join(root, file)),
        do: "authorized extraction requires root #{file}"
  end

  defp authorization_file_errors(_root, _policy), do: []

  defp ledger_errors(root, policy, %{"version" => 1, "entries" => entries})
       when is_list(entries) do
    pending =
      if authorization_status(policy) == "pending" and entries != [],
        do: ["source extraction is blocked while authorization is pending"],
        else: []

    pending ++ Enum.flat_map(entries, &entry_errors(root, &1))
  end

  defp ledger_errors(_root, _policy, _ledger),
    do: ["extracted-files ledger has an invalid shape"]

  defp entry_errors(root, entry) when is_map(entry) do
    if valid_entry_shape?(entry) do
      validated_entry_errors(root, entry)
    else
      ["provenance entry has an invalid shape"]
    end
  end

  defp entry_errors(_root, _entry), do: ["provenance entry has an invalid shape"]

  defp validated_entry_errors(root, entry) do
    destination = entry["destination"]
    {actual, destination_errors} = destination_digest(root, destination)
    valid_sha256? = canonical_sha256?(entry["sha256"])

    destination_errors
    |> add(
      not confined_relative_path?(entry["upstream_path"]),
      "invalid provenance upstream path"
    )
    |> add(entry["upstream_commit"] != @baseline, "entry is not pinned to the audit baseline")
    |> add(entry["classification"] not in @classifications, "invalid provenance classification")
    |> add(not valid_sha256?, "invalid provenance sha256")
    |> add(
      actual != nil and valid_sha256? and actual != entry["sha256"],
      "sha256 mismatch for #{destination}"
    )
  end

  defp valid_entry_shape?(entry) do
    Enum.sort(Map.keys(entry)) == @entry_keys and
      Enum.all?(@entry_keys, &is_binary(entry[&1]))
  end

  defp destination_digest(root, destination) do
    case destination_path(root, destination) do
      {:ok, path} ->
        case sha256_file(path) do
          {:ok, digest} -> {digest, []}
          {:error, _reason} -> {nil, ["provenance destination is missing or not regular"]}
        end

      {:error, :unconfined} ->
        {nil, ["unconfined provenance destination"]}

      {:error, :not_regular} ->
        {nil, ["provenance destination is missing or not regular"]}
    end
  end

  defp destination_path(root, destination) do
    with {:ok, segments} <- confined_relative_segments(destination),
         expanded_root = Path.expand(root),
         path = Path.absname(destination, expanded_root),
         true <- descendant?(path, expanded_root),
         {:ok, regular_path} <- lstat_regular_path(expanded_root, segments) do
      {:ok, regular_path}
    else
      false -> {:error, :unconfined}
      {:error, reason} -> {:error, reason}
    end
  end

  defp confined_relative_path?(path),
    do: match?({:ok, _segments}, confined_relative_segments(path))

  defp confined_relative_segments(path) when is_binary(path) and path != "" do
    segments = Path.split(path)

    if Path.type(path) == :relative and segments not in [[], ["."]] and
         ".." not in segments and not tilde_path?(segments) do
      {:ok, segments}
    else
      {:error, :unconfined}
    end
  end

  defp confined_relative_segments(_path), do: {:error, :unconfined}

  defp tilde_path?([first | _segments]), do: String.starts_with?(first, "~")
  defp tilde_path?([]), do: false

  defp descendant?(path, root) do
    prefix = if root == Path.rootname(root), do: root, else: root <> "/"
    path != root and String.starts_with?(path, prefix)
  end

  defp lstat_regular_path(root, segments) do
    last_index = length(segments) - 1

    segments
    |> Enum.with_index()
    |> Enum.reduce_while(root, fn {segment, index}, parent ->
      path = Path.join(parent, segment)

      case File.lstat(path) do
        {:ok, %{type: :regular}} when index == last_index -> {:halt, {:ok, path}}
        {:ok, %{type: :directory}} when index < last_index -> {:cont, path}
        _other -> {:halt, {:error, :not_regular}}
      end
    end)
    |> case do
      {:ok, path} -> {:ok, path}
      {:error, :not_regular} -> {:error, :not_regular}
      _path -> {:error, :not_regular}
    end
  end

  defp canonical_sha256?(digest), do: Regex.match?(@sha256_regex, digest)

  defp authorization_status(policy) when is_map(policy), do: policy["authorization_status"]
  defp authorization_status(_policy), do: nil

  defp sha256_file(path) do
    with {:ok, expected} <- File.lstat(path),
         {:ok, digest} <- bounded_worker(path, expected, :digest, 64 * 1_024 * 1_024) do
      {:ok, digest}
    else
      _other -> {:error, :read_failed}
    end
  end

  defp read_json(path) do
    with {:ok, expected} <- File.lstat(path),
         {:ok, bytes} <- bounded_worker(path, expected, :read, 1_048_576),
         {:ok, value} <- Jason.decode(bytes) do
      {:ok, value}
    else
      _other -> {:error, "cannot read valid JSON from #{path}"}
    end
  end

  defp bounded_worker(path, expected, operation, maximum) do
    parent = self()
    ref = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result = bounded_file_operation(path, expected, operation, maximum)
        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :read_failed}
    after
      1_000 ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        after
          1_000 -> :ok
        end

        {:error, :read_timeout}
    end
  end

  defp bounded_file_operation(path, expected, :read, maximum) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]),
         {:ok, actual} <- :file.read_file_info(io),
         true <- same_object?(actual, expected) do
      try do
        case IO.binread(io, maximum + 1) do
          bytes when is_binary(bytes) and byte_size(bytes) <= maximum -> {:ok, bytes}
          :eof -> {:ok, <<>>}
          _other -> {:error, :read_failed}
        end
      after
        _ = File.close(io)
      end
    else
      _other -> {:error, :read_failed}
    end
  rescue
    _error -> {:error, :read_failed}
  catch
    _kind, _reason -> {:error, :read_failed}
  end

  defp bounded_file_operation(path, expected, :digest, maximum) do
    with {:ok, io} <- File.open(path, [:read, :binary, :raw]),
         {:ok, actual} <- :file.read_file_info(io),
         true <- same_object?(actual, expected) do
      try do
        hash_digest(io, :crypto.hash_init(:sha256), 0, maximum)
      after
        _ = File.close(io)
      end
    else
      _other -> {:error, :read_failed}
    end
  rescue
    _error -> {:error, :read_failed}
  catch
    _kind, _reason -> {:error, :read_failed}
  end

  defp hash_digest(io, context, total, maximum) do
    case IO.binread(io, 64 * 1_024) do
      :eof ->
        {:ok, context |> :crypto.hash_final() |> Base.encode16(case: :lower)}

      bytes when is_binary(bytes) ->
        next = total + byte_size(bytes)

        if next > maximum,
          do: {:error, :read_too_large},
          else: hash_digest(io, :crypto.hash_update(context, bytes), next, maximum)

      _other ->
        {:error, :read_failed}
    end
  end

  defp same_object?(left, right) do
    object_identity(left) == object_identity(right)
  rescue
    _error -> false
  end

  defp object_identity(%File.Stat{} = stat),
    do: {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid}

  defp object_identity(
         {:file_info, _size, type, _access, _atime, _mtime, _ctime, _mode, _links, major, minor,
          inode, uid, _gid}
       ),
       do: {type, major, minor, inode, uid}

  defp object_identity(_other), do: :invalid_object

  defp add(errors, true, message), do: errors ++ [message]
  defp add(errors, false, _message), do: errors
end
