defmodule SwarmCode.Daemon.Service.R1019AddDirTest do
  @moduledoc """
  Pass 77 C-FEAT-12 (backend side): extra read-only folders live in the
  session's memory, from `--add-dir` at launch or `/add-dir` while it runs, and
  go to every chat turn as `extra_read_roots:`. Only a real, existing folder
  that is neither `/` nor the project itself is kept, at most eight.
  """
  use ExUnit.Case, async: false
  @moduletag :capture_log

  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Conversations, Engine}
  alias SwarmCode.Domain.Tools.Path, as: ToolPath

  setup_all do
    setup_world("add-dir")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    {conv, _, _} = provider!(c, conv, fn _ -> {:text, "Done."} end)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  defp folder!(c, name) do
    dir = Path.join(c.path, name)
    File.mkdir_p!(dir)
    {:ok, real} = ToolPath.real_path(dir)
    {dir, real}
  end

  defp roots(backend), do: :sys.get_state(backend).extra_read_roots

  defp add_dir(backend, c, argument) do
    send_text(backend, scope(c.conversation), "/add-dir " <> argument)
  end

  test "a launch folder is kept by its real path; unusable ones are dropped", c do
    {dir, real} = folder!(c, "outside")
    {:ok, project_real} = ToolPath.real_path(c.root)
    link = Path.join(c.path, "outside-link")
    File.ln_s!(dir, link)

    backend =
      start_backend(c, c.conversation,
        extra_read_roots: [
          link,
          dir,
          "relative/path",
          "/",
          c.root,
          project_real,
          Path.join(c.path, "missing"),
          :not_a_path
        ]
      )

    assert roots(backend) == [real]
    opts = Backend.chat_turn_opts_for_test(:sys.get_state(backend))
    assert opts[:extra_read_roots] == [real]
  end

  test "without folders the turn options carry none", c do
    backend = start_backend(c, c.conversation)
    assert roots(backend) == []
    opts = Backend.chat_turn_opts_for_test(:sys.get_state(backend))
    refute Keyword.has_key?(opts, :extra_read_roots)
  end

  test "/add-dir adds a folder for the session and says so", c do
    {_dir, real} = folder!(c, "docs-outside")
    File.mkdir_p!(Path.join(c.root, "docs"))
    backend = start_backend(c, c.conversation)

    assert {:ok,
            %{"value" => %{"status" => "accepted", "identifiers" => [], "feedback" => feedback}}} =
             add_dir(backend, c, real)

    assert feedback["title"] == "Folders"
    assert feedback["text"] == "Read-only folder added for this session: " <> real
    assert roots(backend) == [real]

    # The same folder again changes nothing; a relative one is read against
    # the project folder.
    assert {:ok, %{"value" => %{"status" => "accepted"}}} = add_dir(backend, c, real)
    assert roots(backend) == [real]
    {:ok, docs} = ToolPath.real_path(Path.join(c.root, "docs"))
    assert {:ok, %{"value" => %{"status" => "accepted"}}} = add_dir(backend, c, "docs")
    assert roots(backend) == [real, docs]

    opts = Backend.chat_turn_opts_for_test(:sys.get_state(backend))
    assert opts[:extra_read_roots] == [real, docs]
    # A command is not a turn: nothing was started or queued.
    assert Conversations.list_runs(c.conversation.id) == []
    assert Conversations.get(c.conversation.id).queued == []
  end

  test "/add-dir refuses /, the project, a missing folder, a file and no argument", c do
    backend = start_backend(c, c.conversation)
    File.write!(Path.join(c.path, "a-file"), "x")

    for argument <- ["/", ".", c.root, Path.join(c.path, "missing"), Path.join(c.path, "a-file")] do
      assert {:ok,
              %{"value" => %{"status" => "rejected", "reason" => %{"code" => "invalid_argument"}}}} =
               add_dir(backend, c, argument)
    end

    assert {:ok,
            %{"value" => %{"status" => "rejected", "reason" => %{"code" => "missing_argument"}}}} =
             send_text(backend, scope(c.conversation), "/add-dir")

    assert roots(backend) == []
  end

  test "a ninth folder is refused", c do
    backend = start_backend(c, c.conversation)
    dirs = for n <- 1..9, do: folder!(c, "extra-#{n}")

    for {dir, _real} <- Enum.take(dirs, 8) do
      assert {:ok, %{"value" => %{"status" => "accepted"}}} = add_dir(backend, c, dir)
    end

    {ninth, _} = List.last(dirs)

    assert {:ok,
            %{"value" => %{"status" => "rejected", "reason" => %{"code" => "invalid_argument"}}}} =
             add_dir(backend, c, ninth)

    assert length(roots(backend)) == 8
    refute elem(List.last(dirs), 1) in roots(backend)
  end

  test "launch folders beyond eight are dropped", c do
    dirs = for n <- 1..10, do: folder!(c, "launch-#{n}") |> elem(0)
    backend = start_backend(c, c.conversation, extra_read_roots: dirs)
    assert length(roots(backend)) == 8
  end
end
