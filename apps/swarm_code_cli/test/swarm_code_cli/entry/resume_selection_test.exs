defmodule SwarmCodeCLI.Release.ResumeSelectionTest do
  @moduledoc """
  cli020 B19 (competitors-12): `--resume` takes a unique id prefix of at
  least 6 hex characters or an exact title; an ambiguous one names up to
  five; bare `--resume` opens the picker.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCodeCLI.Release
  alias SwarmCodeCLI.Release.PersistedSession

  setup do
    base = Path.join(System.tmp_dir!(), "b19-#{System.unique_integer([:positive])}")
    root = Path.join(base, "project")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(base) end)

    start_supervised!(
      {Repo,
       database: Path.join(base, "fixture.db"), domain_fixture: true, pool_size: 1, log: false}
    )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    Cache.clear()
    {:ok, real} = SwarmCode.Domain.Tools.Path.real_path(root)
    {:ok, project} = Projects.create(%{name: "p", root_path: real})
    %{root: real, project: project}
  end

  defp conversation!(c, title) do
    {:ok, conversation} = Conversations.create(c.project.id)
    {:ok, conversation} = Conversations.update(conversation, %{title: title})
    conversation
  end

  test "an exact title or a unique 6+ hex prefix resolves", c do
    one = conversation!(c, "Fix the login")
    _two = conversation!(c, "Write docs")

    assert {:ok, id} = PersistedSession.resolve_resume(c.root, "Fix the login")
    assert id == one.id
    assert {:ok, ^id} = PersistedSession.resolve_resume(c.root, String.slice(one.id, 0, 8))
  end

  test "too short, unknown and ambiguous values say so", c do
    for n <- 1..7, do: conversation!(c, "Same title")

    assert {:error, %{status: 2, message: message, action: action}} =
             PersistedSession.resolve_resume(c.root, "Same title")

    assert message == "--resume Same title matches 7 conversations."
    assert length(String.split(action, "\n")) == 6
    assert action =~ ~r/[0-9a-f-]{36}  Same title/

    assert {:error, %{status: 2, message: missing}} =
             PersistedSession.resolve_resume(c.root, "nope")

    assert missing =~ "No conversation of this project matches nope."

    assert {:error, %{status: 2}} = PersistedSession.resolve_resume(c.root, "abc")
  end

  test "the release grammar takes prefixes and titles, and refuses a bare --resume" do
    assert {:ok, %{conversation: "Fix it"}} = Release.parse(["--resume", "Fix it", "-p", "x"])
    assert {:ok, %{conversation: "7d01acff"}} = Release.parse(["-r", "7d01acff", "--plain"])

    assert {:error,
            "--resume needs an id or a title here; ncode --resume alone opens the picker."} =
             Release.parse(["--resume", "-p", "x"])
  end
end
