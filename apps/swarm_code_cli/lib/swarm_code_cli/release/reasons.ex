defmodule SwarmCodeCLI.Release.Reasons do
  @moduledoc """
  The `reason` of a `-p --json` or `--output-format stream-json` summary: one
  stable snake_case word that says why a refusal or failure happened, so a
  script does not read the sentence (sentences may be reworded; these words
  are a contract, listed in the README and AGENTS.md). It is `null` when the
  session ended well. Exit codes and sentences are not touched here.

  A word comes from a fixed table keyed by an atom written in this code: a
  `StartupError` code, a session failure's `:reason`, a run's state, or a
  stop kind the one-shot names. Nothing is read from a sentence, and a key
  the table does not know falls back to `usage` (exit 2), `startup_failed`
  (before the run) or `run_failed` (a run), so no input can make an atom or
  a made-up word.
  """

  @table %{
    # Startup refusals: the `StartupError` codes of the data gate.
    data_lease_held: "data_lease_held",
    desktop_active: "desktop_open",
    schema_incompatible: "schema_incompatible",
    database_mode: "database_mode",
    private_directory_failed: "data_folder_unsafe",
    path_resolution_failed: "data_folder_unsafe",
    lease_failed: "data_folder_unsafe",
    macos_platform_helper_unavailable: "desktop_check_failed",
    backup_failed: "backup_failed",
    backup_unverified: "backup_failed",
    migration_failed: "migration_failed",
    migration_timeout: "migration_failed",
    database_unavailable: "database_unavailable",
    # The session could not be prepared.
    provider_required: "no_provider",
    endpoint_required: "no_endpoint",
    model_required: "no_model",
    untrusted_approval: "untrusted_approval",
    unknown_model: "unknown_model",
    conversation_not_found: "conversation_not_found",
    conversation_ambiguous: "conversation_ambiguous",
    invalid_project: "invalid_project",
    usage: "usage",
    startup_failed: "startup_failed",
    unexpected_error: "unexpected_error",
    # The session broke, or the prompt never became a run.
    session_unavailable: "session_unavailable",
    session_closed: "session_closed",
    conversation_busy: "conversation_busy",
    prompt_not_sent: "prompt_not_sent",
    run_not_started: "run_not_started",
    answer_incomplete: "answer_incomplete",
    output_not_written: "output_not_written",
    # How a run ended, or why this process stopped it.
    run_failed: "run_failed",
    run_stopped: "run_stopped",
    run_interrupted: "run_interrupted",
    run_paused: "run_paused",
    paused_workflow: "paused_workflow",
    max_turns: "max_turns",
    max_budget: "max_budget",
    denied: "denied",
    approval_required: "approval_required",
    question_asked: "question_asked",
    sigterm: "sigterm",
    sighup: "sighup"
  }

  @doc "Every `reason` word, sorted (the README and AGENTS.md list exactly these)."
  @spec all() :: [String.t()]
  def all, do: @table |> Map.values() |> Enum.uniq() |> Enum.sort()

  @doc """
  The word for a key written in the code (`get(:max_turns)`). A key the table
  does not list raises, so a typo fails a test and never reaches a script.
  """
  @spec get(atom()) :: String.t()
  def get(key) when is_atom(key), do: Map.fetch!(@table, key)

  @doc """
  The word for a startup failure map: `Release.PersistedSession`'s
  `%{status:, message:, action:}` plus the optional `:code` of a
  `StartupError` and `:reason` of a session failure (`:reason` is the more
  specific). The schema refusals share one code, so the `StartupError`'s typed
  `:cause` (`:database_mode`) tells the mode refusal apart; its sentence is
  never read. Anything unlisted is `usage` for exit 2 and `startup_failed`
  otherwise.
  """
  @spec for_failure(term()) :: String.t()
  def for_failure(%{code: :schema_incompatible, cause: :database_mode}),
    do: get(:database_mode)

  def for_failure(failure) when is_map(failure) do
    listed(Map.get(failure, :reason)) || listed(Map.get(failure, :code)) ||
      by_status(Map.get(failure, :status))
  end

  def for_failure(_failure), do: get(:startup_failed)

  @doc """
  The word for the run that speaks for a session (the first that did not
  finish). `stop` is the word recorded when this process stopped the run
  itself (a limit, a question, an approval nobody can answer); it says more
  than the run's own `stopped` state. A workflow parked by the provider or
  by hand is `paused_workflow`.
  """
  @spec for_run(term(), String.t() | nil) :: String.t()
  def for_run(run, stop \\ nil)
  def for_run(%{state: :stopped}, stop) when is_binary(stop), do: stop
  def for_run(%{state: :stopped}, _stop), do: get(:run_stopped)
  def for_run(%{state: :interrupted}, _stop), do: get(:run_interrupted)
  def for_run(%{state: :paused, kind: :workflow}, _stop), do: get(:paused_workflow)
  def for_run(%{state: :paused}, _stop), do: get(:run_paused)
  def for_run(_run, _stop), do: get(:run_failed)

  defp listed(key) when is_atom(key) and key != nil, do: Map.get(@table, key)
  defp listed(_key), do: nil

  defp by_status(2), do: get(:usage)
  defp by_status(_status), do: get(:startup_failed)
end
