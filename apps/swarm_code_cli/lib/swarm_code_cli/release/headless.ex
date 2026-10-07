defmodule SwarmCodeCLI.Release.Headless do
  @moduledoc """
  The saved session without the full-screen view: `ncode -p PROMPT` (one
  turn, then exit) and `ncode --plain` (the line presenter, for pipes, CI
  and SSH).

  Startup and close are the saved session's own
  (`Release.PersistedSession.with_saved_session/2`: log file, lease, verified
  migrations, session selection, provider resolution, boot recovery, then the
  desktop's quit). This module only adds the service, its client and the
  presenter.

  `run/2` returns the exit code: 0 done, 1 the run failed (or the session
  broke), 2 usage, 3 startup refused. Nothing here prints a stack trace:
  every failure is one line on stderr, and the answer owns stdout, so Logger
  output goes to the private log file, never to stdout.
  """
  @compile {:no_warn_undefined,
            [
              SwarmCode.Daemon.Service,
              SwarmCode.Daemon.Service.PersistedBackend,
              Ecto.UUID
            ]}

  alias SwarmCode.Daemon.Service.PersistedBackend
  alias SwarmCodeCLI.Plain.{OneShot, Options}
  alias SwarmCodeCLI.Release.PersistedSession
  alias SwarmCodeCLI.UI.DataSource.Daemon

  @type mode :: {:prompt, binary(), :text | :json} | {:plain, :text | :ndjson}

  @doc """
  Opens the saved session and runs `mode` in it.

  Options: `project_root` (default `SWARM_PROJECT_ROOT`, else the current
  directory), `conversation` (`"latest"`, `"new"` or a conversation id;
  default `SWARM_CONVERSATION`, else latest) and `model` (a session override,
  exported as `SWARM_MODEL_OVERRIDE` for the provider configuration).
  """
  @spec run(mode(), keyword()) :: 0 | 1 | 2 | 3 | 129 | 143
  def run(mode, options \\ []) do
    root = Keyword.get(options, :project_root) || System.get_env("SWARM_PROJECT_ROOT")
    root = if root in [nil, ""], do: File.cwd!(), else: root
    conversation = Keyword.get(options, :conversation) || System.get_env("SWARM_CONVERSATION")
    if model = Keyword.get(options, :model), do: System.put_env("SWARM_MODEL_OVERRIDE", model)

    open = Keyword.get(options, :with_saved_session, &PersistedSession.with_saved_session/2)

    with {:ok, selection} <- selection(conversation),
         {:ok, code} <-
           open.(
             [project_root: root, conversation: selection],
             &run_session(&1, mode, options)
           ) do
      code
    else
      {:error, failure} -> json_failure(mode, failure.message, PersistedSession.report(failure))
    end
  rescue
    error -> fail_json(mode, "ncode stopped unexpectedly (#{inspect(error.__struct__)}).")
  catch
    kind, _ -> fail_json(mode, "ncode stopped unexpectedly (#{kind}).")
  end

  @doc """
  cli020 B4: a `-p … --json` that ends before the run prints the summary
  object anyway (stdout is the script's), beside the stderr line. Returns
  `code`. Other modes print nothing.
  """
  @spec json_failure(mode() | :json | term(), String.t(), non_neg_integer()) :: non_neg_integer()
  def json_failure(mode, sentence, code)

  def json_failure(:json, sentence, code), do: print_failure(sentence, code)

  def json_failure({:prompt, _prompt, :json}, sentence, code), do: print_failure(sentence, code)

  # cli020 B23: a stream ends with the summary object whatever stopped it.
  def json_failure(:stream_json, sentence, code),
    do: print_failure(sentence, code, %{"type" => "summary"})

  def json_failure({:prompt, _prompt, :stream_json}, sentence, code),
    do: print_failure(sentence, code, %{"type" => "summary"})

  def json_failure(_mode, _sentence, code), do: code

  defp print_failure(sentence, code, extra \\ %{}) do
    if code != 0 do
      object =
        Map.merge(extra, %{
          "state" => "not_started",
          "conversation_id" => nil,
          "run_id" => nil,
          "text" => "",
          "error" => sentence,
          "question" => nil,
          "denied" => [],
          "exit_code" => code
        })

      IO.puts(Jason.encode!(object))
    end

    code
  end

  defp fail_json(mode, text), do: json_failure(mode, text, fail(text))

  # -- startup ----------------------------------------------------------------

  defp selection(value) when value in [nil, "", "latest"], do: {:ok, :latest}
  defp selection("new"), do: {:ok, :new}

  # cli020 B19: an id, an id prefix or a title; the session resolves it.
  defp selection(value) when is_binary(value), do: {:ok, value}

  # cli020 B23 + F8: `auto`/`full_access` for one run still need the user's
  # trust in the project (the engine refuses them as `:untrusted_project`).
  @untrusted_approval "--approval auto and full need a trusted project. " <>
                        "Run /trust in ncode first, or use --approval read-only."

  defp run_session(session, mode, options) do
    approval = Keyword.get(options, :approval_mode)

    if approval in ["auto", "full_access"] and not trusted?(session.project) do
      IO.puts(:stderr, "ncode: " <> @untrusted_approval)
      json_failure(mode, @untrusted_approval, 3)
    else
      start_session(session, mode, approval, options)
    end
  end

  defp trusted?(%{trusted_at: %DateTime{}}), do: true
  defp trusted?(_project), do: false

  defp start_session(session, mode, approval, options) do
    # First-run onboarding (D3) says on stderr that it wrote the provider row.
    if notice = session[:notice], do: IO.puts(:stderr, "ncode: " <> notice)
    warn_full_access(session, mode, approval)
    # cli020 B10: folders a hard exit left behind go first.
    _ = SwarmCodeCLI.Release.SocketSweep.sweep()
    {dir, stat} = private_directory()
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_all, max_restarts: 0)
    Process.unlink(supervisor)

    try do
      source_epoch = Ecto.UUID.generate()
      nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      socket = Path.join(dir, "s")

      with {:ok, backend} <-
             child(supervisor, PersistedBackend,
               mode: :persisted,
               repo: SwarmCode.Domain.Repo,
               project_root: session.project.root_path,
               project_id: session.project.id,
               conversation_id: session.conversation.id,
               source_epoch: source_epoch,
               approval_mode: approval
             ),
           {:ok, _service} <-
             child(supervisor, SwarmCode.Daemon.Service,
               socket_path: socket,
               nonce: nonce,
               source_epoch: source_epoch,
               backend: backend
             ),
           {:ok, source} <-
             child(supervisor, Daemon,
               socket_path: socket,
               nonce: nonce,
               source_epoch: source_epoch
             ) do
        present(mode, source, source_epoch, session.conversation.id,
          fail_on_denied: Keyword.get(options, :fail_on_denied, false),
          project_root: session.project.root_path,
          # cli020 B23
          max_turns: Keyword.get(options, :max_turns),
          max_budget_usd: Keyword.get(options, :max_budget_usd)
        )
      else
        _ ->
          fail_json(mode, "The saved session could not start its service.")
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 15_000)
      remove_private_directory(dir, stat)
    end
  end

  # pass71 F9 (review R6): `-p` runs with the project's approval mode, and in
  # full access nothing asks; say so once, before the turn, on stderr.
  @doc false
  def warn_full_access(session, mode, approval \\ nil)

  def warn_full_access(%{project: project}, {:prompt, _, _} = mode, approval)
      when is_binary(approval),
      do: warn_full_access(%{project: %{project | approval_mode: approval}}, mode, nil)

  def warn_full_access(%{project: %{approval_mode: "full_access"}}, {:prompt, _, _}, nil) do
    IO.puts(
      :stderr,
      "ncode: this project is in full access: commands and edits run without asking " <>
        "(/approval auto in ncode to change it)."
    )
  end

  def warn_full_access(_session, _mode, _approval), do: :ok

  defp present({:prompt, prompt, format}, source, epoch, conversation, extra) do
    OneShot.run(
      [
        data_source: source,
        source_epoch: epoch,
        conversation_id: conversation,
        prompt: prompt,
        format: format,
        progress: tty?(:stderr)
      ] ++ extra
    )
  end

  defp present({:plain, format}, source, epoch, conversation, extra) do
    {:ok, plain} =
      SwarmCodeCLI.Plain.Session.start_link(
        data_source: source,
        source_epoch: epoch,
        conversation_id: conversation,
        now: System.system_time(:millisecond),
        input: :standard_io,
        output: :standard_io,
        error: :standard_error,
        # At the end of the input the session waits for the runs it started.
        eof: :wait,
        options: %Options{format: format, banner: :saved, detached_runs?: false},
        observer: self()
      )

    Process.unlink(plain)
    monitor = Process.monitor(plain)

    receive do
      {:plain_session, ^plain, {:closed, reason}} ->
        Process.demonitor(monitor, [:flush])

        summary =
          receive do
            {:plain_session, ^plain, {:summary, summary}} -> summary
          after
            0 -> %{refused: 0, denied: 0}
          end

        plain_exit(reason, summary, Keyword.get(extra, :fail_on_denied, false))

      # cli020 B9: SIGTERM/SIGHUP detach the presenter; the session's close
      # (with_saved_session) stops the live runs.
      {:shutdown_signal, signal} when signal in [:sigterm, :sighup] ->
        _ = SwarmCodeCLI.Plain.Session.close(plain, :interrupt)
        Process.demonitor(monitor, [:flush])
        IO.puts(:stderr, "ncode: " <> SwarmCodeCLI.Release.Signals.words(signal))
        SwarmCodeCLI.Release.Signals.exit_code(signal)

      {:DOWN, ^monitor, :process, ^plain, _} ->
        fail("The plain session stopped unexpectedly.")
    end
  end

  @doc """
  cli020 B6/B3: the exit code of a `--plain` session from how it closed and
  its summary: a refused send fails a clean close, and so does a denied
  approval with `--fail-on-denied`.
  """
  @spec plain_exit(atom(), map(), boolean()) :: 0 | 1
  def plain_exit(reason, summary, fail_on_denied?) do
    code = plain_code(reason)

    cond do
      code != 0 -> code
      Map.get(summary, :refused, 0) > 0 -> 1
      fail_on_denied? and Map.get(summary, :denied, 0) > 0 -> 1
      true -> 0
    end
  end

  defp plain_code(reason) when reason in [:eof, :detach, :interrupt], do: 0
  defp plain_code(:run_failed), do: 1

  defp plain_code(:needs_input) do
    IO.puts(
      :stderr,
      "ncode: the run was waiting for an approval and was stopped when input ended. " <>
        "Answer it before closing stdin (approve or deny), or allow it with /approval auto, then rerun."
    )

    1
  end

  defp plain_code(:eof_timeout) do
    IO.puts(
      :stderr,
      "ncode: input ended and the runs were still going after 10 minutes, so they were stopped."
    )

    1
  end

  defp plain_code(reason),
    do:
      fail("The plain session closed: #{reason |> Atom.to_string() |> String.replace("_", " ")}.")

  # -- plumbing ---------------------------------------------------------------

  defp child(supervisor, module, options) do
    Supervisor.start_child(
      supervisor,
      Supervisor.child_spec({module, options}, restart: :temporary, shutdown: 10_000)
    )
  end

  defp private_directory do
    dir =
      Path.join(
        "/tmp",
        "scl-h-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    case File.mkdir(dir) do
      :ok ->
        File.chmod!(dir, 0o700)
        {dir, File.lstat!(dir)}

      {:error, :eexist} ->
        private_directory()
    end
  end

  defp remove_private_directory(dir, stat) do
    case File.lstat(dir) do
      {:ok, current}
      when current.inode == stat.inode and current.major_device == stat.major_device and
             current.type == :directory ->
        File.rm(Path.join(dir, "s"))
        File.rmdir(dir)

      _ ->
        :ok
    end
  end

  defp tty?(device) do
    :prim_tty.isatty(device) == true
  catch
    _, _ -> false
  end

  defp fail(text) do
    IO.puts(:stderr, "ncode: " <> text)
    1
  end
end
