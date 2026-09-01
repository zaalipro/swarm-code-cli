alias SwarmCode.Daemon.CrossAppLease
alias SwarmCode.Daemon.Platform.ProcessIdentity
alias SwarmCode.Daemon.StartupError

for application <- [:crypto, :jason, :exqlite] do
  {:ok, _started} = Application.ensure_all_started(application)
end

false = Node.alive?()
[encoded_opts] = System.argv()
{:ok, opts_json} = Base.url_decode64(encoded_opts, padding: false)
{:ok, opts} = Jason.decode(opts_json)
pid = System.pid() |> String.to_integer()

identity = %ProcessIdentity{
  uid: Map.fetch!(opts, "uid"),
  pid: pid,
  process_start_id: "lease-probe:#{pid}",
  boot_id: "lease-probe-test"
}

lease_opts = [
  lease_path: Map.fetch!(opts, "lease_path"),
  owner_path: Map.fetch!(opts, "owner_path"),
  identity: identity,
  database_fingerprint: Map.fetch!(opts, "database_fingerprint"),
  schema_contract: %{
    epoch: Map.fetch!(opts, "schema_epoch"),
    newest_migration: Map.fetch!(opts, "newest_migration"),
    manifest_sha256: Map.fetch!(opts, "manifest_sha256")
  },
  socket_path: Map.fetch!(opts, "socket_path"),
  app_version: Map.fetch!(opts, "app_version")
]

IO.puts("READY #{pid}")

case IO.gets("") do
  "GO\n" ->
    case CrossAppLease.start_link(lease_opts) do
      {:ok, lease} ->
        IO.puts("ACQUIRED")

        try do
          case IO.gets("") do
            "STOP\n" -> :ok
            other -> raise "expected STOP, got: #{inspect(other)}"
          end
        after
          GenServer.stop(lease)
        end

      {:error, %StartupError{code: :data_lease_held}} ->
        IO.puts("HELD")

      {:error, %StartupError{} = error} ->
        raise "lease probe failed: #{inspect(error)}"
    end

  other ->
    raise "expected GO, got: #{inspect(other)}"
end
