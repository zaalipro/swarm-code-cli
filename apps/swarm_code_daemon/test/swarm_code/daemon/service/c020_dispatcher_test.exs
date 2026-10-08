defmodule SwarmCode.Daemon.Service.C020DispatcherTest do
  @moduledoc """
  cli020 lane C: the slash commands the dispatcher answers differently in
  0.2.0 (one-shot /consensus, /search rows, structured /agents and /cost,
  /rename, /delete, /fork, bare /effort).
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.CommandDispatcher, as: Dispatcher
  alias SwarmCode.Domain.{Conversations, Engine}

  setup_all do
    setup_world("dispatcher")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    %{conversation: conv}
  end

  describe "C7 /consensus <task>" do
    test "is one-shot: the run is judged, the conversation keeps its mode", c do
      {conv, _, _} = provider!(c, c.conversation, fn _ -> {:text, "Done."} end)

      assert {:ok, %{type: :started, run_id: run_id}} =
               Dispatcher.dispatch(conv.id, "/consensus fix the flaky test")

      assert Conversations.get(conv.id).consensus == false
      assert Conversations.get(conv.id).mode == "build"
      assert Conversations.get_run(run_id).consensus == true
    end

    test "bare /consensus stays sticky", c do
      assert {:ok, %{type: :updated}} = Dispatcher.dispatch(c.conversation.id, "/consensus")
      assert Conversations.get(c.conversation.id).consensus == true
    end
  end

  describe "C8 /search" do
    test "returns this project's hits as rows even when another project has more", c do
      File.mkdir_p!(c.root <> "-other")

      {:ok, other} =
        SwarmCode.Domain.Projects.create(%{name: "Other", root_path: c.root <> "-other"})

      for n <- 1..30 do
        {:ok, conv} = Conversations.create(other.id)

        {:ok, _} =
          Conversations.create_message(%{
            conversation_id: conv.id,
            role: "user",
            content: "zebrafish migration #{n}"
          })
      end

      here =
        for n <- 1..2 do
          {:ok, conv} = Conversations.create(c.project.id)

          {:ok, _} =
            Conversations.create_message(%{
              conversation_id: conv.id,
              role: "user",
              content: "zebrafish tank #{n}"
            })

          conv.id
        end

      assert {:ok, %{type: :select, subject: :search, options: rows}} =
               Dispatcher.dispatch(c.conversation.id, "/search zebrafish")

      assert Enum.sort(Enum.map(rows, & &1.conversation_id)) == Enum.sort(here)
      assert Enum.all?(rows, &(is_binary(&1.title) and is_binary(&1.snippet)))
      assert Enum.all?(rows, &is_integer(&1.at))
    end

    test "the service answers /search with rows the client decodes", c do
      {:ok, conv} = Conversations.create(c.project.id)

      {:ok, _} =
        Conversations.create_message(%{
          conversation_id: conv.id,
          role: "user",
          content: "okapi sighting"
        })

      backend = start_backend(c, c.conversation)

      assert {:ok, %{"value" => value}} =
               send_text(backend, scope(c.conversation), "/search okapi")

      assert {:ok, outcome} = SwarmCodeCLI.UI.DataSource.DTO.Outcome.decode(value)
      assert outcome.feedback.subject == :search
      assert [%{conversation_id: id, title: title}] = outcome.feedback.rows
      assert id == conv.id and is_binary(title)
      assert outcome.feedback.text =~ "/resume " <> String.slice(conv.id, 0, 8)
    end
  end

  describe "C9 /agents" do
    test "answers rows, never Markdown", c do
      dir = Path.join([c.root, ".swarm_code", "agents"])
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "checker.md"), """
      ---
      name: checker
      description: Reads a diff and reports problems
      model: fixture
      ---
      Check the diff.
      """)

      assert {:ok, %{type: :report, subject: :agents, rows: rows, text: text}} =
               Dispatcher.dispatch(c.conversation.id, "/agents")

      assert %{name: "checker", model: "fixture", description: description, source: source} =
               Enum.find(rows, &(&1.name == "checker"))

      assert description =~ "Reads a diff" and is_binary(source)
      refute text =~ "**"
      refute inspect(rows) =~ "**"
    end
  end

  # E3 parses /rename, /delete and /fork; until it lands these tests hand the
  # dispatcher the command map the parser returns (`execute_parsed/3`).
  defp parsed(conv, name, action, fields \\ %{}),
    do:
      Dispatcher.execute_parsed(
        conv.id,
        Map.merge(%{name: name, kind: :builtin, action: action}, fields)
      )

  defp message!(conv, role, content) do
    {:ok, m} =
      Conversations.create_message(%{conversation_id: conv.id, role: role, content: content})

    m
  end

  describe "C11 /rename, /delete, /fork" do
    test "/rename trims and bounds the title", c do
      conv = c.conversation

      assert {:ok, %{type: :renamed, title: "Build fix"}} =
               parsed(conv, "rename", :rename_conversation, %{title: "  Build fix  "})

      assert Conversations.get(conv.id).title == "Build fix"

      for bad <- ["   ", String.duplicate("x", 201)] do
        assert {:error, :invalid_argument} =
                 parsed(conv, "rename", :rename_conversation, %{title: bad})
      end

      assert Conversations.get(conv.id).title == "Build fix"
    end

    test "/delete removes this conversation and opens the newest other one", c do
      {:ok, older} = Conversations.create(c.project.id)
      {:ok, newer} = Conversations.create(c.project.id)
      {:ok, _} = Conversations.update(newer, %{title: "Newest other"})
      message!(newer, "user", "hello")

      assert {:ok, %{type: :conversation, conversation_id: target}} =
               parsed(older, "delete", :delete_conversation)

      assert Conversations.get(older.id) == nil
      assert target == newer.id
    end

    test "/delete of the last conversation opens a new one", c do
      root = c.root <> "-delete-last"
      File.mkdir_p!(root)
      {:ok, project} = SwarmCode.Domain.Projects.create(%{name: "Alone", root_path: root})
      {:ok, only} = Conversations.create(project.id)

      assert {:ok, %{type: :conversation, conversation_id: target, created: true}} =
               parsed(only, "delete", :delete_conversation)

      assert target != only.id
      assert Conversations.get(target).project_id == project.id
    end

    test "/delete is refused while a run of the conversation is live", c do
      conv = c.conversation
      run_id = Ecto.UUID.generate()
      {:ok, _} = Registry.register(SwarmCode.Domain.Registry, {:run, run_id}, {conv.id, nil})

      assert {:error, {:busy, words}} = parsed(conv, "delete", :delete_conversation)
      assert words =~ "Stop"
      assert Conversations.get(conv.id) != nil
      Registry.unregister(SwarmCode.Domain.Registry, {:run, run_id})
    end

    test "/fork copies the whole conversation and opens the copy", c do
      conv = c.conversation
      {:ok, conv} = Conversations.update(conv, %{title: "Original"})
      message!(conv, "user", "first")
      message!(conv, "assistant", "reply")
      message!(conv, "user", "second")

      assert {:ok, %{type: :conversation, conversation_id: fork_id, created: true}} =
               parsed(conv, "fork", :fork_conversation)

      assert fork_id != conv.id
      assert Conversations.get(fork_id).title == "Fork: Original"

      assert Enum.map(Conversations.list_messages(fork_id), & &1.content) ==
               ["first", "reply", "second"]
    end
  end

  describe "C17 bare /effort" do
    test "reports the effort and the levels", c do
      {:ok, conv} = Conversations.update(c.conversation, %{effort: "medium"})
      levels = Dispatcher.efforts(conv, :chat)

      assert {:ok, %{type: :report, title: "Effort", text: text}} =
               parsed(conv, "effort", :show_effort, %{target: :chat})

      assert text ==
               "Effort: medium (chat model). Levels: #{Enum.join(levels, ", ")}. /effort <level> sets it."

      assert {:ok, %{type: :report, text: worker}} =
               parsed(conv, "worker_effort", :show_effort, %{target: :swarm})

      # cli021 B2: the worker slot's command is /worker_effort (/swarm_effort
      # stays a hidden alias, so the report names the new word).
      assert worker =~ "(worker model)" and worker =~ "/worker_effort <level> sets it."
      refute worker =~ "swarm_effort"
    end
  end

  describe "C18 /cost" do
    test "rows per model, an unknown price stays unknown, then the total", c do
      conv = c.conversation

      for {model, cost, tin} <- [{"alpha", 0.5, 100}, {"alpha", 0.25, 50}, {"beta", nil, 10}] do
        {:ok, _} =
          Conversations.create_run(%{
            conversation_id: conv.id,
            kind: "chat",
            prompt: "x",
            status: "done",
            model: model,
            tokens_in: tin,
            tokens_out: 5,
            cost_usd: cost,
            started_at: DateTime.utc_now()
          })
      end

      assert {:ok, %{type: :report, subject: :cost, rows: rows, text: text}} =
               Dispatcher.dispatch(conv.id, "/cost")

      assert [
               %{model: "alpha", runs: 2, tokens_in: 150, tokens_out: 10, cost_usd: 0.75},
               %{model: "beta", runs: 1, tokens_in: 10, cost_usd: nil},
               %{name: "Total", runs: 3, tokens_in: 160, tokens_out: 15}
             ] = rows

      assert text =~ "beta: 1 run, 10 in, 5 out, price unknown"
    end
  end
end
