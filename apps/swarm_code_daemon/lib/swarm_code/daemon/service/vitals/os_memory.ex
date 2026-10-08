defmodule SwarmCode.Daemon.Service.Vitals.OsMemory do
  @moduledoc """
  cli021 C2: what the OS says about the memory of this Erlang VM and of the
  processes it started, and how much memory the machine has.

  One `ps` reading lists every process as `pid ppid rss comm`; the VM's own
  resident size and the sum over its descendants (the terminal renderer, tool
  commands, the `ps` itself excluded) come from that table. The machine's
  memory is `sysctl -n hw.memsize` on macOS and `/proc/meminfo` on Linux. All
  of it runs in one owned task of `Vitals`, never in a callback.
  """

  # The listing is cut at 1 MiB while it is read (about 20 000 processes).
  @ps_script "ps -A -o pid=,ppid=,rss=,comm= | head -c 1048576"

  @type reading :: %{
          os_rss_bytes: non_neg_integer() | nil,
          children_rss_bytes: non_neg_integer() | nil,
          machine_bytes: non_neg_integer() | nil
        }

  @doc "Reads the table and the machine's memory; nil fields when a tool is missing."
  @spec read(keyword()) :: reading()
  def read(opts \\ []) do
    vm = Keyword.get(opts, :vm_pid, System.pid() |> String.to_integer())

    table =
      case run("sh", ["-c", @ps_script]) do
        {:ok, output} -> parse_ps(output)
        :error -> []
      end

    {own, children} = split(table, vm)

    %{
      os_rss_bytes: own,
      children_rss_bytes: if(own, do: children),
      machine_bytes: if(Keyword.get(opts, :machine, true), do: machine_bytes())
    }
  end

  @doc "Parses `ps -A -o pid=,ppid=,rss=,comm=` into `{pid, ppid, rss_kib, command}` rows."
  @spec parse_ps(binary()) :: [{integer(), integer(), integer(), String.t()}]
  def parse_ps(output) when is_binary(output) do
    for line <- String.split(output, "\n", trim: true),
        [pid, ppid, rss, command] <- [String.split(String.trim_leading(line), ~r/\s+/, parts: 4)],
        {pid, ""} <- [Integer.parse(pid)],
        {ppid, ""} <- [Integer.parse(ppid)],
        {rss, ""} <- [Integer.parse(rss)] do
      {pid, ppid, rss, command}
    end
  end

  @doc """
  The VM's resident bytes and the bytes of its descendants, from parsed rows
  (`{nil, 0}` when the VM is not in the table). A `ps` row is not counted.
  """
  @spec split([{integer(), integer(), integer(), String.t()}], integer()) ::
          {non_neg_integer() | nil, non_neg_integer()}
  def split(rows, vm) do
    own =
      case List.keyfind(rows, vm, 0) do
        {^vm, _ppid, rss, _command} -> rss * 1024
        nil -> nil
      end

    by_parent = Enum.group_by(rows, fn {_pid, ppid, _rss, _command} -> ppid end)
    {own, descendants(by_parent, [vm], MapSet.new([vm]), 0)}
  end

  defp descendants(_by_parent, [], _seen, total), do: total * 1024

  defp descendants(by_parent, [parent | rest], seen, total) do
    kids =
      for {pid, _ppid, rss, command} = row <- Map.get(by_parent, parent, []),
          not MapSet.member?(seen, pid),
          do: {row, pid, rss, command}

    sum = for {_row, _pid, rss, command} <- kids, Path.basename(command) != "ps", do: rss
    pids = for {_row, pid, _rss, _command} <- kids, do: pid

    descendants(
      by_parent,
      rest ++ pids,
      Enum.reduce(pids, seen, &MapSet.put(&2, &1)),
      total + Enum.sum(sum)
    )
  end

  @doc "The machine's memory in bytes, or nil."
  @spec machine_bytes() :: non_neg_integer() | nil
  def machine_bytes do
    case :os.type() do
      {:unix, :darwin} -> darwin_bytes()
      {:unix, _linux} -> linux_bytes()
      _other -> nil
    end
  end

  defp darwin_bytes do
    with {:ok, output} <- run("sysctl", ["-n", "hw.memsize"]),
         {bytes, _rest} <- Integer.parse(String.trim(output)) do
      bytes
    else
      _ -> nil
    end
  end

  defp linux_bytes do
    with {:ok, text} <- File.read("/proc/meminfo"),
         [_all, kib] <- Regex.run(~r/^MemTotal:\s+(\d+) kB/m, text) do
      String.to_integer(kib) * 1024
    else
      _ -> nil
    end
  end

  defp run(command, args) do
    case System.find_executable(command) do
      nil ->
        :error

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} -> {:ok, output}
          _ -> :error
        end
    end
  rescue
    _ -> :error
  end
end
