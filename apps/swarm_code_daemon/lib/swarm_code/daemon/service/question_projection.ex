defmodule SwarmCode.Daemon.Service.QuestionProjection do
  @moduledoc "Stable presentation identities for indexed questions within a pending interaction."

  def id(node, revision, index) do
    <<value::binary-size(16), _::binary>> =
      :crypto.hash(:sha256, :erlang.term_to_binary({node, revision, index}))

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = Base.encode16(value, case: :lower)

    Enum.join([a, b, c, d, e], "-")
  end

  def index(node, revision, id), do: Enum.find(0..3, &(id(node, revision, &1) == id))

  @doc """
  One wire row per unanswered question of an ask. pass75: each question map
  carries its index, header and the asked total, and `meta` names the asker
  and when it asked (unix ms); an option's description is its own field.
  """
  def rows(base, questions), do: rows(base, questions, %{agent_id: nil, requested_at: nil})

  def rows(base, questions, meta) do
    questions
    |> Enum.take(4)
    |> Enum.with_index()
    |> Enum.map(fn {q, fallback} ->
      index = Map.get(q, :index, fallback)
      question_id = id(base["node_id"], base["expected_revision"], index)

      options =
        (q[:options] || [])
        |> Enum.take(12)
        |> Enum.with_index()
        |> Enum.map(fn {o, i} ->
          %{
            "id" => question_id <> ":" <> Integer.to_string(i),
            "label" => o[:label] || "",
            "description" => o[:description] || ""
          }
        end)

      Map.merge(base, %{
        "id" => question_id,
        "kind" => "question",
        "approval" => nil,
        "question" => %{
          "prompt" => q[:question] || "",
          "options" => options,
          "multiple" => q[:multiple] == true,
          "index" => index,
          "header" => q[:header],
          "total" => q[:total] || length(questions),
          "agent_id" => meta.agent_id,
          "requested_at" => meta.requested_at
        },
        "allowed_actions" => ["answer_question"]
      })
    end)
  end

  def selection(%{"question" => q}, ids, custom) when is_list(ids) and is_binary(custom) do
    options = q["options"]
    indices = Enum.map(ids, fn id -> Enum.find_index(options, &(&1["id"] == id)) end)

    cond do
      byte_size(custom) > 4000 or not String.valid?(custom) ->
        {:error, :invalid_request}

      ids == [] and String.trim(custom) == "" ->
        {:error, :invalid_request}

      Enum.any?(indices, &is_nil/1) or length(Enum.uniq(indices)) != length(indices) ->
        {:error, :invalid_request}

      not q["multiple"] and length(indices) > 1 ->
        {:error, :invalid_request}

      true ->
        {:ok, indices}
    end
  end

  def selection(_, _, _), do: {:error, :invalid_request}
end
