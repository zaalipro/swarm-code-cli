defmodule SwarmCode.Daemon.Platform.ProcessIdentity do
  @moduledoc false

  @enforce_keys [:uid, :pid, :process_start_id, :boot_id]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          uid: non_neg_integer(),
          pid: pos_integer(),
          process_start_id: String.t(),
          boot_id: String.t()
        }

  @spec current(keyword()) :: {:ok, t()} | {:error, term()}
  def current(opts \\ []) do
    case Keyword.get_lazy(opts, :platform, &current_platform/0) do
      :linux -> current_linux(opts)
      :macos -> {:error, :macos_platform_helper_unavailable}
      _other -> {:error, :unsupported_platform}
    end
  end

  @spec from_linux(non_neg_integer(), pos_integer(), binary(), binary()) ::
          {:ok, t()} | {:error, :invalid_linux_process_identity}
  def from_linux(uid, pid, stat, boot_id)
      when is_integer(uid) and uid >= 0 and is_integer(pid) and pid > 0 and is_binary(stat) and
             is_binary(boot_id) do
    with {:ok, start_ticks} <- linux_start_ticks(pid, stat),
         boot_id when boot_id != "" <- String.trim(boot_id) do
      {:ok,
       %__MODULE__{
         uid: uid,
         pid: pid,
         process_start_id: "linux-proc-start:#{start_ticks}",
         boot_id: boot_id
       }}
    else
      _other -> {:error, :invalid_linux_process_identity}
    end
  end

  def from_linux(_uid, _pid, _stat, _boot_id),
    do: {:error, :invalid_linux_process_identity}

  @spec from_darwin(non_neg_integer(), pos_integer(), binary(), binary()) ::
          {:ok, t()} | {:error, :invalid_darwin_process_identity}
  def from_darwin(uid, pid, process_start, boot_time)
      when is_integer(uid) and uid >= 0 and is_integer(pid) and pid > 0 and
             is_binary(process_start) and is_binary(boot_time) do
    process_start = String.trim(process_start)
    boot_time = String.trim(boot_time)

    if process_start != "" and boot_time != "" do
      {:ok,
       %__MODULE__{
         uid: uid,
         pid: pid,
         process_start_id: "darwin-proc-start:#{process_start}",
         boot_id: "darwin-boot:#{boot_time}"
       }}
    else
      {:error, :invalid_darwin_process_identity}
    end
  end

  def from_darwin(_uid, _pid, _process_start, _boot_time),
    do: {:error, :invalid_darwin_process_identity}

  defp current_linux(opts) do
    command = Keyword.get(opts, :command, &System.cmd/3)
    read_file = Keyword.get(opts, :read_file, &File.read/1)
    pid = System.pid() |> String.to_integer()

    with {:ok, uid} <- current_uid(command),
         {:ok, stat} <- read_file.("/proc/self/stat"),
         {:ok, boot_id} <- read_file.("/proc/sys/kernel/random/boot_id") do
      from_linux(uid, pid, stat, boot_id)
    end
  end

  defp current_uid(command) do
    case command.("/usr/bin/id", ["-u"], []) do
      {output, 0} when is_binary(output) ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _other -> {:error, :invalid_uid}
        end

      {_output, status} ->
        {:error, {:uid_command_failed, status}}

      _other ->
        {:error, :invalid_uid_command_result}
    end
  end

  defp linux_start_ticks(pid, stat) do
    prefix = Integer.to_string(pid) <> " ("

    with true <- String.starts_with?(stat, prefix),
         {_close_at, 1} = close <- final_closing_parenthesis(stat),
         tail <- stat_tail(stat, close),
         start_ticks when is_binary(start_ticks) <- Enum.at(String.split(tail), 19),
         {ticks, ""} when ticks >= 0 <- Integer.parse(start_ticks) do
      {:ok, Integer.to_string(ticks)}
    else
      _other -> {:error, :invalid_linux_process_identity}
    end
  end

  defp final_closing_parenthesis(stat) do
    case :binary.matches(stat, ")") do
      [] -> :error
      matches -> List.last(matches)
    end
  end

  defp stat_tail(stat, {close_at, 1}) do
    offset = close_at + 1
    binary_part(stat, offset, byte_size(stat) - offset)
  end

  defp current_platform do
    case :os.type() do
      {:unix, :linux} -> :linux
      {:unix, :darwin} -> :macos
      _other -> :unsupported
    end
  end
end
