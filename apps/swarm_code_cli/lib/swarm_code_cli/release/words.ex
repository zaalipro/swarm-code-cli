defmodule SwarmCodeCLI.Release.Words do
  @moduledoc """
  pass 77 C-ARCH-14: the sentences of a session that could not start. Each
  function turns a reason (a `StartupError`, a storage refusal, a session
  reason) into the `failure` map `Release.PersistedSession` prints: exit
  status, one sentence, one action, and the typed code or reason
  `Release.Reasons` turns into the `reason` word of `-p --json`.

  The words live here, apart from the session's storage-open sequence, so that
  the sentences and the code that opens storage change on their own. Nothing
  here starts a process or writes a file; the lease owner record is read only
  to name the holder (`PersistedSession.lease_holder/1`).
  """

  # The daemon app is not a compile-time dependency of this one.
  @compile {:no_warn_undefined,
            [
              SwarmCode.Daemon.Schema.Refusal,
              SwarmCode.Daemon.StartupError
            ]}
  require Logger
  alias SwarmCodeCLI.Release.PersistedSession

  @exit_failure 1
  @exit_usage 2
  @exit_refused 3

  @provider_setup_words "Add a model provider to start: pick a preset, paste its key."

  @doc false
  # `reason` is an atom written at the call site (see `Release.Reasons`).
  @spec failure(1..3, String.t(), String.t(), atom() | nil) :: PersistedSession.failure()
  def failure(status, message, action, reason \\ nil) do
    failure = %{status: status, message: message, action: action}
    if reason, do: Map.put(failure, :reason, reason), else: failure
  end

  @doc false
  # cli020 B12/B13: the notice the interactive TUI opens Providers with.
  @spec setup_words(atom()) :: String.t()
  def setup_words(:provider_required), do: @provider_setup_words

  def setup_words(reason),
    do: session_failure(reason, nil).message <> " " <> @provider_setup_words

  @doc false
  # The failure a storage start refusal becomes: a typed `StartupError` (its
  # code picks the words) or any other reason `RepoLauncher` reports.
  @spec startup_failure(term(), term()) :: PersistedSession.failure()
  def startup_failure(%{__struct__: SwarmCode.Daemon.StartupError} = error, boot) do
    Logger.error("startup refused: #{error.code}: #{error.message} #{error.action}")
    {message, action} = startup_words(error.code, error, boot)
    # pass74 S1-14: `ncode config` answers a held lease with its own words.
    failure = @exit_refused |> failure(message, action) |> Map.put(:code, error.code)
    if error.cause, do: Map.put(failure, :cause, error.cause), else: failure
  end

  def startup_failure(reason, _boot) do
    Logger.error("guarded storage did not start: #{inspect(reason)}")
    {message, action} = storage_words(reason)
    failure(@exit_refused, message, action, storage_reason(reason))
  end

  @doc false
  # The words a schema refusal is said with, for the regression tests.
  def schema_words(%{code: :schema_incompatible} = error),
    do: startup_words(:schema_incompatible, error, nil)

  defp startup_words(:desktop_active, _error, _boot),
    do:
      {"The ncode app is open, and only one of them can use your conversations at a time.",
       "Quit the ncode app, then run ncode again."}

  defp startup_words(:data_lease_held, _error, boot) do
    if PersistedSession.settings_only?(),
      do: {PersistedSession.lease_words(boot, :settings), ""},
      else:
        {PersistedSession.lease_holder(boot),
         "Close it first (Ctrl-C twice, and once more if it asks), then run ncode again."}
  end

  # The allowlist's two refusals (pass70 D2: an upgrade only the app makes, a
  # database from a newer app), the gate's stray-file and damaged-file ones
  # (Q13) and the mode refusal (cli020 fix S4) already say what to do; any
  # other schema failure gets the general sentence.
  defp startup_words(:schema_incompatible, error, _boot) do
    refusals = [
      SwarmCode.Daemon.Schema.Refusal.desktop_upgrade_required(),
      SwarmCode.Daemon.Schema.Refusal.database_ahead(),
      SwarmCode.Daemon.Schema.Refusal.not_a_database(),
      SwarmCode.Daemon.Schema.Refusal.damaged(),
      # cli020 fix S4: one sentence, the path travels in the action.
      SwarmCode.Daemon.Schema.Refusal.database_mode("")
    ]

    if Enum.any?(refusals, &(&1.message == error.message)),
      do: {error.message, error.action},
      else:
        {"Your conversations database comes from an ncode version this ncode does not know.",
         "Update ncode, or open the ncode app once to upgrade the database. Nothing was changed."}
  end

  defp startup_words(code, _error, _boot)
       when code in [:private_directory_failed, :path_resolution_failed, :lease_failed],
       do:
         {"ncode could not safely open its private data folder.",
          "Check that ~/Library/Application Support/SwarmCode belongs to you and has mode 0700."}

  defp startup_words(:macos_platform_helper_unavailable, _error, _boot),
    do:
      {"ncode could not check whether the ncode app is running.",
       "Reinstall ncode: curl -fsSL https://code.llmotions.com/install.sh | sh"}

  defp startup_words(code, _error, _boot) when code in [:backup_failed, :backup_unverified],
    do:
      {"ncode could not make a verified backup before upgrading the database, so it changed nothing.",
       "Free some disk space and run ncode again."}

  defp startup_words(_code, error, _boot), do: {error.message, error.action}

  defp storage_words(reason) when reason in [:migration_failed, :migration_timeout],
    do:
      {"ncode could not upgrade the database; it was left as it was.",
       "Your verified backup is in the backups folder beside your conversations database. Open the ncode app, or report this."}

  defp storage_words(_reason),
    do:
      {"ncode could not open your conversations database.",
       "Close other ncode windows and run ncode again."}

  defp storage_reason(reason) when reason in [:migration_failed, :migration_timeout],
    do: :migration_failed

  defp storage_reason(_reason), do: :database_unavailable

  @doc false
  # pass74 S1-13 (D11): the exit-3 words name the settings command. The failure
  # a session reason (`SessionConfiguration.prepare/2`, `open_session/3`)
  # becomes.
  @spec session_failure(atom(), term()) :: PersistedSession.failure()
  def session_failure(:provider_required, _),
    do:
      failure(
        @exit_refused,
        "No model provider is set up yet.",
        "Run 'ncode settings providers' to add one, or set NCODE_MODEL, NCODE_BASE_URL and NCODE_API_KEY in ~/.secrets (the older SWARM_* names still work)."
      )
      |> Map.put(:reason, :provider_required)

  # cli020 B13 (onboarding-4): a first run from the environment that lacks
  # an endpoint or a model says which.
  def session_failure(:endpoint_required, _),
    do:
      failure(
        @exit_refused,
        "NCODE_BASE_URL is missing (OpenAI-compatible URLs end in /v1).",
        "Set NCODE_BASE_URL, or run 'ncode settings providers'."
      )
      |> Map.put(:reason, :endpoint_required)

  def session_failure(:model_required, _),
    do:
      failure(
        @exit_refused,
        "NCODE_MODEL is missing.",
        "Set NCODE_MODEL to a model of your provider, or run 'ncode settings providers'."
      )
      |> Map.put(:reason, :model_required)

  # pass71 F19 (review R17): the sentence names the model that was given.
  def session_failure(:unknown_model, _),
    do:
      failure(
        @exit_usage,
        PersistedSession.unknown_model_words(System.get_env("SWARM_MODEL_OVERRIDE")),
        "Use a model from /model, or provider/model.",
        :unknown_model
      )

  def session_failure(:conversation_not_found, _),
    do:
      failure(
        @exit_usage,
        "That conversation is not part of this project.",
        "Use ncode --continue, or --resume with an id from this project.",
        :conversation_not_found
      )

  def session_failure(:invalid_project, _),
    do:
      failure(
        @exit_usage,
        "That project directory cannot be opened.",
        "Name a readable directory.",
        :invalid_project
      )

  def session_failure(reason, _selection) do
    Logger.error("session could not be prepared: #{inspect(reason)}")

    failure(
      @exit_failure,
      "ncode could not open the conversation.",
      "Run ncode again; nothing was changed."
    )
  end
end
