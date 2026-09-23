defmodule SwarmCode.Domain.Engine.RunServerPendingInteractionsTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Domain.Engine.RunServer

  # pass 70 contract (docs/superpowers/plans/pass70-notes/A.md): every row has
  # exactly these keys, approvals and questions alike.
  @row_keys [
    :node_id,
    :agent_id,
    :kind,
    :permission,
    :tool,
    :args,
    :command,
    :cwd,
    :path,
    :reason,
    :command_family,
    :classification,
    :allowed_decisions,
    :requested_at,
    :questions
  ]

  test "unknown and invalid run handles return no interactions" do
    assert [] = RunServer.pending_interactions(Ecto.UUID.generate())
    assert [] = RunServer.pending_interactions(nil)
  end

  test "approval output is redacted, byte-bounded and excludes runtime state" do
    id = Ecto.UUID.generate()

    input =
      Jason.encode!(%{
        "command" => "echo hello",
        "nested" => %{"api_key" => "SECRET"},
        "authorization" => "credential"
      })

    state =
      state(
        %{id => %{permission: :execute, from: {self(), make_ref()}, timer: make_ref()}},
        %{},
        %{id => %{op_type: "run_command", input: input, pid: self()}}
      )

    assert {:reply, [row], ^state} = RunServer.handle_call(:pending_interactions, nil, state)

    assert %{
             node_id: ^id,
             kind: :approval,
             permission: :execute,
             tool: "run_command",
             questions: []
           } = row

    assert row.args =~ "echo hello"
    refute row.args =~ "SECRET"
    refute row.args =~ "credential"
    assert byte_size(row.args) <= 8192

    assert Map.keys(row) |> Enum.sort() == Enum.sort(@row_keys)
  end

  test "an approval row carries the command, where it runs, why, its family and class" do
    id = Ecto.UUID.generate()
    agent = Ecto.UUID.generate()
    asked = ~U[2026-09-23 10:00:00.000000Z]

    input =
      Jason.encode!(%{
        "command" => "mix test --only focus",
        "workdir" => "apps/core",
        "justification" => "run the focused test"
      })

    state =
      state(
        %{id => %{permission: :execute, safety: :normal, requested_at: asked}},
        %{},
        %{
          id => %{
            op_type: "run_command",
            input: input,
            parent_id: agent,
            approval_prefix: "mix test"
          }
        }
      )

    assert {:reply, [row], ^state} = RunServer.handle_call(:pending_interactions, nil, state)

    assert %{
             node_id: ^id,
             agent_id: ^agent,
             tool: "run_command",
             command: "mix test --only focus",
             cwd: "/work/project/apps/core",
             path: nil,
             reason: "run the focused test",
             command_family: "mix test",
             classification: :normal,
             permission: :execute,
             requested_at: ^asked,
             allowed_decisions: [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
           } = row

    assert Map.keys(row) |> Enum.sort() == Enum.sort(@row_keys)
    assert Jason.encode!(row)
  end

  test "a dangerous command offers no family; a file tool names its path and the root" do
    shell = Ecto.UUID.generate()
    edit = Ecto.UUID.generate()

    state =
      state(
        %{
          shell => %{permission: :execute, safety: :dangerous},
          edit => %{permission: :write}
        },
        %{},
        %{
          shell => %{op_type: "run_command", input: Jason.encode!(%{"command" => "rm -rf build"})},
          edit => %{op_type: "edit_file", input: Jason.encode!(%{"path" => "lib/a.ex"})}
        }
      )

    assert {:reply, rows, ^state} = RunServer.handle_call(:pending_interactions, nil, state)
    by_id = Map.new(rows, &{&1.node_id, &1})

    assert %{
             classification: :dangerous,
             command_family: nil,
             cwd: "/work/project",
             allowed_decisions: [:approve, :approve_run, :deny, :deny_stop]
           } = by_id[shell]

    assert %{
             tool: "edit_file",
             command: nil,
             path: "lib/a.ex",
             cwd: "/work/project",
             classification: :normal,
             command_family: nil
           } = by_id[edit]
  end

  test "a command raised without a stored class is classified from its text" do
    id = Ecto.UUID.generate()

    state =
      state(%{id => %{permission: :execute}}, %{}, %{
        id => %{op_type: "run_command", input: Jason.encode!(%{"command" => "ls -la"})}
      })

    assert {:reply, [row], ^state} = RunServer.handle_call(:pending_interactions, nil, state)

    assert row.classification ==
             SwarmCode.Domain.Tools.CommandSafety.classify("ls -la")
  end

  test "questions and options use byte limits and one row per interaction" do
    id = Ecto.UUID.generate()
    huge = String.duplicate("🦊", 5000)

    question = %{
      "question" => huge,
      "options" => List.duplicate(%{"label" => huge, "description" => huge}, 20),
      "multi_select" => true,
      "pid" => self()
    }

    state =
      state(
        %{},
        %{id => %{questions: List.duplicate(question, 8), from: self(), timer: make_ref()}},
        %{}
      )

    assert {:reply, [%{kind: :question, questions: questions} = row], ^state} =
             RunServer.handle_call(:pending_interactions, nil, state)

    assert Map.keys(row) |> Enum.sort() == Enum.sort(@row_keys)
    assert %{allowed_decisions: [], command: nil, cwd: nil, classification: nil} = row

    assert length(questions) == 4

    for q <- questions do
      assert byte_size(q.question) <= 4000 and String.valid?(q.question)
      assert q.multiple == true
      assert length(q.options) == 12

      for option <- q.options do
        assert byte_size(option.label) <= 500 and String.valid?(option.label)
        assert byte_size(option.description) <= 500 and String.valid?(option.description)
      end
    end
  end

  test "combined interactions never exceed 64 and malformed inputs are safe" do
    approvals = Map.new(1..80, fn _ -> {Ecto.UUID.generate(), %{permission: :write}} end)

    questions = %{
      Ecto.UUID.generate() => %{
        questions: [self(), %{"options" => self(), "multi_select" => self()}]
      }
    }

    state = state(approvals, questions, %{})
    assert {:reply, rows, ^state} = RunServer.handle_call(:pending_interactions, nil, state)
    assert length(rows) == 64
    state = state(%{}, questions, %{})
    assert {:reply, rows, ^state} = RunServer.handle_call(:pending_interactions, nil, state)
    assert Jason.encode!(rows)
  end

  test "oversized or deeply nested tool input is never reflected raw" do
    id = Ecto.UUID.generate()

    for input <- [
          String.duplicate("x", 50_000),
          String.duplicate("{\"a\":", 1000) <> "0" <> String.duplicate("}", 1000),
          "not JSON SECRET"
        ] do
      state =
        state(%{id => %{permission: :write}}, %{}, %{id => %{input: input, op_type: "write_file"}})

      assert {:reply, [row], ^state} = RunServer.handle_call(:pending_interactions, nil, state)
      assert byte_size(row.args) <= 8192
      refute row.args =~ "SECRET"
    end
  end

  defp state(approvals, questions, nodes),
    do: %{
      approvals: approvals,
      questions: questions,
      nodes: nodes,
      project: %{root_path: "/work/project"},
      providers: %{secret: "DO NOT COPY"}
    }
end
