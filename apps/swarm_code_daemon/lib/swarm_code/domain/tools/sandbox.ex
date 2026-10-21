defmodule SwarmCode.Domain.Tools.Sandbox do
  @moduledoc """
  pass 77 C-FEAT-4: `"sandbox": "workspace-write"` in `.swarm_code/config.json` runs
  the commands the model starts under macOS Seatbelt (`/usr/bin/sandbox-exec`):
  writes only inside the project and the temp dirs, no network unless the
  approval mode is Full access.

  Opt-in and small on purpose. What it covers is `run_command` (the model's
  shell); project hooks and the app's own Git calls are not sandboxed this pass.
  A denied write reaches the model as `Operation not permitted` and a non-zero
  exit code. `sandbox-exec` execs the shell in place, so the shell keeps its pid
  and `SwarmCode.Domain.OSProcess.kill_tree/1` still owns the whole tree.

  The profile is fail-closed: a path that cannot be quoted in the profile
  language refuses the command rather than running it unsandboxed. A project
  that asks for the sandbox on a machine without `sandbox-exec` runs unsandboxed
  (logged once) — there is nothing to enforce it with.
  """

  require Logger

  @exec "/usr/bin/sandbox-exec"
  @available_key {__MODULE__, :available}
  @warned_key {__MODULE__, :warned}

  @type mode :: :off | :workspace_write

  @doc "The sandbox mode the project of `ctx` asks for."
  @spec mode(map()) :: mode()
  def mode(%{project_root: root}) when is_binary(root) do
    case SwarmCode.Domain.Hooks.project_config(root) do
      %{sandbox: "workspace-write"} -> :workspace_write
      _none -> :off
    end
  end

  def mode(_ctx), do: :off

  @doc "True where `sandbox-exec` exists (macOS); read once per VM."
  @spec available?() :: boolean()
  def available? do
    case :persistent_term.get(@available_key, :unknown) do
      :unknown ->
        found = match?({:unix, :darwin}, :os.type()) and File.exists?(@exec)
        :persistent_term.put(@available_key, found)
        found

      found ->
        found
    end
  end

  @doc """
  The command to spawn for `{shell, args}`: wrapped in `sandbox-exec` when the
  project asks for it, unchanged otherwise, `{:error, message}` when the profile
  cannot be written safely.
  """
  @spec wrap({String.t(), [String.t()]}, map()) ::
          {String.t(), [String.t()]} | {:error, String.t()}
  def wrap({shell, args}, ctx) do
    cond do
      mode(ctx) != :workspace_write ->
        {shell, args}

      not available?() ->
        warn_once()
        {shell, args}

      true ->
        roots = write_roots(ctx.project_root)
        tmp = tmp_dirs()

        if Enum.all?(roots ++ tmp, &quotable?/1) do
          {@exec, ["-p", profile(roots, tmp, network?(ctx)), shell | args]}
        else
          {:error, "sandbox: the project path cannot be expressed in a sandbox profile"}
        end
    end
  end

  @doc """
  The Seatbelt profile (pure): everything allowed except writes, which are
  allowed under `roots` (a path or a list), `tmp_dirs` and a few device files;
  the network is denied unless `network?`.
  """
  @spec profile(String.t() | [String.t()], [String.t()], boolean()) :: String.t()
  def profile(roots, tmp_dirs, network?) do
    subpaths =
      (List.wrap(roots) ++ tmp_dirs ++ ["/private/tmp", "/private/var/folders"])
      |> Enum.uniq()
      |> Enum.map_join(" ", &~s[(subpath "#{&1}")])

    [
      "(version 1)",
      "(allow default)",
      "(deny file-write*)",
      "(allow file-write* #{subpaths} " <>
        ~s[(literal "/dev/null") (literal "/dev/zero") (literal "/dev/dtracehelper") ] <>
        ~s[(regex #"^/dev/tty") (regex #"^/dev/fd/"))],
      if(network?, do: nil, else: "(deny network*)")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  @doc "The network is open only in Full access (the mode this op was decided in)."
  @spec network?(map()) :: boolean()
  def network?(ctx) do
    mode = ctx[:live_mode] || ctx[:approval_override] || ctx[:approval_mode]
    mode == "full_access"
  end

  # The project, resolved; for an isolation directory the owning project too (a
  # commit in a worktree writes into the owner's `.git`).
  defp write_roots(root) do
    owner =
      case root |> Path.split() |> Enum.reverse() do
        [_name, "worktrees", ".swarm_code" | up] -> [up |> Enum.reverse() |> Path.join()]
        _plain -> []
      end

    for path <- [root | owner], do: real(path)
  end

  defp tmp_dirs, do: [real(System.tmp_dir!())]

  defp real(path) do
    case SwarmCode.Domain.Tools.Path.real_path(path) do
      {:ok, resolved} -> resolved
      {:error, _cycle} -> Path.expand(path)
    end
  end

  # A double quote or a backslash would end the profile's string early, and a
  # control character has no business in a path.
  defp quotable?(path), do: not String.match?(path, ~r/["\\\x00-\x1f]/)

  defp warn_once do
    if :persistent_term.get(@warned_key, false) == false do
      :persistent_term.put(@warned_key, true)

      Logger.warning(
        "sandbox: config.json asks for \"workspace-write\" but #{@exec} is not available; " <>
          "commands run unsandboxed"
      )
    end

    :ok
  end
end
