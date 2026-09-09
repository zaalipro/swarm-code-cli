defmodule SwarmCode.Daemon.Service.QuestionProjectionTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Service.QuestionProjection, as: P

  test "remaining questions preserve their original index and distinct option identities" do
    base = %{"node_id" => Ecto.UUID.generate(), "expected_revision" => 3}

    q = %{
      index: 2,
      question: "Choose",
      multiple: true,
      options: [%{label: "One", description: "First"}, %{label: "One", description: "Second"}]
    }

    [row] = P.rows(base, [q])
    assert P.index(base["node_id"], 3, row["id"]) == 2
    assert P.index(base["node_id"], 4, row["id"]) == nil
    [a, b] = row["question"]["options"]
    assert a["id"] != b["id"]
    assert row["allowed_actions"] == ["answer_question"]
    assert {:ok, [0, 1]} = P.selection(row, [a["id"], b["id"]], "")
    assert {:error, _} = P.selection(row, ["forged"], "")
    assert {:error, _} = P.selection(row, [a["id"], a["id"]], "")
    assert {:ok, []} = P.selection(row, [], "My answer")
    assert {:error, _} = P.selection(row, [], "")
    assert {:error, _} = P.selection(row, [], String.duplicate("x", 4001))
  end
end
