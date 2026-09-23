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
end
