defmodule SwarmCode.Daemon.Service.R1019ChatOptsTest do
  @moduledoc """
  Pass 77 C-BUG-12 (CLI wiring): every chat turn the session starts carries the
  session overlay (`--model`, `NCODE_EFFORT`) as a function, so a turn the
  engine chains after an automatic compaction can apply it to the conversation
  it reloads. The engine's continuation applies it after the desktop re-sync;
  here only the options are pinned.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Daemon.Service.{SessionConfiguration, SessionSelection}
  alias SwarmCode.Domain.{Cache, Conversations, Providers, Repo}

  setup do
    path = SchemaFixture.database!(:current, SwarmCode.Daemon.Test.LeaseFixture.build_root())
    start_supervised!({Repo, database: path, domain_fixture: true, pool_size: 1, log: false})
    Cache.clear()
    SessionConfiguration.clear_override()

    on_exit(fn ->
      Cache.clear()
      SessionConfiguration.clear_override()
      SessionConfiguration.clear_env_effort()
    end)

    root = Path.join(Path.dirname(path), "project")
    File.mkdir!(root)
    {:ok, session} = SessionSelection.open(root)
    _ = SwarmCode.Domain.Settings.get_cached()
    %{session: session}
  end

  defp provider!(attrs) do
    {:ok, provider} =
      Providers.create(
        Map.merge(
          %{kind: "openai_compatible", base_url: "https://saved.invalid/v1", api_key: "saved"},
          attrs
        )
      )

    Cache.clear()
    provider
  end

  defp state, do: %{opts: [approval_mode: "read_only"], extra_read_roots: []}

  test "the options carry the caller's, the approval mode and an overlay function", c do
    a = provider!(%{name: "alpha", models: ["a-model"], default_model: "a-model"})
    b = provider!(%{name: "beta", models: ["b-model"], default_model: "b-model"})

    {:ok, conversation} =
      Conversations.update(c.session.conversation, %{
        chat_provider_id: a.id,
        chat_model: "a-model"
      })

    session = %{c.session | conversation: conversation}

    assert {:ok, _} =
             SessionConfiguration.prepare(session, %{"SWARM_MODEL_OVERRIDE" => "beta/b-model"})

    opts = Backend.chat_turn_opts_for_test(state(), research_ids: ["r1"])
    assert opts[:research_ids] == ["r1"]
    assert opts[:approval_mode] == "read_only"
    assert is_function(opts[:conversation_overlay], 1)

    # The stored row is untouched; the function applies the override to a
    # freshly loaded conversation.
    fresh = Conversations.get!(conversation.id)
    assert fresh.chat_model == "a-model"
    overlaid = opts[:conversation_overlay].(fresh)
    assert overlaid.chat_provider_id == b.id
    assert overlaid.chat_model == "b-model"
  end

  test "without an approval mode the overlay is still passed", _c do
    opts = Backend.chat_turn_opts_for_test(%{opts: [], extra_read_roots: []})
    assert Keyword.keys(opts) == [:conversation_overlay]
  end
end
