defmodule SwarmCodeCLI.UI.Pass73WorkflowKeywordTest do
  @moduledoc "pass73 T5: the whole word \"workflow\" outside backticks, in a message that is not a command."
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.WorkflowKeyword

  defp words(text),
    do: for({start, length} <- WorkflowKeyword.spans(text), do: binary_part(text, start, length))

  test "the whole word in any case, singular or plural, is a keyword" do
    assert words("build a workflow that tests the API") == ["workflow"]
    assert words("Workflows for releases, and one WORKFLOW more") == ["Workflows", "WORKFLOW"]
    assert words("workflow") == ["workflow"]
    assert words("make it a workflow.") == ["workflow"]
    assert words("workflow: scan, plan, fix") == ["workflow"]
    assert words("the workflow's steps (workflow)") == ["workflow", "workflow"]
    assert words("\"workflow\" and 'workflows'") == ["workflow", "workflows"]
  end

  test "a word that only contains it, a path or an identifier is not" do
    for text <- [
          "workflowish",
          "subworkflow",
          "create-workflow the thing",
          "workflow-based design",
          "see priv/workflows/ for examples",
          "open workflow.ex",
          "the workflow_id column",
          "@workflow #workflows $workflow",
          "workflows2 and 3workflow",
          "a workflow:step label"
        ] do
      assert WorkflowKeyword.spans(text) == [], text
    end
  end

  test "backticks hide it: inline code, fenced blocks and runs of any length" do
    assert words("run `workflow` now") == []
    assert words("``a `workflow` b`` then workflow") == ["workflow"]
    assert words("```\nworkflow\n```\nplease make a workflow") == ["workflow"]
    # An unmatched run is literal text, so the word after it counts.
    assert words("a ` then workflow") == ["workflow"]
    assert words("`x` workflow `y`") == ["workflow"]
  end

  test "a slash command never has one, whatever it says" do
    assert WorkflowKeyword.spans("/swarm build a workflow") == []
    assert WorkflowKeyword.spans("  /plan the workflow") == []
    refute WorkflowKeyword.routes?("/create-workflow a workflow")
    assert WorkflowKeyword.routes?("write a workflow")
  end

  test "segments rebuild the text and grapheme spans count graphemes" do
    text = "héllo 👩‍💻 workflow and workflows"
    segments = WorkflowKeyword.segments(text)
    assert Enum.map_join(segments, &elem(&1, 1)) == text

    assert [
             {:text, "héllo 👩‍💻 "},
             {:keyword, "workflow"},
             {:text, " and "},
             {:keyword, "workflows"}
           ] =
             segments

    assert WorkflowKeyword.grapheme_spans(text) == [{8, 8}, {21, 9}]
    assert WorkflowKeyword.segments("no keyword") == [{:text, "no keyword"}]
    assert WorkflowKeyword.segments("") == []
  end

  test "invalid UTF-8 and non-binaries have no keyword and never raise" do
    assert WorkflowKeyword.spans(<<0xFF, "workflow">>) == []
    assert WorkflowKeyword.spans(nil) == []
    assert WorkflowKeyword.grapheme_spans(:x) == []
  end

  test "the routed command and the hint" do
    assert WorkflowKeyword.command("  a workflow for tests \n") ==
             "/create-workflow a workflow for tests"

    assert WorkflowKeyword.hint("^S") == "workflow · sends as /create-workflow · ^S plain message"
  end

  test "many backtick runs stay linear" do
    text = String.duplicate("` `` ", 20_000) <> "workflow"
    {micros, spans} = :timer.tc(fn -> WorkflowKeyword.spans(text) end)
    assert length(spans) <= 1
    assert micros < 2_000_000
  end
end
