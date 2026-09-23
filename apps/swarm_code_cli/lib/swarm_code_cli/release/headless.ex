defmodule SwarmCodeCLI.Release.Headless do
  @moduledoc """
  The saved session without the full-screen view: `swarmcode -p PROMPT` (one
  turn, then exit) and `swarmcode --plain` (the line presenter, for pipes, CI
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
  @spec run(mode(), keyword()) :: 0 | 1 | 2 | 3
  def run(mode, options \\ []) do
    root = Keyword.get(options, :project_root) || System.get_env("SWARM_PROJECT_ROOT")
    root = if root in [nil, ""], do: File.cwd!(), else: root
    conversation = Keyword.get(options, :conversation) || System.get_env("SWARM_CONVERSATION")
    if model = Keyword.get(options, :model), do: System.put_env("SWARM_MODEL_OVERRIDE", model)

    with {:ok, selection} <- selection(conversation),
         {:ok, code} <-
           PersistedSession.with_saved_session(
             [project_root: root, conversation: selection],
             &run_session(&1, mode)
           ) do
      code
    else
      {:error, failure} -> PersistedSession.report(failure)
    end
  rescue
    error -> fail("SwarmCode stopped unexpectedly (#{inspect(error.__struct__)}).")
  catch
    kind, _ -> fail("SwarmCode stopped unexpectedly (#{kind}).")
  end

  # -- startup ----------------------------------------------------------------

  defp selection(value) when value in [nil, "", "latest"], do: {:ok, :latest}
  defp selection("new"), do: {:ok, :new}

  defp selection(id) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} ->
        {:ok, id}

      _ ->
        {:error,
         %{
           status: 2,
           message: "A conversation is latest, new, or a conversation id; #{id} is none.",
           action: "Run swarmcode --help."
         }}
    end
  end

  defp run_session(session, mode) do
    # First-run onboarding (D3) says on stderr that it wrote the provider row.
    if notice = session[:notice], do: IO.puts(:stderr, "swarmcode: " <> notice)
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
               source_epoch: source_epoch
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
        present(mode, source, source_epoch, session.conversation.id)
      else
        _ -> fail("The saved session could not start its service.")
      end
    after
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, 15_000)
      remove_private_directory(dir, stat)
    end
  end

  defp present({:prompt, prompt, format}, source, epoch, conversation) do
    OneShot.run(
      data_source: source,
      source_epoch: epoch,
      conversation_id: conversation,
      prompt: prompt,
      format: format,
      progress: tty?(:stderr)
    )
  end

  defp present({:plain, format}, source, epoch, conversation) do
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
        plain_code(reason)

      {:DOWN, ^monitor, :process, ^plain, _} ->
        fail("The plain session stopped unexpectedly.")
    end
  end

  defp plain_code(reason) when reason in [:eof, :detach, :interrupt], do: 0
  defp plain_code(:run_failed), do: 1

  defp plain_code(:needs_input) do
    IO.puts(:stderr, "swarmcode: a run is waiting for an answer; open swarmcode to give it.")
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
    IO.puts(:stderr, "swarmcode: " <> text)
    1
  end
end
