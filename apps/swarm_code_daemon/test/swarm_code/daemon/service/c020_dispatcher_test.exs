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
end
