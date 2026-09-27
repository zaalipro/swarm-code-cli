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

      # pass 75: the trimmed slug is humanised (`angular-plan` → `Angular plan`).
      assert Name.of(state, angular) == "Angular plan"
      assert text =~ "Angular plan wants to run a command", "#{panel} #{c}x#{r}"
      # pass 75 (7.2): the band names the agent on its request row.
      assert text =~ "! 1 needs you · oldest first"
      assert text =~ ~r/│ ⋔ Angular plan wants to run/u
      refute text =~ "review-angular-plan", "#{panel} #{c}x#{r}:\n" <> text
      refute text =~ "angular-plan", "#{panel} #{c}x#{r}:\n" <> text
      # Beside a state glyph (panel rows, the strip, the chat's agent
      # lines), the agent is never a shorter word.
      assert text =~ ~r/[●◐◒◌!✓✗○⏸] Angular plan/u
      refute text =~ ~r/[●◐◒◌!✓✗○⏸] Angular(?! plan)/u, "#{panel} #{c}x#{r}:\n" <> text

      views = Model.agents(state, Map.fetch!(state.read_model.runs, Pass73Scenes.swarm_id()))
      assert Enum.find(views, &(&1.id == angular.id)).display == "Angular plan"
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
    rows = screen(state)
    text = Enum.join(rows, "\n")
    assert text =~ "Angular plan wants to run a command"
    # The header and the band: never the slug (pass 75: the agent's title is
    # its slug here, so the BRIEF's fallback, the node's title, may show it).
    refute rows |> Enum.take(4) |> Enum.join("\n") =~ "review-angular-plan"
    refute text =~ ~r/[●◐◒◌!✓✗○⏸] Angular(?! plan)/u
  end

  # pass 75 (4.5, 8.3, SA2 O): the slug stays the identifier; the ^F
  # overlay shows it, faint, after an AI title.
  test "the overlay header shows the slug after an AI title" do
    state = Pass73Scenes.screenshot_11(160, 45)
    agent = state.read_model.agents["agent-80-5"]

    titled =
      put_in(state.read_model.agents["agent-80-5"], %{
        agent
        | name: "build-verify-review",
          title: "Build check"
      })

    {:ok, open} =
      SwarmCodeCLI.UI.Reducer.Overlay.open(titled, Pass73Scenes.swarm_id(), "agent-80-5")

    header = open |> screen() |> hd()
    assert header =~ "Build check  build-verify-review", header

    faint = SwarmCodeCLI.UI.Theme.style(:text_faint, open.capabilities).foreground
    assert %{style: %{foreground: ^faint}} = find_span(open, "  build-verify-review")

    # A turn-limit stop reads `✗ turn limit` in the error colour.
    stopped =
      update_in(titled.read_model.agents["agent-80-5"], fn a ->
        %{a | state: :done} |> Map.merge(%{panel_state: :done, stop_reason: "turn_budget"})
      end)

    {:ok, open} =
      SwarmCodeCLI.UI.Reducer.Overlay.open(stopped, Pass73Scenes.swarm_id(), "agent-80-5")

    header = open |> screen() |> hd()
    assert header =~ "Build check  build-verify-review  ✗ turn limit", header
    red = SwarmCodeCLI.UI.Theme.style(:error, open.capabilities).foreground
    assert %{style: %{foreground: ^red}} = find_span(open, " turn limit")

    # Without an AI title the header is unchanged: the name, then the state.
    {:ok, open} =
      SwarmCodeCLI.UI.Reducer.Overlay.open(state, Pass73Scenes.swarm_id(), "agent-80-3")

    header = open |> screen() |> hd()
    assert header =~ ~r/› Elixir plan  \S \w/u, header
    refute header =~ "review-elixir-plan"
  end

  defp find_span(state, text) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(&Map.get(&1, :blocks, []))
    |> Enum.flat_map(&Map.get(&1, :spans, []))
    |> Enum.find(&(SwarmCodeCLI.UI.SafeText.value(&1.text) == text))
  end

  test "the card and the overlay name the agent by Panel.Name, the approval's raw name aside" do
    state = Pass73Scenes.screenshot_11(160, 45)
    item = state.read_model.interactions["demo-approval-80"]
    assert item.approval.agent_name == "review-angular-plan"
    assert ApprovalCard.who(item, state) == "Angular plan"
    assert ApprovalCard.title(item, state) == "Angular plan wants to run a command"
  end

  test "the band flattens a multi-line command to one row with …; the card keeps it whole" do
    for panel <- [:full, :compact] do
      state = Pass73Scenes.screenshot_11(160, 45, panel: panel)
      rows = screen(state)
      panel_rows = region(rows, state, :inspector)

      band = Enum.find_index(panel_rows, &(&1 =~ ~r/needs? you · oldest first/))
      assert band, Enum.join(panel_rows, "\n")

      # pass 75 (7.2): the flat command on at most two rows, the second cut.
      command_rows = Enum.filter(panel_rows, &(&1 =~ "curl"))
      assert [one] = command_rows, Enum.join(panel_rows, "\n")
      assert one =~ "cd apps/ailogic_web && curl"
      assert [^one, two, why] = Enum.slice(panel_rows, band + 2, 3)
      assert two =~ "…"
      refute why =~ ~r/json|python/
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

  test "two waiting: the swarm footer names the agent the band and the card lead with" do
    # Seen live: the band and the card opened on the oldest ask, the footer
    # said the first waiting agent in the tree was "paused on you".
    state = Pass73Scenes.screenshot_11(160, 45)
    model = state.read_model
    newer = model.interactions["demo-approval-80"]

    older = %{
      newer
      | id: "demo-approval-79",
        node_id: "demo-op-79",
        created_at: state.now - 30_000,
        approval: %{
          newer.approval
          | agent_id: "agent-80-4",
            agent_name: "review-security-plan",
            command: "ls lib",
            arguments_preview: ~S<{"command":"ls lib"}>
        }
    }

    security =
      %{model.agents["agent-80-4"] | state: :waiting_approval}
      |> Map.put(:panel_state, :needs_you)

    model = %{
      model
      | interactions: Map.put(model.interactions, older.id, older),
        agents: Map.put(model.agents, security.id, security)
    }

    state = %{state | read_model: model}
    rows = screen(state)
    panel_rows = region(rows, state, :inspector)
    panel = Enum.join(panel_rows, "\n")

    # pass 75 (7.2): the band's request rows, oldest first.
    asking = fn rows ->
      rows |> Enum.map(&Regex.run(~r/│ \S (.+?) wants to run/u, &1)) |> Enum.reject(&is_nil/1)
    end

    assert [[_, first], [_, second]] = asking.(panel_rows), panel
    assert first == "Security plan"
    assert second == "Angular plan"
    assert Enum.join(rows, "\n") =~ "Security plan wants to run a command"
    # The swarm's rows name the same agents.
    assert panel =~ ~r/! Security plan +wants to run/, panel

    # With the swarm in view, the band still leads with it; V2 has no footer.
    state = %{state | destination: {:run, Pass73Scenes.swarm_id()}}
    panel_rows = state |> screen() |> region(state, :inspector)
    panel = Enum.join(panel_rows, "\n")
    assert [[_, "Security plan"] | _] = asking.(panel_rows), panel
    refute panel =~ "is paused on"
  end

  test "a chat turn's role label: the node's own name, the run's title, else Assistant" do
    assert Name.role_label(%{name: "Planner"}, nil) == "Planner"

    assert Name.role_label(%{name: "assistant"}, %{title: "/create-workflow x"}) ==
             "Workflow author"

    assert Name.role_label(%{name: nil}, %{title: "hello"}) == "Assistant"
    assert Name.display(%{role: :lead, name: "lead"}, {"", ""}, nil) == "Lead"
    assert Name.display(%{role: :worker, name: "review-x-plan"}, {"review-", ""}, nil) == "X plan"
  end

  test "pass 75: the trimmed slug is humanised" do
    # The shared `review-` prefix goes, dashes and underscores read as
    # spaces, the first letter is upper case.
    names =
      for slug <- ~w(review-angular-plan review-elixir-plan review-security-plan review-deploy),
          do: Name.display(%{role: :worker, name: slug}, {"review-", ""}, nil)

    assert names == ["Angular plan", "Elixir plan", "Security plan", "Deploy"]
    assert Name.humanise("") == ""
    assert Name.humanise("build__verify-review") == "Build verify review"
    assert Name.humanise("-x-") == "X"
  end

  test "pass 75: an AI title wins over the slug" do
    # The Lead named the deploy reviewer "Build check" (spawn_agent's title).
    state = Pass73Scenes.screenshot_11(160, 45, titles: %{"agent-80-5" => "Build check"})
    deploy = Map.fetch!(state.read_model.agents, "agent-80-5")

    assert Name.ai_title?(deploy)
    assert Name.slug(deploy) == "review-deploy"
    # The title as is: no affix trim, no humanising.
    assert Name.of(state, deploy) == "Build check"

    rows = screen(state)
    main = state |> then(&region(rows, &1, :main)) |> Enum.join("\n")
    assert main =~ "Build check", main
    refute Enum.join(rows, "\n") =~ ~r/\bDeploy\b|review-deploy/

    # With the swarm in view its panel row reads the title too.
    state = %{state | destination: {:run, Pass73Scenes.swarm_id()}}
    rows = screen(state)
    panel = state |> then(&region(rows, &1, :inspector)) |> Enum.join("\n")
    assert panel =~ "Build check", panel
    refute Enum.join(rows, "\n") =~ ~r/\bDeploy\b|review-deploy/

    # An agent whose title is its own name reads its humanised slug.
    elixir = Map.fetch!(state.read_model.agents, "agent-80-3")
    assert elixir.title == elixir.name
    refute Name.ai_title?(elixir)
    assert Name.of(state, elixir) == "Elixir plan"
    assert Name.ai_title?(%{name: "x", title: "  "}) == false
    assert Name.ai_title?(%{name: "x"}) == false
  end
end
