defmodule SwarmCodeCLI.UI.Projector.GoldenScenesTest do
  @moduledoc """
  pass70 D8: every conversation-shaped scene (`Demo.Conversation`) at the four
  golden sizes, under both ambiguous-width policies, in colour and in
  monochrome ASCII, paints a valid plan with no diagnostics, keeps at least 17
  transcript rows at 80x24, ends in one status row that leads with the mode,
  and shows what the scene is about. The same scenes are the gallery's
  `conversation-*` previews (`mix swarm_code.demo.cells`).
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, Scene, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  @sizes [{160, 45}, {120, 36}, {90, 30}, {80, 24}]

  @evidence %{
    first_reply: ["Read mix.exs", "The app boots the repo"],
    approval: ["ls -la notes", "Type a message"],
    approval_edit: ["guard.ex", "Type a message"],
    swarm: ["worker-a-accounts", "worker-b-live"],
    long: ["The app boots the repo"],
    failed_workflow: ["/design-coloring", "Failed"],
    trouble: ["not trusted", "retrying in 42s", "exit 2"],
    empty: ["Ready to build", "Enter"]
  }

  defp paint(scene, {columns, rows}, policy, mode, ascii?) do
    size = %Size{columns: columns, rows: rows}

    caps = %Capabilities{
      size: size,
      ambiguous_width: policy,
      color_mode: mode,
      ascii?: ascii?
    }

    state = Conversation.state(scene, size, caps)
    {projected, _table} = Projector.project(state)
    assert Scene.validate(projected) == :ok

    assert {:ok, plan} =
             Paint.build(projected, %Options{color_mode: mode, ascii?: ascii?})

    assert :ok = Plan.validate(plan)
    assert plan.diagnostics == []

    rows =
      for y <- 0..(rows - 1) do
        for x <- 0..(columns - 1), reduce: "" do
          acc ->
            case Plan.cell(plan, x, y) do
              {:glyph, glyph, _, _} -> acc <> glyph
              _ -> acc
            end
        end
      end

    {projected, rows}
  end

  for scene <- Conversation.scenes(), {columns, rows} <- @sizes, policy <- [:narrow, :wide] do
    test "#{scene} at #{columns}x#{rows} (#{policy})" do
      scene = unquote(scene)
      size = {unquote(columns), unquote(rows)}

      for {mode, ascii?} <- [truecolor: false, monochrome: true] do
        {projected, rows} = paint(scene, size, unquote(policy), mode, ascii?)
        screen = Enum.join(rows, "\n")

        for text <- Map.fetch!(@evidence, scene) do
          assert screen =~ text, "#{scene} #{inspect(size)} #{mode}: no #{inspect(text)}"
        end

        assert List.last(rows) =~ ~r/^ (SELECT  )?Build/

        # ASCII mode draws no box, block or symbol glyph. The middle dot and the
        # ellipsis are still text punctuation there (a pre-existing choice of
        # `Width.elide/4` and the separators), so they are the only exceptions.
        if ascii? do
          assert String.printable?(screen)
          leaked = Regex.scan(~r/[^\x00-\x7F·…]/u, screen) |> List.flatten() |> Enum.uniq()
          assert leaked == [], "#{scene} #{inspect(size)} leaks #{inspect(leaked)}"
        end

        main = Enum.find(projected.regions, &(&1.role == :main))
        if size == {80, 24}, do: assert(main.rect.height >= 17)
      end
    end
  end

  # pass71 V6, redrawn by pass72: what the docked side panel says about the
  # conversation scenes (the panel is direction D, not the pass-71 cards).
  @pass71 %{
    first_reply: ["✳ Read mix.exs", "· in chat", "✓ Assistant", "context", " elixir "],
    trouble: ["@@ -12,9 +12,13 @@", "429 Too Many Requests", "earlier in this chat"],
    swarm: ["worker-a-accounts", "reported", "! NEEDS YOU · worker-b-live"]
  }

  for {scene, texts} <- @pass71, policy <- [:narrow, :wide] do
    test "pass71 #{scene} at 160x45 (#{policy})" do
      {_projected, rows} = paint(unquote(scene), {160, 45}, unquote(policy), :truecolor, false)
      screen = Enum.join(rows, "\n")

      for text <- unquote(texts),
          do: assert(screen =~ text, "#{unquote(scene)}: no #{inspect(text)}")

      # pass72 P1: no operations anywhere in the panel.
      refute screen =~ "Operations ·"
      refute screen =~ "Current task"
    end
  end

  # pass72: the side panel's own scenes (`Demo.Panel`, the D2 mockups) at the
  # four golden sizes, both width policies, in colour and in monochrome ASCII,
  # full and compact: a valid plan with no diagnostics, the run on screen
  # (docked from 120 columns, the strip under it), and at least 17
  # transcript rows at 80x24.
  alias SwarmCodeCLI.Demo.Panel, as: PanelScenes

  @panel_evidence %{
    panel_chat: {"fix the flaky retry test", ["Assistant", "context"]},
    panel_swarm_1: {"architecture review", ["engine-lifecycle", "reported"]},
    panel_swarm_2: {"architecture review", ["NEEDS YOU", "mix test test/swarm_code_web/live"]},
    panel_swarm_3: {"architecture review", ["stop reason read before the flush"]},
    panel_workflow: {"ship retry", ["implement", "retry-tests"]},
    panel_goal: {"suite green", ["criteria", "goal agent"]},
    panel_plan: {"rate limits for the API", ["NEEDS YOU", "limit per API key"]},
    panel_research: {"Req vs Finch pooling", ["sources", "reader-code"]},
    panel_consensus: {"should runs own worktrees?", ["positions", "gemini"]},
    panel_heavy: {"architecture review", ["5 runs", "NEED YOU"]}
  }

  defp paint_panel(scene, {columns, rows}, policy, mode, ascii?, panel) do
    size = %Size{columns: columns, rows: rows}
    caps = %Capabilities{size: size, ambiguous_width: policy, color_mode: mode, ascii?: ascii?}
    state = scene |> PanelScenes.state(size, caps) |> Map.put(:panel_mode, panel)
    {projected, _table} = Projector.project(state)
    assert Scene.validate(projected) == :ok
    assert {:ok, plan} = Paint.build(projected, %Options{color_mode: mode, ascii?: ascii?})
    assert :ok = Plan.validate(plan)
    assert plan.diagnostics == []

    rows =
      for y <- 0..(rows - 1) do
        for x <- 0..(columns - 1), reduce: "" do
          acc ->
            case Plan.cell(plan, x, y) do
              {:glyph, glyph, _, _} -> acc <> glyph
              _ -> acc
            end
        end
      end

    {projected, rows}
  end

  for scene <- PanelScenes.scenes(), {columns, rows} <- @sizes, policy <- [:narrow, :wide] do
    test "pass72 #{scene} at #{columns}x#{rows} (#{policy})" do
      scene = unquote(scene)
      size = {unquote(columns), unquote(rows)}
      {title, docked} = Map.fetch!(@panel_evidence, scene)

      for {mode, ascii?} <- [truecolor: false, monochrome: true], panel <- [:full, :compact] do
        {projected, rows} = paint_panel(scene, size, unquote(policy), mode, ascii?, panel)
        screen = Enum.join(rows, "\n")
        label = "#{scene} #{inspect(size)} #{mode} #{panel}"

        assert screen =~ title, "#{label}: no #{inspect(title)}"

        # The kind's sections are the full panel's; compact keeps the rows.
        if elem(size, 0) >= 120 and panel == :full do
          for text <- docked, do: assert(screen =~ text, "#{label}: no #{inspect(text)}")
        else
          # The strip (R17) sits on row 1.
          if elem(size, 0) < 120, do: assert(Enum.at(rows, 1) =~ title)
        end

        if ascii? do
          leaked = Regex.scan(~r/[^\x00-\x7F·…]/u, screen) |> List.flatten() |> Enum.uniq()
          assert leaked == [], "#{label} leaks #{inspect(leaked)}"
        end

        main = Enum.find(projected.regions, &(&1.role == :main))
        if size == {80, 24}, do: assert(main.rect.height >= 17)
      end
    end
  end
end
