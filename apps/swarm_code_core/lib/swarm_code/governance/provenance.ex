defmodule SwarmCode.Governance.Provenance do
  @moduledoc false

  @baseline "dbb8804b3d7293178e571fa7afdf6bd47d06a51c"
  @classifications ~w(source test spec)

  @spec verify(Path.t()) :: :ok | {:error, [String.t()]}
  def verify(root) do
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

  defp policy_errors(policy) do
    []
    |> add(policy["version"] != 1, "source policy version must be 1")
    |> add(policy["audit_baseline"] != @baseline, "audit baseline is not pinned")
    |> add(
      policy["authorization_status"] not in ~w(pending authorized clean_room),
      "invalid authorization status"
    )
    |> add(
      policy["authorization_status"] == "authorized" and
        not Enum.all?(
          ~w(public_source_copying_allowed copyright_terms_recorded license_terms_recorded notice_terms_recorded),
          &policy[&1]
        ),
      "authorized extraction requires copying, copyright, license, and NOTICE records"
    )
  end

  defp authorization_file_errors(root, %{"authorization_status" => "authorized"}) do
    for file <- ~w(LICENSE NOTICE SOURCE_AUTHORIZATION.md),
        not File.regular?(Path.join(root, file)),
        do: "authorized extraction requires root #{file}"
  end

  defp authorization_file_errors(_root, _policy), do: []

  defp ledger_errors(root, policy, %{"version" => 1, "entries" => entries})
       when is_list(entries) do
    pending =
      if policy["authorization_status"] == "pending" and entries != [],
        do: ["source extraction is blocked while authorization is pending"],
        else: []

    pending ++ Enum.flat_map(entries, &entry_errors(root, &1))
  end

  defp ledger_errors(_root, _policy, _ledger),
    do: ["extracted-files ledger has an invalid shape"]

  defp entry_errors(root, entry) do
    destination = entry["destination"]
    path = destination_path(root, destination)
    regular? = is_binary(path) and match?({:ok, %{type: :regular}}, File.lstat(path))
    actual = if regular?, do: sha256_file(path), else: nil

    []
    |> add(is_nil(path), "unconfined provenance destination")
    |> add(entry["upstream_commit"] != @baseline, "entry is not pinned to the audit baseline")
    |> add(entry["classification"] not in @classifications, "invalid provenance classification")
    |> add(
      not is_nil(path) and not regular?,
      "provenance destination is missing or not regular"
    )
    |> add(actual != nil and actual != entry["sha256"], "sha256 mismatch for #{destination}")
  end

  defp destination_path(root, destination) when is_binary(destination) and destination != "" do
    segments = Path.split(destination)

    if Path.type(destination) == :relative and ".." not in segments do
      Path.expand(destination, root)
    end
  end

  defp destination_path(_root, _destination), do: nil

  defp sha256_file(path) do
    path
    |> File.stream!([], 1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, ctx ->
      :crypto.hash_update(ctx, chunk)
    end)
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp read_json(path) do
    with {:ok, bytes} <- File.read(path), {:ok, value} <- Jason.decode(bytes) do
      {:ok, value}
    else
      _ -> {:error, "cannot read valid JSON from #{path}"}
    end
  end

  defp add(errors, true, message), do: errors ++ [message]
  defp add(errors, false, _message), do: errors
end
