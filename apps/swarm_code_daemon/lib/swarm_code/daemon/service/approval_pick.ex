defmodule SwarmCode.Daemon.Service.ApprovalPick do
  @moduledoc """
  cli020 fix S3: choosing an approval mode by hand (Shift-Tab, the `/approval`
  picker, `/approval <mode>`) is the consent the desktop's trust banner asks
  for. The desktop's `set_approval_mode` event therefore sets the mode and then
  `Projects.mark_trusted/1`, so the folder is not left untrusted under a mode
  the user picked (its AGENTS.md stays out of the prompt, hooks and project
  rules stay off). The CLI does the same, and never silently: the notice says
  `Approvals: read-only → auto · this project is now trusted`.
  """

  alias SwarmCode.Domain.Projects
  alias SwarmCode.Domain.Projects.Project

  @modes ["read_only", "auto", "full_access"]

  @doc """
  Sets `mode`, marks the project trusted, and returns the notice.

  The notice is the plain `Approval mode: <mode>` when the project was already
  trusted, so a trusted project's words are unchanged.
  """
  @spec pick(Project.t(), String.t()) :: {:ok, Project.t(), String.t()} | {:error, term()}
  def pick(%Project{} = project, mode) when mode in @modes do
    before_mode = project.approval_mode
    was_trusted? = Projects.trusted?(project)

    with {:ok, project} <- Projects.update(project, %{approval_mode: mode}),
         {:ok, project} <- Projects.mark_trusted(project) do
      {:ok, project, notice(before_mode, project.approval_mode, was_trusted?)}
    end
  end

  @doc false
  @spec notice(String.t() | nil, String.t(), boolean()) :: String.t()
  def notice(_from, to, true), do: "Approval mode: " <> words(to)

  def notice(to, to, false),
    do: "Approvals: " <> words(to) <> " · this project is now trusted"

  def notice(from, to, false),
    do: "Approvals: " <> words(from) <> " → " <> words(to) <> " · this project is now trusted"

  defp words("read_only"), do: "read-only"
  defp words("full_access"), do: "full access"
  defp words(mode), do: to_string(mode)
end
