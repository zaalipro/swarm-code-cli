defmodule SwarmCodeCLI.UI.Projector.Pass73NamesTest do
  @moduledoc """
  pass73 T10 (owner V1): the owner's screenshot 11. One agent was
  "review-angular-plan" on the approval card, "angular-plan" in the band and
  "angular" on its compact row; the band printed a multi-line `curl … |
  python3 -c "` over four rows; and the `/create-workflow` turn in chat said
  "Assistant" for the Workflow author.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{Layout, Paint, Projector, Width}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.{ApprovalCard, Overlay}
  alias SwarmCodeCLI.UI.Projector.Panel.{Model, Name}

  defp screen(state) do
    {scene, _} = Projector.project(state)

    {:ok, plan} =
      Paint.build(scene, %Options{
        color_mode: state.capabilities.color_mode,
        ascii?: state.capabilities.ascii?
      })

    assert plan.diagnostics == []

    for y <- 0..(state.size.rows - 1) do
      for x <- 0..(state.size.columns - 1), reduce: "" do
        acc ->
          case Plan.cell(plan, x, y) do
            {:glyph, glyph, _, _} -> acc <> glyph
            _ -> acc
          end
      end
    end
  end

  defp region(rows, state, key) do
    rect = Map.fetch!(Layout.for_state(state).rects, key)
    policy = state.capabilities.ambiguous_width

    rows
    |> Enum.slice(rect.y, rect.height)
    |> Enum.map(fn row ->
      {_, rest, _} = Width.take_cells(row, rect.x, policy)
      {kept, _, _} = Width.take_cells(rest, rect.width, policy)
      kept
    end)
  end

  test "one name for the agent: card, band, panel rows (full and compact), overlay, chat" do
    for panel <- [:full, :compact], {c, r} <- [{160, 45}, {120, 36}] do
      state = Pass73Scenes.screenshot_11(c, r, panel: panel)
      rows = screen(state)
      text = Enum.join(rows, "\n")
      angular = Map.fetch!(state.read_model.agents, Pass73Scenes.angular_id())

      assert Name.of(state, angular) == "angular-plan"
      assert text =~ "angular-plan wants to run a command", "#{panel} #{c}x#{r}"
      assert text =~ ~r/NEEDS YOU · angular-plan|! 1 NEEDS YOU/
      refute text =~ "review-angular-plan", "#{panel} #{c}x#{r}:\n" <> text
      # Beside a state glyph (panel rows, the strip, the chat's agent
      # lines), the agent is never a shorter word.
      named = Regex.scan(~r/[●◐◌!✓✗○⏸] ([\w-]+)/u, text, capture: :all_but_first)
      assert ["angular-plan"] in named
      refute ["angular"] in named, "#{panel} #{c}x#{r}:\n" <> text

      views = Model.agents(state, Map.fetch!(state.read_model.runs, Pass73Scenes.swarm_id()))
      assert Enum.find(views, &(&1.id == angular.id)).display == "angular-plan"
    end

    # The overlay on the agent names it the same way in its header and band.
    state = Pass73Scenes.screenshot_11(160, 45)

    {:ok, state} =
      SwarmCodeCLI.UI.Reducer.Overlay.open(
        state,
        Pass73Scenes.swarm_id(),
        Pass73Scenes.angular_id()
      )

    assert Overlay.project(state, Layout.for_state(state))
    text = state |> screen() |> Enum.join("\n")
    assert text =~ "angular-plan wants to run a command"
    refute text =~ "review-angular-plan"
    named = Regex.scan(~r/[●◐◌!✓✗○⏸] ([\w-]+)/u, text, capture: :all_but_first)
    refute ["angular"] in named
  end

  test "the card and the overlay name the agent by Panel.Name, the approval's raw name aside" do
    state = Pass73Scenes.screenshot_11(160, 45)
    item = state.read_model.interactions["demo-approval-80"]
    assert item.approval.agent_name == "review-angular-plan"
    assert ApprovalCard.who(item, state) == "angular-plan"
    assert ApprovalCard.title(item, state) == "angular-plan wants to run a command"
  end

  test "the band flattens a multi-line command to one row with …; the card keeps it whole" do
    for panel <- [:full, :compact] do
      state = Pass73Scenes.screenshot_11(160, 45, panel: panel)
      rows = screen(state)
      panel_rows = region(rows, state, :inspector)

      band = Enum.find_index(panel_rows, &(&1 =~ "NEED"))
      assert band, Enum.join(panel_rows, "\n")

      command_rows = Enum.filter(panel_rows, &(&1 =~ "curl"))
      assert [one] = command_rows, Enum.join(panel_rows, "\n")
      assert one =~ "cd apps/ailogic_web && curl"
      assert one =~ "…"
      refute Enum.any?(panel_rows, &(&1 =~ "import json"))

      # The card still shows the command's own lines.
      text = Enum.join(rows, "\n")
      assert text =~ "import json,sys"
    end
  end

  test "a narrated multi-line command from the wire is flat too" do
    assert Model.flat("a \\\n  | b\n c") == "a \\ | b c"

    ask = %{
      approval: %{
        tool: "run_command",
        arguments_preview: ~S<{"command":"curl -s x | python3 -c \"\nimport json\nprint(1)\">
      }
    }

    # A preview cut by its byte limit does not decode; its escapes still read.
    assert Model.request(ask) == "curl -s x | python3 -c \" import json print(1)\""
  end

  test "the /create-workflow turn in chat is the Workflow author in the panel and the chat" do
    state = Pass73Scenes.screenshot_11(160, 45)
    rows = screen(state)
    panel = state |> then(&region(rows, &1, :inspector)) |> Enum.join("\n")
    main = state |> then(&region(rows, &1, :main)) |> Enum.join("\n")

    assert panel =~ "Workflow author"
    assert main =~ ~r/✳ Workflow author  deepseek-v4-pro/
    refute Enum.join(rows, "\n") =~ "Assistant"
  end

  test "a chat turn's role label: the node's own name, the run's title, else Assistant" do
    assert Name.role_label(%{name: "Planner"}, nil) == "Planner"

    assert Name.role_label(%{name: "assistant"}, %{title: "/create-workflow x"}) ==
             "Workflow author"

    assert Name.role_label(%{name: nil}, %{title: "hello"}) == "Assistant"
    assert Name.display(%{role: :lead, name: "lead"}, {"", ""}, nil) == "Lead"
    assert Name.display(%{role: :worker, name: "review-x-plan"}, {"review-", ""}, nil) == "x-plan"
  end
end
