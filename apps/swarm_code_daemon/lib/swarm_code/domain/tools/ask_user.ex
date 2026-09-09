defmodule SwarmCode.Domain.Tools.AskUser do
  @moduledoc """
  Interview mode (spec 10 §1): the agent asks the user 1–4 multiple-choice
  questions and waits for the answers, exactly like an approval waits for a
  decision.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.RunServer

  @impl true
  def name, do: "ask_user"

  @impl true
  def description,
    do:
      "Ask the user 1-4 multiple-choice questions and wait for the answers. Use it when a " <>
        "decision is yours to ask, not to make: an ambiguous request, several valid " <>
        "approaches, a destructive choice. Give each question 2-4 concrete options; the user " <>
        "can also answer with their own text."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "questions" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 4,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "question" => %{"type" => "string"},
              "header" => %{"type" => "string", "description" => "≤ 12 chars chip"},
              "options" => %{
                "type" => "array",
                "minItems" => 2,
                "maxItems" => 4,
                "items" => %{
                  "type" => "object",
                  "properties" => %{
                    "label" => %{"type" => "string"},
                    "description" => %{"type" => "string"}
                  },
                  "required" => ["label"]
                }
              },
              "multi_select" => %{"type" => "boolean"}
            },
            "required" => ["question", "options"]
          }
        }
      },
      "required" => ["questions"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args) do
    case normalize(args["questions"]) do
      [%{"question" => q} | _] -> "asked " <> String.slice(to_string(q), 0, 60)
      _ -> "asked the user"
    end
  end

  @impl true
  def run(args, ctx, progress) do
    case normalize(args["questions"]) do
      [] ->
        {:error, "questions must be a non-empty array"}

      questions ->
        progress.(nil, "waiting for the user")

        case RunServer.ask_user(ctx.run_id, ctx.node_id, questions) do
          {:ok, answers} ->
            progress.(100, "answered")
            {:ok, format(questions, answers)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  The tool result the model reads:

      Answers:
      1. Which database? → Postgres — custom: with PostGIS
  """
  @spec format([map()], [map()]) :: String.t()
  def format(questions, answers) do
    lines =
      questions
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {q, i} ->
        "#{i + 1}. #{q["question"]} → #{answer_text(Enum.at(answers, i))}"
      end)

    "Answers:\n" <> lines
  end

  defp answer_text(nil), do: "skipped"

  defp answer_text(answer) do
    labels = answer["labels"] || []
    custom = answer["custom"]

    text =
      cond do
        labels != [] -> Enum.join(labels, ", ")
        is_binary(custom) and String.trim(custom) != "" -> "other"
        true -> "skipped"
      end

    if is_binary(custom) and String.trim(custom) != "" and labels != [] do
      text <> " — custom: " <> String.trim(custom)
    else
      if text == "other", do: "custom: " <> String.trim(custom), else: text
    end
  end

  # Normalises whatever the model sent into a list of question maps with string
  # keys and at least two options.
  @spec normalize(term()) :: [map()]
  def normalize(questions) when is_list(questions) do
    questions
    |> Enum.take(4)
    |> Enum.map(fn q ->
      q = stringify(q)

      %{
        "question" => to_string(q["question"] || ""),
        "header" => q["header"] && String.slice(to_string(q["header"]), 0, 12),
        "multi_select" => q["multi_select"] == true,
        "options" =>
          (q["options"] || [])
          |> Enum.take(4)
          |> Enum.map(fn o ->
            o = stringify(o)
            %{"label" => to_string(o["label"] || ""), "description" => o["description"]}
          end)
          |> Enum.reject(&(&1["label"] == ""))
      }
    end)
    |> Enum.reject(&(&1["question"] == "" or length(&1["options"]) < 2))
  end

  def normalize(_other), do: []

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp stringify(_other), do: %{}
end
