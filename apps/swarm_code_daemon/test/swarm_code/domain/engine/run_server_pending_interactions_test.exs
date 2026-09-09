defmodule SwarmCode.Domain.Engine.RunServerPendingInteractionsTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Domain.Engine.RunServer

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

    assert Map.keys(row) |> Enum.sort() ==
             Enum.sort([:node_id, :kind, :permission, :tool, :args, :questions])
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

    assert {:reply, [%{kind: :question, questions: questions}], ^state} =
             RunServer.handle_call(:pending_interactions, nil, state)

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
      providers: %{secret: "DO NOT COPY"}
    }
end
