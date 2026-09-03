defmodule SwarmCode.Daemon.Schema.Gate do
  @moduledoc false

  alias SwarmCode.Daemon.Schema.{Binding, MigrationManifest, Probe}
  alias SwarmCode.Daemon.StartupError

  defmodule Decision do
    @moduledoc false

    alias SwarmCode.Daemon.Schema.{Binding, MigrationManifest, Probe}

    @enforce_keys [:status, :applied, :pending, :probe, :app_version]
    defstruct @enforce_keys ++ [binding: nil]

    @type t :: %__MODULE__{
            status: :ready | :migration_required | :new_database,
            applied: [pos_integer()],
            pending: [MigrationManifest.Entry.t()],
            probe: Probe.t() | nil,
            app_version: String.t(),
            binding: Binding.t() | nil
          }
  end

  @spec check(Path.t(), MigrationManifest.t(), String.t()) ::
          {:ok, Decision.t()} | {:error, StartupError.t()}
  def check(path, %MigrationManifest{} = manifest, app_version) when is_binary(path) do
    check_bound(path, manifest, app_version, [])
  end

  @doc "Run the schema gate while retaining an identity binding for handoff."
  @spec check_bound(Path.t(), MigrationManifest.t(), String.t(), keyword()) ::
          {:ok, Decision.t()} | {:error, StartupError.t()}
  def check_bound(path, %MigrationManifest{} = manifest, app_version, opts)
      when is_binary(path) and is_list(opts) do
    with :ok <- compatible_app_version(app_version, manifest.minimum_reader) do
      case File.lstat(path) do
        {:error, :enoent} ->
          if sidecars_absent?(path),
            do:
              {:ok,
               %Decision{
                 status: :new_database,
                 applied: [],
                 pending: manifest.migrations,
                 probe: nil,
                 app_version: app_version,
                 binding: nil
               }},
            else: {:error, incompatible_error()}

        {:ok, %File.Stat{type: :regular}} ->
          check_existing(path, manifest, app_version, opts)

        _other ->
          {:error, incompatible_error()}
      end
    end
  end

  @doc false
  @spec verify_binding(Path.t(), Binding.t(), non_neg_integer()) ::
          :ok | {:error, StartupError.t()}
  def verify_binding(path, %Binding{} = binding, uid) when is_binary(path) and is_integer(uid) do
    if path != binding.path do
      {:error, incompatible_error()}
    else
      case Probe.verify_bound_paths(path, binding, uid) do
        :ok -> :ok
        _other -> {:error, incompatible_error()}
      end
    end
  end

  def verify_binding(_path, _binding, _uid), do: {:error, incompatible_error()}

  defp check_existing(path, manifest, app_version, opts) do
    with {:ok, %{probe: probe, binding: binding}} <- Probe.inspect_bound(path, opts),
         :ok <- verify_integrity(probe),
         :ok <- verify_sqlite_version(probe.sqlite_version, manifest.sqlite_minimum),
         :ok <- verify_application_id(probe.application_id, manifest.application_ids),
         {:ok, pending} <- verify_prefix(probe, manifest.migrations) do
      status = if pending == [], do: :ready, else: :migration_required

      {:ok,
       %Decision{
         status: status,
         applied: probe.migration_versions,
         pending: pending,
         probe: probe,
         app_version: app_version,
         binding: binding
       }}
    end
  end

  defp sidecars_absent?(path) do
    File.lstat(path <> "-wal") == {:error, :enoent} and
      File.lstat(path <> "-shm") == {:error, :enoent}
  end

  defp compatible_app_version(app_version, minimum_reader) do
    with {:ok, app} <- Version.parse(app_version),
         {:ok, minimum} <- Version.parse(minimum_reader),
         comparison when comparison in [:eq, :gt] <- Version.compare(app, minimum) do
      :ok
    else
      _other -> {:error, incompatible_error()}
    end
  end

  defp verify_integrity(%Probe{quick_check: [["ok"]], foreign_key_violations: []}), do: :ok
  defp verify_integrity(_probe), do: {:error, incompatible_error()}

  defp verify_sqlite_version(actual, minimum) do
    with {:ok, actual_version} <- Version.parse(actual),
         {:ok, minimum_version} <- Version.parse(minimum),
         comparison when comparison in [:eq, :gt] <-
           Version.compare(actual_version, minimum_version) do
      :ok
    else
      _other -> {:error, incompatible_error()}
    end
  end

  defp verify_application_id(application_id, supported) do
    if application_id in supported, do: :ok, else: {:error, incompatible_error()}
  end

  defp verify_prefix(probe, migrations) do
    expected_versions = Enum.map(migrations, & &1.version)
    applied_count = length(probe.migration_versions)

    if probe.migration_versions == Enum.take(expected_versions, applied_count) and
         applied_count > 0 do
      applied_entry = Enum.at(migrations, applied_count - 1)

      if applied_entry && applied_entry.schema_sha256 == probe.schema_sha256 do
        {:ok, Enum.drop(migrations, applied_count)}
      else
        {:error, incompatible_error()}
      end
    else
      {:error, incompatible_error()}
    end
  end

  defp incompatible_error do
    StartupError.new(
      :schema_incompatible,
      false,
      "The canonical database is incompatible with this migration manifest.",
      "Use a supported SwarmCode version and restore only from a verified backup."
    )
  end
end
