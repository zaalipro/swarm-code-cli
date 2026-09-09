defmodule SwarmCode.Domain.Engine.PromptsTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Conversations.Message
  alias SwarmCode.Domain.Engine.Prompts
  alias SwarmCode.Domain.Projects.Project

  @project %Project{name: "swarm-code", root_path: "/tmp/swarm-code"}

  test "assistant/1" do
    text = Prompts.assistant(@project)
    assert String.starts_with?(text, "You are SwarmCode")
    assert text =~ "swarm-code"
    assert text =~ "/tmp/swarm-code"
  end

  test "lead/2" do
    assert Prompts.lead(@project, 3) =~ "at most 3 run at once"
  end

  test "sub_agent/2" do
    assert Prompts.sub_agent(@project, "Explorer") =~ ~s(sub-agent "Explorer")
  end

  test "history_to_messages/1" do
    history = [
      %Message{role: "user", content: "hi"},
      %Message{role: "assistant", content: ""},
      %Message{role: "assistant", content: "hello"},
      %Message{role: "swarm", content: "report"},
      %Message{role: "error", content: "boom"}
    ]

    assert Prompts.history_to_messages(history) == [
             %{role: "user", content: "hi"},
             %{role: "assistant", content: "hello"},
             %{role: "user", content: "[Swarm report]\nreport"}
           ]
  end

  test "sub_agent_user/2" do
    assert Prompts.sub_agent_user("task", nil) == "task"
    assert Prompts.sub_agent_user("task", "  ") == "task"
    assert Prompts.sub_agent_user("task", "ctx") == "task\n\nContext from the lead:\nctx"
  end

  test "suffix/1 injects the conversation goal into every agent" do
    opts = [goal: "  ship the beta  ", mode: "build"]
    line = "Conversation goal (keep it in mind for every answer): ship the beta"

    assert Prompts.assistant(@project, opts) =~ line
    assert Prompts.lead(@project, 2, opts) =~ line
    assert Prompts.sub_agent(@project, "Explorer", opts) =~ line

    refute Prompts.assistant(@project) =~ "Conversation goal"
    refute Prompts.assistant(@project, goal: "   ") =~ "Conversation goal"
  end

  test "suffix/1 adds the plan-mode instruction" do
    plan = Prompts.assistant(@project, mode: "plan")
    assert plan =~ "PLAN MODE: do not modify anything"
    assert plan =~ "## Open questions"
    refute Prompts.assistant(@project, mode: "build") =~ "PLAN MODE"
    assert Prompts.sub_agent(@project, "Sub", mode: "plan") =~ "PLAN MODE"
    assert Prompts.lead(@project, 2, mode: "plan") =~ "PLAN MODE"
  end

  # ------------------------------------------------------------- spec 51 §6.6

  describe "pass45 (spec 51 §6.6)" do
    test "compact/2 names the messages the window could not read" do
      assert Prompts.compact() =~ "Compact this conversation"
      refute Prompts.compact() =~ "were not part of this window"
      refute Prompts.compact("the parser") =~ "were not part of this window"

      with_omitted = Prompts.compact("", omitted: 12)
      assert with_omitted =~ "The 12 oldest messages of this conversation were not part of this"

      both = Prompts.compact("the parser", omitted: 3)
      assert both =~ "Pay particular attention to: the parser"
      assert both =~ "The 3 oldest messages"

      # Nothing omitted, a negative count, or no option: no line.
      refute Prompts.compact("", omitted: 0) =~ "were not part of this window"
      refute Prompts.compact("", omitted: -2) =~ "were not part of this window"
    end
  end
end
