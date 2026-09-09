defmodule SwarmCode.Domain.Tools.RunCommand do
  @moduledoc "Runs a shell command in the project root with streamed detail, a hard timeout and bounded output."
  @behaviour SwarmCode.Domain.Tools.Tool

  @impl true
  def name, do: "run_command"

  @impl true
  # Spec 54 §5 (54c H9): closed stdin and head/tail truncation are both real and
  # both were undocumented.
  def description,
    do:
      "Run a shell command with /bin/sh -c in the project root and return its exit code with " <>
        "its combined stdout and stderr. stdin is closed, so a command that waits for input " <>
        "(an editor, an interactive prompt, a bare git commit) gets EOF rather than hanging. " <>
        "Output over 20 000 characters comes back as its head and tail with the middle marked " <>
        "as truncated, so pipe long output through a filter rather than dumping it. The " <>
        "command runs to the timeout configured in Settings and is killed, with its whole " <>
        "process tree, when it expires or the agent is stopped."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{
          "type" => "string",
          "description" => "Shell command to run with /bin/sh -c"
        },
        "timeout_ms" => %{
          "type" => "integer",
          "description" =>
            "Optional timeout in milliseconds. Only used when it is LONGER than the " <>
              "configured command timeout (Settings → Limits); shorter values are ignored. " <>
              "Maximum 600000."
        }
      },
      "required" => ["command"]
    }
  end

  @impl true
  def permission(_args), do: :execute

  @impl true
  def title(args), do: "run: " <> String.slice(to_string(args["command"] || ""), 0, 60)

  @doc """
  The timeout of one call, in milliseconds (spec 07 §10).

  `settings.command_timeout_ms` is the floor, not a suggestion: models routinely
  ask for `timeout_ms: 30000` and that — not any hard-coded value — is what
  produced `command timed out after 30000 ms`. A model may still *raise* the
  timeout for something it knows is slow, up to the 600 s hard cap.
  """
  @spec timeout_for(map(), map()) :: {pos_integer(), pos_integer()}
  def timeout_for(args, ctx) do
    configured =
      (Map.get(ctx, :settings) && Map.get(ctx.settings, :command_timeout_ms)) || 120_000

    asked = args["timeout_ms"]
    asked = if is_integer(asked) and asked > 0, do: asked, else: 0

    {min(max(asked, configured), 600_000), configured}
  end

  @impl true
  def run(args, ctx, progress) do
    command = args["command"]
    {timeout, configured} = timeout_for(args, ctx)

    # When the agent (and therefore this op task) is stopped, the supervisor sends us an
    # exit signal; trapping it lets us kill the OS process instead of leaking it.
    Process.flag(:trap_exit, true)

    # Spec 51 §7.3 (R18): the port's stdin is a pipe nobody ever writes to, so
    # `cat`, `git commit` without `-m`, `python`, `npm init`, `ssh` and `sudo`
    # sat `running` for the whole timeout waiting for input that never came.
    # `exec </dev/null` gives them EOF on the first read instead.
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", "exec </dev/null\n" <> command],
        cd: String.to_charlist(ctx.project_root),
        env: clean_env()
      ])

    deadline = System.monotonic_time(:millisecond) + timeout
    progress.(nil, "running")

    case collect(port, [], deadline, progress) do
      {:ok, status, output, truncated?} ->
        progress.(100, "exit code #{status}")
        text = String.replace_invalid(output)
        text = if truncated?, do: text, else: cap(text)
        {:ok, "exit code #{status}\n" <> text}

      {:timeout, _output, _truncated?} ->
        {:error,
         "command timed out after #{timeout} ms — raise Settings → Limits → " <>
           "Command timeout (now #{configured} ms)"}
    end
  end

  # Variables the release launcher (erlexec / bin/swarm_code) sets for OUR VM. A child
  # `mix`/`elixir`/`erl` would otherwise pick up this app's embedded ERTS and crash with
  # "cannot get bootfile". `{name, false}` removes a variable from the child's environment.
  @release_env ~w(ROOTDIR BINDIR EMU PROGNAME ERTS_LIB_DIR RELEASE_ROOT RELEASE_NAME RELEASE_VSN
                  RELEASE_COOKIE RELEASE_NODE RELEASE_MODE RELEASE_BOOT_SCRIPT RELEASE_BOOT_SCRIPT_CLEAN
                  RELEASE_TMP RELEASE_DISTRIBUTION RELEASE_COMMAND RELEASE_PROG RELEASE_SYS_CONFIG
                  RELEASE_VM_ARGS RELEASE_REMOTE_VM_ARGS)

  @doc false
  def clean_env do
    # erlexec prepends $BINDIR (and $ROOTDIR/bin) to PATH for our VM. Inside a packaged
    # release those are the embedded ERTS dirs — drop them so the child finds the user's
    # own erl/elixir. In dev, ROOTDIR/bin IS the user's Erlang, so only BINDIR is dropped.
    bindir = System.get_env("BINDIR")
    rootdir = System.get_env("ROOTDIR")
    release? = System.get_env("RELEASE_ROOT") != nil
    drop = Enum.reject([bindir, if(release? and rootdir, do: rootdir <> "/bin")], &is_nil/1)

    path =
      (System.get_env("PATH") || "")
      |> String.split(":")
      |> Enum.reject(&(&1 == "" or &1 in drop))
      |> Enum.join(":")

    [
      {~c"PATH", String.to_charlist(path)},
      # Spec 51 §7.3 (R18): with stdin closed a git that wants credentials would
      # fail on a closed terminal anyway; saying so up front makes the error the
      # model reads ("could not read Username") immediate instead of timed out.
      {~c"GIT_TERMINAL_PROMPT", ~c"0"}
      | Enum.map(@release_env, &{String.to_charlist(&1), false})
    ]
  end

  # The model only ever needs the head and the tail of a long log; anything more
  # just eats the context window (and pushes runs into the turn limit).
  @cap 20_000
  @head_cap div(@cap * 3, 4)
  @tail_cap div(@cap, 4)

  # Spec 13 §11 A-6: the whole accumulator used to be re-serialised on every
  # port chunk just to find the last line — quadratic in the number of chunks,
  # and the buffer itself grew without a bound. `buf` is a rolling 4 KB tail for
  # the progress line.
  #
  # Sakana task 16: the result buffer then kept only the NEWEST chunks, so a
  # long log lost the first diagnostics — exactly what head/tail truncation
  # promises to keep. Two bounded buffers now hold the true head (15,000 bytes,
  # immutable once full) and a rolling true tail (5,000 bytes), with one marker
  # in between when anything was dropped.
  @tail_bytes 4_096
  @truncated "\n…[output truncated]\n"

  defp collect(port, _acc, deadline, progress),
    do: collect(port, new_buffers(), "", deadline, progress)

  defp new_buffers, do: %{head: [], head_size: 0, tail: "", total: 0}

  defp collect(port, buffers, tail, deadline, progress) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        chunk = IO.iodata_to_binary(data)
        tail = rolling_tail(tail, chunk)
        progress.(nil, last_line(tail))

        collect(port, push(buffers, chunk), tail, deadline, progress)

      {^port, {:exit_status, status}} ->
        {:ok, status, output(buffers), truncated?(buffers)}

      {:EXIT, ^port, _reason} ->
        collect(port, buffers, tail, deadline, progress)

      {:EXIT, _from, reason} ->
        kill(port)
        exit(reason)
    after
      remaining ->
        kill(port)
        {:timeout, output(buffers), truncated?(buffers)}
    end
  end

  defp rolling_tail(tail, chunk) do
    joined = tail <> chunk

    if byte_size(joined) > @tail_bytes,
      do: binary_part(joined, byte_size(joined) - @tail_bytes, @tail_bytes),
      else: joined
  end

  # The head fills once and never changes; everything after it rolls through the
  # tail buffer, so memory stays bounded whatever the command prints.
  defp push(buffers, chunk) do
    room = @head_cap - buffers.head_size
    take = min(room, byte_size(chunk))

    {head, head_size, rest} =
      if take > 0 do
        {[binary_part(chunk, 0, take) | buffers.head], buffers.head_size + take,
         binary_part(chunk, take, byte_size(chunk) - take)}
      else
        {buffers.head, buffers.head_size, chunk}
      end

    %{
      buffers
      | head: head,
        head_size: head_size,
        tail: roll(buffers.tail, rest),
        total: buffers.total + byte_size(chunk)
    }
  end

  defp roll(tail, ""), do: tail

  defp roll(tail, chunk) do
    joined = tail <> chunk

    if byte_size(joined) > @tail_cap,
      do: binary_part(joined, byte_size(joined) - @tail_cap, @tail_cap),
      else: joined
  end

  defp truncated?(buffers), do: buffers.total > buffers.head_size + byte_size(buffers.tail)

  defp output(buffers) do
    head = buffers.head |> Enum.reverse() |> IO.iodata_to_binary()

    if truncated?(buffers) do
      head <> @truncated <> buffers.tail
    else
      head <> buffers.tail
    end
  end

  # Sakana task 17: `kill -9 <os_pid>` reached `/bin/sh` and left everything it
  # had started running — the timeout said "stopped" while the work went on.
  defp kill(port) do
    port |> SwarmCode.Domain.OSProcess.port_pid() |> SwarmCode.Domain.OSProcess.kill_tree()

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp cap(output) do
    if String.length(output) > @cap do
      head = String.slice(output, 0, div(@cap * 3, 4))
      tail = String.slice(output, -div(@cap, 4), div(@cap, 4))
      head <> "\n…[truncated: #{String.length(output)} chars total]\n" <> tail
    else
      output
    end
  end

  defp last_line(tail) when is_binary(tail) do
    tail
    |> String.replace_invalid()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> "running"
      line -> String.slice(line, 0, 120)
    end
  end
end
