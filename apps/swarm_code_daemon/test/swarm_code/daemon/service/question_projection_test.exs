defmodule SwarmCode.Daemon.Service.QuestionProjectionTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Daemon.Service.QuestionProjection, as: P
  alias SwarmCodeCLI.UI.DataSource.DTO

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

  # pass75 interview (task 206): the wire shape of one ask's questions.
  defp two_rows do
    base = %{"node_id" => Ecto.UUID.generate(), "expected_revision" => 7}

    questions = [
      %{
        index: 0,
        question: "Which format?",
        header: "Format",
        total: 2,
        multiple: false,
        options: [%{label: "CSV", description: "One row per ticket"}]
      },
      %{
        index: 1,
        question: "Which fields?",
        header: "Fields",
        total: 2,
        multiple: true,
        options: [%{label: "Status", description: ""}]
      }
    ]

    P.rows(base, questions, %{agent_id: "a", requested_at: 5})
  end

  test "the wire question map has exactly the pass-75 keys" do
    for row <- two_rows() do
      assert Map.keys(row["question"]) |> Enum.sort() ==
               ~w(agent_id header index multiple options prompt requested_at total)

      for option <- row["question"]["options"],
          do: assert(Map.keys(option) |> Enum.sort() == ~w(description id label))
    end
  end

  test "the CLI DTO decodes the projected map" do
    [_, second] = two_rows()

    assert {:ok, %DTO.Question{index: 1, header: "Fields", total: 2}} =
             DTO.Question.decode(second["question"])
  end

  test "an old map decodes with defaults" do
    [first, _] = two_rows()

    old =
      first["question"]
      |> Map.drop(~w(index header total agent_id requested_at))
      |> Map.update!("options", fn options ->
        Enum.map(options, &Map.delete(&1, "description"))
      end)

    assert {:ok,
            %DTO.Question{
              index: 0,
              header: nil,
              total: 0,
              agent_id: nil,
              requested_at: nil,
              options: [%DTO.QuestionOption{description: ""}]
            }} = DTO.Question.decode(old)
  end

  test "the facts reach the row and the description is its own field" do
    base = %{"node_id" => Ecto.UUID.generate(), "expected_revision" => 1}

    q = %{
      question: "Which format?",
      header: "Format",
      total: 3,
      options: [%{id: "x", label: "CSV", description: "One row per ticket"}]
    }

    [row] = P.rows(base, [q], %{agent_id: "a", requested_at: 5})

    assert %{
             "index" => 0,
             "header" => "Format",
             "total" => 3,
             "agent_id" => "a",
             "requested_at" => 5
           } = row["question"]

    assert [%{"label" => "CSV", "description" => "One row per ticket"}] =
             row["question"]["options"]

    assert [legacy] = P.rows(base, [q])
    assert legacy["question"]["agent_id"] == nil
  end
end
