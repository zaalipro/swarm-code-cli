defmodule SwarmCode.Domain.Engine.RunServerAnswerQuestionTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Domain.Engine.{RunServer, Questions, Events}
  alias SwarmCode.Domain.LLM.Chunks

  test "partial answers retain original indices and complete in asked order" do
    {state, node, tag} =
      fixture([question("First", ["A", "B"]), question("Second", ["C", "D"], true)])

    Questions.put(state.conversation.id, state.run.id, node)
    Events.subscribe(state.conversation.id)
    assert {:reply, :ok, partial} = answer(state, node, 1, [1, 0], "extra")
    refute_received {^tag, _}
    assert Questions.pending?(state.run.id, node)

    assert {:reply, [%{questions: [%{index: 0, multiple: false}]}], _} =
             RunServer.handle_call(:pending_interactions, nil, partial)

    assert {:reply, {:error, :stale_question}, ^partial} = answer(partial, node, 1, [0], "")
    assert {:reply, :ok, completed} = answer(partial, node, 0, [0], "")

    assert_receive {^tag,
                    {:ok,
                     [
                       %{"labels" => ["A"], "custom" => ""},
                       %{"labels" => ["D", "C"], "custom" => "extra"}
                     ]}}

    assert completed.questions == %{}
    refute Questions.pending?(state.run.id, node)
    assert_receive {:question_cleared, _, ^node}
    assert {:reply, {:error, :stale_question}, ^completed} = answer(completed, node, 0, [0], "")
  end

  test "one question accepts a custom-only answer up to 4000 UTF-8 bytes" do
    {state, node, tag} = fixture([question("Explain", [])])
    custom = String.duplicate("🦊", 1000)
    assert {:reply, :ok, _} = answer(state, node, 0, [], custom)
    assert_receive {^tag, {:ok, [%{"labels" => [], "custom" => ^custom}]}}
  end

  test "invalid answers do not alter any partial state or reply to caller" do
    {state, node, tag} =
      fixture([question("Pick one", ["A", "B"]), question("Several", ["C", "D"], true)])

    for {index, indices, custom} <- [
          {-1, [0], ""},
          {2, [0], ""},
          {0, [-1], ""},
          {0, [2], ""},
          {0, [0, 0], ""},
          {0, [0, 1], ""},
          {0, [], "  "},
          {0, ["0"], ""},
          {0, [0], String.duplicate("🦊", 1001)},
          {0, [0], <<255>>},
          {0, [0], nil}
        ] do
      assert {:reply, {:error, :invalid_answer}, ^state} =
               answer(state, node, index, indices, custom)
    end

    refute_received {^tag, _}
  end

  test "multi_select drives projection and permits multiple distinct options" do
    {state, node, tag} = fixture([question("Pick", ["one", "two"], true)])

    assert {:reply, [%{questions: [%{index: 0, multiple: true}]}], _} =
             RunServer.handle_call(:pending_interactions, nil, state)

    assert {:reply, :ok, _} = answer(state, node, 0, [0, 1], "")
    assert_receive {^tag, {:ok, [%{"labels" => ["one", "two"]}]}}
  end

  test "absent run is safely reported" do
    assert {:error, :not_running} =
             RunServer.answer_question(Ecto.UUID.generate(), Ecto.UUID.generate(), 0, [0])
  end

  defp answer(state, node, index, indices, custom),
    do: RunServer.handle_call({:answer_question, node, index, indices, custom}, nil, state)

  defp question(text, labels, multiple \\ false),
    do: %{
      "question" => text,
      "options" => Enum.map(labels, &%{"label" => &1}),
      "multi_select" => multiple
    }

  defp fixture(questions) do
    node = Ecto.UUID.generate()
    tag = make_ref()

    state = %{
      questions: %{node => %{questions: questions, from: {self(), tag}, timer: nil}},
      approvals: %{},
      nodes: %{},
      stream: %{},
      dirty: MapSet.new(),
      dirty_cols: %{},
      persist_pending: MapSet.new(),
      uninserted: MapSet.new(),
      unsaved: %{},
      stripped: MapSet.new(),
      totals_written: {0, 0, nil},
      pending_delta: Chunks.new(),
      pending_reasoning: Chunks.new(),
      assistant_message: nil,
      run_dirty: false,
      conversation: %{id: Ecto.UUID.generate()},
      run: %{id: Ecto.UUID.generate(), tokens_in: 0, tokens_out: 0, cost_usd: nil}
    }

    {state, node, tag}
  end
end
