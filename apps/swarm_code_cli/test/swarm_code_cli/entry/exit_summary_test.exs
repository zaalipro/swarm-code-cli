defmodule SwarmCodeCLI.Release.ExitSummaryTest do
  @moduledoc """
  cli020 B21 (competitors-5, ux-live-20; decisions 4d, 4g) and B20: the
  full screen's exit summary prints the last exchanges and what the session
  spent, after erasing the launcher's "Starting ncode…" line.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCodeCLI.Release.PersistedSession

  setup do
    base = Path.join(System.tmp_dir!(), "b21-#{System.unique_integer([:positive])}")
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
    {:ok, conversation} = Conversations.create(project.id)
    %{project: project, conversation: conversation}
  end

  defp message!(c, position, role, content, superseded? \\ false) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO messages (id, conversation_id, role, content, position, superseded_at, inserted_at, updated_at) " <>
        "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)",
      [
        Ecto.UUID.generate(),
        c.conversation.id,
        role,
        content,
        position,
        if(superseded?, do: now),
        now
      ]
    )
  end

  defp run!(c, tokens_in, tokens_out, cost) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    Repo.query!(
      "INSERT INTO runs (id, conversation_id, kind, status, tokens_in, tokens_out, cost_usd, started_at, inserted_at, updated_at) " <>
        "VALUES (?1, ?2, 'chat', 'done', ?3, ?4, ?5, ?6, ?6, ?6)",
      [Ecto.UUID.generate(), c.conversation.id, tokens_in, tokens_out, cost, now]
    )
  end

  defp session(c), do: %{conversation: c.conversation, project: c.project}

  defp text(c, started_at, opts \\ []) do
    c
    |> session()
    |> PersistedSession.exit_summary(started_at, Keyword.put_new(opts, :exchanges, 3))
    |> PersistedSession.summary_text()
  end

  test "the last exchanges oldest first, superseded rows skipped, then the spend line", c do
    started = DateTime.add(DateTime.utc_now(), -372, :second)
    message!(c, 1, "user", "first question")
    message!(c, 2, "assistant", "first answer\e[31m red")
    message!(c, 3, "user", "an edited prompt", true)
    message!(c, 4, "shell", "ls\nREADME.md")
    message!(c, 5, "user", "second question")
    message!(c, 6, "assistant", "second answer")
    run!(c, 10_000, 2_400, 0.012)
    run!(c, 0, 0, 0.018)

    out = text(c, started)
    assert String.starts_with?(out, "\r\e[2K")
    refute out =~ "an edited prompt"
    refute out =~ "\e[31m"

    assert out =~
             "› first question\nfirst answer red\n\n$ ls\n  README.md\n\n› second question\nsecond answer\n"

    assert out =~ ~r/Spent\s+12\.4k tokens · \$0\.03 · 6m 1[23]s/
    [before, _] = String.split(out, "Spent", parts: 2)
    assert before =~ "Last prompt"
  end

  test "no cost part when a run's cost is unknown; <$0.01; no line without runs", c do
    started = DateTime.add(DateTime.utc_now(), -5, :second)
    message!(c, 1, "user", "hi")
    out = text(c, started)
    refute out =~ "Spent"

    run!(c, 900, 50, 0.001)
    assert text(c, started) =~ ~r/Spent\s+950 tokens · <\$0\.01 · [56]s/

    run!(c, 1_000_000, 300_000, nil)
    out = text(c, started)
    assert out =~ ~r/Spent\s+1\.3M tokens · [56]s/
    refute out =~ "$0"
  end

  test "exit_transcript 0 prints no exchanges; long replies are clipped on a UTF-8 boundary", c do
    started = DateTime.utc_now()
    message!(c, 1, "user", "question")
    message!(c, 2, "assistant", String.duplicate("é", 3_000))

    refute text(c, started, exchanges: 0) =~ "› question"

    out = text(c, started)
    assert String.valid?(out)
    [_, reply] = String.split(out, "› question\n", parts: 2)
    [reply | _] = String.split(reply, "\n", parts: 2)
    assert byte_size(reply) <= 4_000 + 3
  end

  test "the exit_transcript setting: default 3, 0..20" do
    assert PersistedSession.exit_transcript(%{}) == 3
    assert PersistedSession.exit_transcript(%{"exit_transcript" => 0}) == 0
    assert PersistedSession.exit_transcript(%{"exit_transcript" => 50}) == 3
  end
end
