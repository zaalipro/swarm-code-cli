defmodule SwarmCode.Daemon.Service.R1019SlashExtrasTest do
  @moduledoc """
  C-FEAT-1 / C-FEAT-8: the workspace metadata lists the project's custom
  commands and workflows (names and descriptions, never bodies) for the
  terminal's `/` popup and /help.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Domain.Conversations

  setup_all do
    setup_world("slash-extras")
  end

  defp write!(root, relative, content) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  test "a project command and a project workflow are listed without their bodies", c do
    write!(
      c.root,
      ".swarm_code/commands/deploy.md",
      "---\ndescription: Ship it\\nsecond line stays home\n---\nDeploy $ARGUMENTS to production SECRET-BODY\n"
    )

    write!(
      c.root,
      ".swarm_code/commands/plain.md",
      "---\ndescription: No arguments\n---\nRun the checks\n"
    )

    write!(
      c.root,
      ".swarm_code/workflows/nightly.exs",
      ~s|meta = %{name: "nightly", description: "Nightly sweep", phases: ["Sweep"], budget: 4, args: %{}}\n\nphase("Sweep")\n|
    )

    {:ok, conv} = Conversations.create(c.project.id)
    backend = start_backend(c, conv)

    # `start_backend/3` returns once the launch listing has landed.
    assert %{task: nil, items: %{}} = :sys.get_state(backend).slash_extras

    body = workspace(backend, scope(conv))
    assert %{"custom" => custom, "workflows" => workflows} = body["slash_extras"]

    assert %{"name" => "deploy", "args" => true, "description" => description} =
             Enum.find(custom, &(&1["name"] == "deploy"))

    assert description =~ "Ship it"
    refute description =~ "\n"

    assert %{"args" => false} = Enum.find(custom, &(&1["name"] == "plain"))

    assert %{"description" => "Nightly sweep"} =
             Enum.find(workflows, &(&1["name"] == "nightly"))

    # Names, descriptions and the args flag only: no body leaves the daemon.
    refute inspect(body["slash_extras"]) =~ "SECRET-BODY"
    assert Enum.all?(custom, &(Map.keys(&1) |> Enum.sort() == ["args", "description", "name"]))
    assert Enum.all?(workflows, &(Map.keys(&1) |> Enum.sort() == ["description", "name"]))
    assert custom == Enum.sort_by(custom, & &1["name"])
    assert length(custom) + length(workflows) <= 200
  end

  test "a project without commands of its own sends a well-formed list", c do
    root = c.path <> "/empty-project"
    File.mkdir_p!(root)
    {:ok, project} = SwarmCode.Domain.Projects.create(%{name: "Empty", root_path: root})
    {:ok, conv} = Conversations.create(project.id)
    backend = start_backend(%{c | root: root, project: project}, conv)

    # `start_backend/3` returns once the launch listing has landed.
    assert %{task: nil, items: %{}} = :sys.get_state(backend).slash_extras

    assert %{"custom" => custom, "workflows" => workflows} =
             workspace(backend, scope(conv))["slash_extras"]

    refute Enum.any?(custom, &(&1["name"] in ["deploy", "plain"]))
    refute Enum.any?(workflows, &(&1["name"] == "nightly"))
  end
end
