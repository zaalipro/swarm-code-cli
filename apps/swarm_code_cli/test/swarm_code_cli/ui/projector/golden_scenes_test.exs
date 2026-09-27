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
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, Scene, Size, Width}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  @sizes [{160, 45}, {120, 36}, {90, 30}, {80, 24}]

  @evidence %{
    first_reply: ["Read mix.exs", "The app boots the repo"],
    approval: ["ls -la notes", "Type a message"],
    approval_edit: ["guard.ex", "Type a message"],
    # pass 75: the slugs read humanised.
    swarm: ["Worker a accounts", "Worker b live"],
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
  # pass 75: the V2 panel (a done chat turn has no agents row; the spent,
  # earlier, found and band rows; humanised names).
  @pass71 %{
    first_reply: [
      "✳ Read mix.exs",
      "· in chat",
      "spent $0.01 · 19k tokens · 1 run",
      "context",
      " elixir "
    ],
    trouble: [
      "@@ -12,9 +12,13 @@",
      "429 Too Many Requests",
      "earlier  2 finished runs in this chat"
    ],
    swarm: [
      "Worker a accounts",
      "1 of 3 in · no files changed",
      "1 needs you · oldest first",
      "Worker b live wants to run"
    ]
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

  # pass 75: re-derived from the V2 panel (humanised names, `found`, the
  # band's words, the spent and earlier rows). Review P-1 (spec Blockers,
  # 153b, the owner's decision): the kind sections stay for workflow and
  # consensus runs only, so `implement` and `positions` are evidence again;
  # goal criteria and the research funnel (`criteria`, `sources`) are not
  # drawn.
  @panel_evidence %{
    panel_chat: {"fix the flaky retry test", ["Assistant", "2 finished runs in this chat"]},
    panel_swarm_1: {"architecture review", ["Engine lifecycle", "found"]},
    panel_swarm_2:
      {"architecture review", ["1 needs you · oldest first", "mix test test/swarm_code_web/live"]},
    panel_swarm_3: {"architecture review", ["stop reason read before the flush"]},
    panel_workflow: {"ship retry", ["implement", "found", "Retry tests"]},
    panel_goal: {"suite green", ["found", "Goal agent"]},
    panel_plan: {"rate limits for the API", ["1 needs you · oldest first", "limit per API key"]},
    panel_research: {"Req vs Finch pooling", ["found", "Reader code"]},
    panel_consensus: {"should runs own worktrees?", ["positions", "found", "Gemini"]},
    panel_heavy: {"architecture review", ["spent", "2 need you"]},
    panel_owner19:
      {"lets plan how to make this app better", ["Build check", "quiet 1m", "no files changed"]},
    panel_owner19_band:
      {"lets plan how to make this app better",
       ["2 need you", "1 question: Focus", "dangerous: asks even in full access"]}
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
          # The strip (R17) sits on row 1; pass 75 (8.2): it draws the title
          # whole or cut at its end with `…`, to 22 cells, or to 12 cells
          # when the row is short.
          if elem(size, 0) < 120 do
            policy = unquote(policy)
            forms = [title | Enum.map([22, 12], &Width.elide(title, &1, :end, policy))]
            strip = Enum.at(rows, 1)

            assert Enum.any?(forms, &String.contains?(strip, &1)),
                   "#{label}: the strip draws no form of #{inspect(title)}: #{strip}"
          end
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
