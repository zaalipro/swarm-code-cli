defmodule SwarmCode.CommandsTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Commands

  test "catalogue exposes all builtins" do
    assert Enum.map(Commands.catalogue(), & &1.name) ==
             ~w(swarm goal plan review effort swarm_effort rewind stop resume workflow workflows create-workflow ultra consensus deep_research attach compact)
  end

  test "catalogue ranking" do
    assert Enum.map(
             Commands.catalogue("/research",
               workflows: [%{name: "arch-review"}, %{name: "deep_research"}]
             ),
             & &1.name
           ) == ["deep_research"]

    assert hd(Commands.catalogue("/sw")).name == "swarm"
  end

  test "precedence" do
    xs =
      Commands.catalogue("/workflow",
        workflows: [%{name: "workflow"}],
        custom: [%{name: "workflow", body: "x"}]
      )

    assert Enum.count(xs, &(&1.name == "workflow")) == 1
    assert Enum.find(xs, &(&1.name == "workflow")).kind == :builtin
  end

  test "mode and effort" do
    assert {:ok, %{name: "effort", effort: :high}} = Commands.parse("/effort high")
    assert {:ok, %{name: "plan", mode: :plan}} = Commands.parse("/plan")
    assert {:ok, %{name: "swarm_effort", effort: :max}} = Commands.parse("/swarm_effort max")
    assert {:error, %{type: :invalid_effort}} = Commands.parse("/effort extreme")
  end

  test "attachment staging parses a bounded path" do
    assert {:ok, %{action: :attach_file, path: "images/shot.png"}} =
             Commands.parse("/attach images/shot.png")

    assert {:error, %{type: :missing_argument}} = Commands.parse("/attach")
  end

  test "swarm and goal" do
    assert {:ok,
            %{name: "swarm", task: "/goal ship it", nested: %{name: "goal", text: "ship it"}}} =
             Commands.parse("/swarm /goal ship it")

    assert {:ok, %{name: "goal", text: "ship it", mode: :goal}} = Commands.parse("/goal ship it")
  end

  test "bounded errors" do
    assert {:error, %{type: :unknown_command}} = Commands.parse("/wat")
    assert {:error, %{type: :missing_argument}} = Commands.parse("/swarm")
    assert {:error, %{type: :invalid_command}} = Commands.parse("hello")
  end

  test "custom expansion" do
    custom = [
      %{
        name: "ship",
        description: "Ship it",
        body: "Do $ARGUMENTS",
        mode: "plan",
        swarm: true,
        scope: :project
      }
    ]

    assert {:ok, result} = Commands.parse("/ship now", custom: custom)

    assert result.kind == :custom and result.prompt == "Do now" and result.mode == :plan and
             result.swarm
  end

  defmodule Definition do
    defstruct [:name, :scope, meta: %{}]
  end

  @workflows [
    %{name: "arch-review", scope: :project, meta: %{description: "Review architecture"}}
  ]

  test "six modes are exposed in menu order" do
    assert Commands.mode_values() == ~w(build plan goal ultra workflow consensus)
    assert length(Commands.modes()) == 6
  end

  test "prefix matches precede word boundaries and arbitrary substrings do not match" do
    custom = [%{name: "research", body: "research"}, %{name: "team.arch", body: "arch"}]

    assert Enum.map(Commands.catalogue("/research", custom: custom), & &1.name) == [
             "research",
             "deep_research"
           ]

    assert Enum.map(Commands.catalogue("/arch", custom: custom, workflows: @workflows), & &1.name) ==
             ["arch-review", "team.arch"]

    assert Commands.catalogue("/ese") == []
  end

  test "parser shares builtin workflow and custom precedence" do
    custom = [%{name: "stop", body: "BAD"}, %{name: "arch-review", body: "BAD"}]
    workflows = [%{name: "stop"} | @workflows]

    assert {:ok, %{kind: :builtin, action: :stop_all}} =
             Commands.parse("/stop", custom: custom, workflows: workflows)

    assert {:ok, %{kind: :workflow, action: :launch_workflow}} =
             Commands.parse("/arch-review", custom: custom, workflows: workflows)
  end

  test "struct and JSON metadata are accepted without Access or atom conversion" do
    workflows = [
      %Definition{
        name: "audit",
        scope: :project,
        meta: %{description: "Audit", args: %{target: %{type: :path}}}
      }
    ]

    assert [%{name: "audit", args: "target=<path>", desc: "Audit"}] =
             Commands.catalogue("/audit", workflows: workflows)

    assert {:ok, %{prompt: "Do this", mode: :plan, swarm: true}} =
             Commands.parse("/ship this",
               custom: [
                 %{"name" => "ship", "body" => "Do $ARGUMENTS", "mode" => "plan", "swarm" => true}
               ]
             )
  end

  test "project custom commands override global duplicates regardless of input order" do
    custom = [
      %{name: "ship", body: "global", scope: :global},
      %{name: "ship", body: "project", scope: :project}
    ]

    assert {:ok, %{prompt: "project"}} = Commands.parse("/SHIP", custom: custom)
  end

  test "effort values can be limited to model supported fixed atoms" do
    assert {:ok, %{action: :set_effort, effort: :high, target: :chat}} =
             Commands.parse("/effort HIGH")

    assert {:ok, %{effort: :xhigh}} = Commands.parse("/effort xhigh", efforts: [:low, :xhigh])
    assert {:error, %{type: :invalid_effort}} = Commands.parse("/effort high", efforts: [:low])
    assert {:error, %{type: :missing_argument}} = Commands.parse("/swarm_effort")
  end

  test "mode commands distinguish toggles settings and turns" do
    assert {:ok, %{action: :toggle_mode, mode: :plan}} = Commands.parse("/plan")
    assert {:ok, %{action: :toggle_mode, mode: :ultra}} = Commands.parse("/ultra")
    assert {:ok, %{action: :set_mode, mode: :ultra}} = Commands.parse("/ultra on")
    assert {:ok, %{action: :set_mode, mode: :build}} = Commands.parse("/ultra off")
    assert {:error, %{type: :invalid_argument}} = Commands.parse("/ultra maybe")
    assert {:ok, %{action: :set_mode, mode: :consensus}} = Commands.parse("/consensus")

    assert {:ok, %{action: :start_turn, task: "design it", mode: :consensus}} =
             Commands.parse("/consensus design it")

    assert {:ok, %{action: :disable_workflow_authoring}} = Commands.parse("/create-workflow off")

    assert {:ok, %{action: :author_workflow, mode: :workflow, prompt: prompt}} =
             Commands.parse("/create-workflow")

    assert String.contains?(prompt, "Ask me")
  end

  test "goal composite intent is explicit and arbitrary nested commands are text" do
    assert {:ok, %{action: :show_goal}} = Commands.parse("/goal")

    assert {:ok, %{action: :pursue_goal, execution: :chat, text: "ship it"}} =
             Commands.parse("/goal ship it")

    assert {:ok,
            %{
              name: "swarm",
              action: :pursue_goal,
              execution: :swarm,
              text: "ship it",
              nested: %{name: "goal"}
            }} = Commands.parse("/swarm /goal ship it")

    assert {:ok, %{action: :start_swarm, task: "/stop"}} = Commands.parse("/swarm /stop")
    assert {:error, %{type: :missing_argument}} = Commands.parse("/swarm /goal")
  end

  test "all remaining builtins produce distinct explicit actions" do
    for {text, action} <- [
          {"/review", :review_changes},
          {"/rewind", :select_rewind},
          {"/stop", :stop_all},
          {"/resume", :resume_last},
          {"/workflows", :open_workflows},
          {"/deep_research", :select_research},
          {"/deep_research 12", :attach_research},
          {"/compact focus", :compact}
        ] do
      assert {:ok, %{kind: :builtin, action: ^action}} = Commands.parse(text)
    end
  end

  test "no argument commands reject trailing arguments" do
    for name <- ~w(plan review rewind stop resume workflows) do
      assert {:error, %{type: :unexpected_argument}} = Commands.parse("/#{name} extra")
    end
  end

  test "workflow aliases and explicit launch parse quoted key value pairs and free text" do
    for text <- [
          "/arch-review target=\"lib web\" count=2 inspect this",
          "/workflow arch-review target=\"lib web\" count=2 inspect this",
          "/workflow run arch-review target=\"lib web\" count=2 inspect this"
        ] do
      assert {:ok,
              %{
                kind: :workflow,
                action: :launch_workflow,
                workflow: "arch-review",
                inputs: %{"target" => "lib web", "count" => "2"},
                input: "inspect this"
              }} = Commands.parse(text, workflows: @workflows)
    end

    assert {:ok, %{inputs: %{"a" => "last", "empty" => ""}}} =
             Commands.parse("/arch-review a=first empty=\"\" a=last", workflows: @workflows)
  end

  test "workflow free text authors but explicit unknown launch is refused" do
    assert {:ok, %{action: :author_workflow, prompt: "review all code"}} =
             Commands.parse("/workflow review all code")

    assert {:error, %{type: :unknown_workflow}} = Commands.parse("/workflow run missing")
    assert {:error, %{type: :missing_argument}} = Commands.parse("/workflow")
    assert {:error, %{type: :missing_argument}} = Commands.parse("/workflow resume")
  end

  test "workflow controls and save contain validated distinct fields" do
    assert {:ok, %{action: :control_workflow, control: :pause, run: "run-1"}} =
             Commands.parse("/workflow pause run-1")

    assert {:ok, %{action: :control_workflow, control: :stop}} =
             Commands.parse("/workflow stop run-1")

    assert {:ok, %{control: :resume, budget: 20}} =
             Commands.parse("/workflow resume run-1 budget=20")

    assert {:error, %{type: :invalid_budget}} =
             Commands.parse("/workflow resume run-1 budget=abc")

    assert {:error, %{type: :invalid_budget}} = Commands.parse("/workflow resume run-1 budget=0")

    assert {:ok, %{action: :save_workflow, run: "run-1", workflow: "new-flow", scope: :user}} =
             Commands.parse("/workflow save run-1 as new-flow scope=user")

    assert {:error, %{type: :invalid_argument}} = Commands.parse("/workflow save run-1")
  end

  test "custom expansion replaces all markers without redispatching" do
    custom = [%{name: "ship", body: " $ARGUMENTS and $ARGUMENTS ", mode: "plan", swarm: true}]

    assert {:ok, %{prompt: "/stop and /stop", mode: :plan, swarm: true, action: :start_swarm}} =
             Commands.parse("/ship /stop", custom: custom)

    assert {:error, %{type: :invalid_metadata}} =
             Commands.parse("/bad", custom: [%{name: "bad", body: "x", mode: "unknown"}])
  end

  test "malformed inputs metadata and oversized expansions cannot raise or echo large input" do
    for input <- [nil, 1, %{}, <<255>>, "/" <> <<255>>, String.duplicate("x", 262_145)] do
      assert {:error, %{type: type}} = Commands.parse(input)
      assert type in [:invalid_command, :input_too_large]
    end

    assert {:error, %{type: :invalid_command}} = Commands.parse("/" <> String.duplicate("n", 257))
    assert {:error, %{type: :invalid_options}} = Commands.parse("/stop", %{})
    assert Commands.catalogue(<<255>>) == []

    assert Commands.catalogue("/", custom: [%{name: "bad", body: <<255>>}, 1]) ==
             Commands.catalogue()

    custom = [%{name: "big", body: String.duplicate("$ARGUMENTS", 40)}]

    assert {:error, %{type: :expansion_too_large}} =
             Commands.parse("/big " <> String.duplicate("x", 10_000), custom: custom)

    assert byte_size(
             inspect(elem(Commands.parse("/effort " <> String.duplicate("x", 10_000)), 1))
           ) < 512
  end
end
