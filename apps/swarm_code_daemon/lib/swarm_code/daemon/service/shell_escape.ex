defmodule SwarmCode.Daemon.Service.ShellEscape do
  @moduledoc """
  cli020 C15 (competitors-9, decision 4c): the composer's `!cmd`.

  The command the user typed runs in an owned task of the backend's task
  supervisor through the synced `SwarmCode.Domain.Tools.RunCommand.run/3`
  (scrubbed environment, the user's umask, kill-tree timeout; the settings'
  command timeout, 120 s by default). No approval and no Policy: the user
  typed it. `yield_ms` is the same 120 s, so a slow command is not handed to
  the background book after the tool's default 10 s. The task traps exits, so
  stopping it (`stop/2`, `Task.Supervisor.terminate_child/2`) kills the
  process tree.

  The backend owns the task (one per conversation) and, when it ends, persists
  the shell message `content/3` builds: `"$ " <> command <> "\\n" <> output <>
  "\\n[exit " <> code <> "]"`. `parse/1` reads one back for the transcript.
  """
  alias SwarmCode.Domain.Tools.RunCommand

  @yield_ms 120_000

  @doc "Starts `command` in a task of `supervisor`; the task answers `{output, exit}`."
  @spec start(GenServer.server(), map(), String.t()) :: Task.t()
  def start(supervisor, ctx, command) do
    Task.Supervisor.async_nolink(supervisor, fn -> run(command, ctx) end)
  end

  @doc """
  Runs `command` (in the calling process, which traps exits): `{output, exit}`
  with `exit` an integer, `"pending"` (still running in the background) or
  `"error"` (it could not run, or timed out; the output says why).
  """
  @spec run(String.t(), map()) :: {String.t(), integer() | String.t()}
  def run(command, ctx) do
    args = %{"command" => command, "yield_ms" => @yield_ms}

    case RunCommand.run(args, ctx, fn _pct, _detail -> :ok end) do
      {:ok, text} -> split(text)
      {:error, text} -> {to_string(text), "error"}
    end
  end

  # RunCommand's answer starts with `exit code N` (or `exit code pending` /
  # `exit code unknown (...)`), then the output.
  defp split(text) do
    {head, body} =
      case String.split(text, "\n", parts: 2) do
        [head, body] -> {head, body}
        [head] -> {head, ""}
      end

    exit =
      case Regex.run(~r/\Aexit code (\d+)\z/, head) do
        [_, code] -> String.to_integer(code)
        _ -> if head == "exit code pending", do: "pending", else: "error"
      end

    {String.trim_trailing(body, "\n"), exit}
  end

  @doc "Stops the command's task; the trapped exit kills its process tree."
  @spec stop(GenServer.server(), Task.t()) :: :ok
  def stop(supervisor, %Task{pid: pid, ref: ref}) do
    Process.demonitor(ref, [:flush])
    _ = Task.Supervisor.terminate_child(supervisor, pid)
    :ok
  end

  @doc "The persisted message: `$ <command>`, the output, `[exit <code>]`."
  @spec content(String.t(), String.t(), integer() | String.t() | :stopped) :: String.t()
  def content(command, output, exit) do
    code = if exit == :stopped, do: "stopped", else: to_string(exit)
    output = if output == "", do: "", else: output <> "\n"
    "$ " <> command <> "\n" <> output <> "[exit " <> code <> "]"
  end

  @doc """
  A persisted shell message read back: `%{command, output, state, exit_code}`
  (`state` `:done`, `:stopped` or `:failed`), or nil when `content` is not one.
  """
  @spec parse(String.t()) :: map() | nil
  def parse("$ " <> rest) do
    case Regex.run(~r/\A(.*)\n?\[exit ([0-9]+|stopped|error|pending)\]\z/s, rest) do
      [_, body, code] ->
        {command, output} =
          case String.split(body, "\n", parts: 2) do
            [command, output] -> {command, String.trim_trailing(output, "\n")}
            [command] -> {command, ""}
          end

        {state, exit_code} =
          case code do
            "stopped" -> {:stopped, nil}
            "error" -> {:failed, nil}
            "pending" -> {:done, nil}
            n -> {:done, String.to_integer(n)}
          end

        %{command: command, output: output, state: state, exit_code: exit_code}

      _ ->
        nil
    end
  end

  def parse(_content), do: nil

  @doc """
  `parse/1` of a message read as its first 8 KB (`head`), last 64 bytes
  (`tail`) and size: a long output keeps its exit from the tail.
  """
  @spec parse(String.t(), String.t(), non_neg_integer()) :: map() | nil
  def parse(head, _tail, bytes) when bytes <= 8192, do: parse(head)

  def parse("$ " <> rest, tail, _bytes) do
    [command | output] = String.split(rest, "\n", parts: 2)

    {state, exit_code} =
      case Regex.run(~r/\[exit ([0-9]+|stopped|error|pending)\]\z/, tail) do
        [_, "stopped"] -> {:stopped, nil}
        [_, "error"] -> {:failed, nil}
        [_, "pending"] -> {:done, nil}
        [_, n] -> {:done, String.to_integer(n)}
        _ -> {:failed, nil}
      end

    %{command: command, output: Enum.join(output), state: state, exit_code: exit_code}
  end

  def parse(_head, _tail, _bytes), do: nil
end
