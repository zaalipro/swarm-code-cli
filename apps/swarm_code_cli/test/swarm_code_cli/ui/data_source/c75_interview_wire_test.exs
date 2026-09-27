defmodule SwarmCodeCLI.UI.DataSource.C75InterviewWireTest do
  @moduledoc """
  pass 75 (task 254): the interview's wire facts cross real JSON through the
  daemon codec on the CLI side: a newer daemon's question and needs-you
  facts decode intact, an older daemon's body decodes with the defaults, and
  the question DTO stays closed.
  """
  use ExUnit.Case, async: true
  alias SwarmCode.Protocol.{Envelope, Message, Scope}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec
  alias SwarmCodeCLI.TestSupport.HiveWire, as: Wire

  @conversation "22222222-2222-4222-8222-222222222222"
  @node "44444444-4444-4444-8444-444444444444"
  @lead "55555555-5555-4555-8555-555555555555"
  @interaction "66666666-6666-4666-8666-666666666666"
  @nonce String.duplicate("A", 43)
  @scope %Scope{kind: :conversation, id: @conversation, generation: 2}

  @question %{
    "prompt" => "Which format should the ticket export produce?",
    "options" => [
      %{
        "id" => "csv",
        "label" => "CSV",
        "description" => "One row per ticket; opens in Excel and Sheets."
      },
      %{
        "id" => "json",
        "label" => "JSON",
        "description" => "Nested comments and tags; the shape a re-import reads."
      }
    ],
    "multiple" => false,
    "index" => 1,
    "header" => "Format",
    "total" => 3,
    "agent_id" => @lead,
    "requested_at" => 1_788_436_790_000
  }

  @need %{
    "agent_id" => @lead,
    "node_id" => @node,
    "agent_name" => "Lead",
    "kind" => "question",
    "text" => "Which format should the ticket export produce?",
    "reason" => "",
    "requested_at" => 1_788_436_790_000,
    "questions" => ["Format", "Fields", "Delivery"],
    "options" => 4
  }

  defp through_json(message) do
    {:ok, bytes} = Envelope.encode(message)
    {:ok, decoded} = Envelope.decode(IO.iodata_to_binary(bytes))
    decoded
  end

  defp watch,
    do: %Watch{
      watch_ref: "watch-1",
      slot: :workspace,
      scope: @scope,
      generation: 2,
      page_size: 20,
      byte_limit: 262_144
    }

  defp event(sequence, body),
    do: %Message{
      version: 1,
      type: :event,
      request_id: nil,
      nonce: @nonce,
      scope: @scope,
      sequence: sequence,
      occurred_at: "2026-09-27T00:00:00Z",
      body: body
    }

  defp interaction(question),
    do: %{
      "id" => @interaction,
      "run_id" => Wire.run_id(),
      "node_id" => @node,
      "conversation_id" => @conversation,
      "kind" => "question",
      "expected_revision" => 7,
      "state" => "pending",
      "question" => question,
      "approval" => nil,
      "allowed_actions" => ["answer_question"],
      "urgency" => "normal",
      "deadline" => 0,
      "created_at" => 1_788_436_800_000
    }

  # An interaction_upsert delta, the path a question row arrives on.
  defp upsert(question) do
    delta = %{
      "kind" => "interaction_upsert",
      "entity_id" => @interaction,
      "run_id" => Wire.run_id(),
      "conversation_id" => @conversation,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => interaction(question),
      "sequence" => 4,
      "revision" => 3
    }

    message = event(4, %{"op" => "delta", "watch_ref" => "watch-1", "value" => delta})
    Codec.event(through_json(message), watch(), @nonce)
  end

  defp snapshot(run) do
    value = Map.put(Wire.workspace(), "runs", [run])

    message =
      event(9, %{
        "op" => "watch_ready",
        "watch_ref" => "watch-1",
        "revision" => 7,
        "body_kind" => "workspace_snapshot",
        "value" => value
      })

    Codec.event(through_json(message), watch(), @nonce)
  end

  test "a question with every pass-75 key decodes with its facts" do
    assert {:ok, %Delivery{kind: :delta, body: %Delta{body: %DTO.PendingInteraction{} = row}}} =
             upsert(@question)

    q = row.question

    assert {q.index, q.header, q.total, q.agent_id, q.requested_at} ==
             {1, "Format", 3, @lead, 1_788_436_790_000}

    assert [%DTO.QuestionOption{id: "csv", label: "CSV"} = csv, %DTO.QuestionOption{}] =
             q.options

    assert csv.description == "One row per ticket; opens in Excel and Sheets."
  end

  test "an older daemon's question, without the five keys and descriptions, gets the defaults" do
    old =
      @question
      |> Map.drop(["index", "header", "total", "agent_id", "requested_at"])
      |> Map.update!("options", fn options ->
        Enum.map(options, &Map.delete(&1, "description"))
      end)

    assert {:ok, %Delivery{body: %Delta{body: %DTO.PendingInteraction{question: q}}}} =
             upsert(old)

    assert {q.index, q.header, q.total, q.agent_id, q.requested_at} == {0, nil, 0, nil, nil}
    assert Enum.map(q.options, & &1.description) == ["", ""]
    assert q.prompt == @question["prompt"]
  end

  test "a needs-you entry carries its questions and options, and defaults without them" do
    run = Map.put(Wire.run_summary(), "needs_you", [@need])
    assert {:ok, %Delivery{kind: :watch_ready, body: page}} = snapshot(run)
    assert [%DTO.RunSummary{needs_you: [need]}] = page.runs
    assert %DTO.NeedsYou{kind: :question, options: 4} = need
    assert need.questions == ["Format", "Fields", "Delivery"]

    older = Map.drop(@need, ["questions", "options"])
    run = Map.put(Wire.run_summary(), "needs_you", [older])
    assert {:ok, %Delivery{body: page}} = snapshot(run)
    assert [%DTO.RunSummary{needs_you: [%DTO.NeedsYou{questions: [], options: 0}]}] = page.runs
  end

  test "the question DTO stays closed: an unknown key is rejected" do
    assert {:error, _} = upsert(Map.put(@question, "reason", "Because."))
  end
end
