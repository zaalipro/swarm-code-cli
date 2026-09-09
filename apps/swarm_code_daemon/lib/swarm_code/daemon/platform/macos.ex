defmodule SwarmCode.Daemon.Platform.MacOS do
  @moduledoc """
  Read-only macOS process identity and exact desktop bundle checks.

  The signed helper digest is captured during compilation, after the native
  compiler signs it. Source builds use ad-hoc signing and are internal artifacts.
  Release packaging must sign the helper before compiling this module; replacing
  or re-signing the helper afterwards invalidates this pin and fails closed.
  """
  import Bitwise
  alias SwarmCode.Daemon.Platform.ProcessIdentity
  @bundle "com.zaali.swarmcode"
  @packaged_path Path.expand("../../../../priv/native/swarm-macos-helper", __DIR__)
  @external_resource @packaged_path
  @digest (if :os.type() == {:unix, :darwin} do
             case File.read(@packaged_path) do
               {:ok, bytes} -> :crypto.hash(:sha256, bytes)
               _ -> nil
             end
           else
             nil
           end)
  @unavailable {:error, :macos_platform_helper_unavailable}

  def helper_path, do: Application.app_dir(:swarm_code_daemon, "priv/native/swarm-macos-helper")

  def current_identity do
    pid = String.to_integer(System.pid())

    with {:ok, output} <- invoke(["identity", Integer.to_string(pid)]),
         {:ok, identity} <- parse_identity(output, pid) do
      {:ok, identity}
    else
      _ -> @unavailable
    end
  end

  @doc "FoundationGate detector callback; does not open storage or signal any process."
  def desktop_detector do
    fn ->
      with {:ok, identity} <- current_identity(),
           {:ok, output} <- invoke(["desktop"]),
           {:ok, result} <- parse_desktop(output, identity.uid) do
        result
      else
        _ -> @unavailable
      end
    end
  end

  @doc false
  def verify_helper(path) do
    with true <- :os.type() == {:unix, :darwin} and is_binary(@digest),
         {:ok, %{type: :regular, mode: mode, size: size}} <- File.lstat(path),
         true <- size in 1..1_048_576 and band(mode, 0o022) == 0 and band(mode, 0o111) != 0,
         {:ok, bytes} <- File.read(path),
         true <- :crypto.hash_equals(:crypto.hash(:sha256, bytes), @digest),
         {:ok, _} <- command("/usr/bin/codesign", ["--verify", "--strict", path]),
         {:ok, ^bytes} <- File.read(path) do
      :ok
    else
      _ -> @unavailable
    end
  rescue
    _ -> @unavailable
  end

  @doc false
  def parse_identity(output, expected_pid) do
    with {:ok, map} <- line(output),
         true <- Enum.sort(Map.keys(map)) == ~w(boot kind pid start uid version),
         %{
           "version" => 1,
           "kind" => "identity",
           "uid" => uid,
           "pid" => ^expected_pid,
           "start" => start,
           "boot" => boot
         } <- map,
         true <- is_integer(uid) and uid in 0..4_294_967_295,
         true <- is_integer(expected_pid) and expected_pid in 1..2_147_483_647,
         true <- is_binary(start) and Regex.match?(~r/\A[1-9][0-9]{0,12}:[0-9]{6}\z/, start),
         true <-
           is_binary(boot) and
             Regex.match?(
               ~r/\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\z/,
               boot
             ) do
      ProcessIdentity.from_darwin(uid, expected_pid, start, String.downcase(boot))
    else
      _ -> @unavailable
    end
  end

  @doc false
  def parse_desktop(output, expected_uid) do
    with {:ok, map} <- line(output) do
      case map do
        %{"version" => 1, "kind" => "desktop", "active" => false} when map_size(map) == 3 ->
          {:ok, :none}

        %{
          "version" => 1,
          "kind" => "desktop",
          "active" => true,
          "pid" => pid,
          "uid" => ^expected_uid,
          "application" => @bundle
        }
        when map_size(map) == 6 and
               is_integer(pid) and pid in 1..2_147_483_647 and is_integer(expected_uid) and
               expected_uid >= 0 ->
          {:ok, {:active, %{pid: pid, uid: expected_uid, application: @bundle}}}

        _ ->
          @unavailable
      end
    end
  end

  defp invoke(args) do
    path = helper_path()
    with :ok <- verify_helper(path), do: command(path, args)
  end

  defp line(output) when is_binary(output) and byte_size(output) in 3..2048 do
    with true <- String.valid?(output),
         [body, ""] <- String.split(output, "\n"),
         false <- String.contains?(body, "\r"),
         {:ok, map} when is_map(map) <- Jason.decode(body) do
      {:ok, map}
    else
      _ -> @unavailable
    end
  end

  defp line(_), do: @unavailable

  defp command(executable, args) do
    # ExternalCommand owns timeout/requester-loss teardown and waits for the
    # exact child exit. Its line protocol rejects extra or overlong output.
    case SwarmCode.Daemon.Platform.ExternalCommand.run(executable, args,
           timeout: 5_000,
           max_line_bytes: 2048
         ) do
      {:ok, line} -> {:ok, line <> "\n"}
      _ -> @unavailable
    end
  end
end
