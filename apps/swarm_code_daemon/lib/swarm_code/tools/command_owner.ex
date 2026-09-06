defmodule SwarmCode.Tools.CommandOwner do
  @moduledoc """
  Opens the native POSIX command guardian as a Port owned by the requesting task.

  Port closure is the cancellation capability: even untrappable requester death
  closes the guardian's stdin. The guardian remains outside the shell's process
  group and kills that group before reporting a result. No PID lookup or detached
  cleanup task is needed. Deliberate setsid/setpgid escape is not a sandbox boundary.
  """

  def run(helper, command, timeout, root, environment, collect) do
    port =
      Port.open({:spawn_executable, helper}, [
        :binary,
        :exit_status,
        :use_stdio,
        {:packet, 4},
        {:args, [Integer.to_string(timeout), command]},
        {:cd, String.to_charlist(root)},
        {:env, environment}
      ])

    try do
      collect.(port)
    after
      close(port)
    end
  end

  defp close(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
