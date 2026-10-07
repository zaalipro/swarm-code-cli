defmodule SwarmCodeCLI.Cli020.E14ReadOnlyCardTest do
  # cli020 E14 (ux-live-5, competitors-2): in read-only mode a write asks
  # first. The card says `Ask · <tool>`, offers `y once · d deny · D deny and
  # stop`, and shows what would change: a diff for `edit_file` (12 lines,
  # then `… N more`), the first 12 lines for `write_file`.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp with_approval(tool, arguments, mode \\ "read_only") do
    state = Pass73Scenes.screenshot_11(120, 44)
    [{id, interaction}] = Map.to_list(state.read_model.interactions)

    approval =
      %DTO.Approval{
        tool: tool,
        permission: :write,
        classification: :normal,
        arguments_preview: Jason.encode!(arguments),
        allowed_decisions: [:approve, :deny, :deny_stop]
      }
      |> Map.put(:approval_mode, mode)

    put_in(state.read_model.interactions[id], %{interaction | approval: approval})
  end

  defp numbered(prefix, n), do: Enum.map_join(1..n, "\n", &"#{prefix} #{&1}")

  test "edit_file: Ask title, three keys, a bounded diff" do
    text =
      with_approval("edit_file", %{
        "path" => "lib/router.ex",
        "old_string" => numbered("old", 10),
        "new_string" => numbered("new", 10)
      })
      |> screen_text()

    assert text =~ "Ask · edit_file"
    refute text =~ "wants to change a file"
    assert text =~ ~r/y\s+once/
    assert text =~ ~r/d\s+deny/
    assert text =~ ~r/D\s+deny and stop/
    refute text =~ "this run"
    assert text =~ "lib/router.ex"
    assert text =~ "- old 1"
    assert text =~ "+ new 1"
    # 20 changed lines: 12 shown, then the count.
    assert text =~ "… 8 more"
    refute text =~ "+ new 10"
  end

  test "write_file: the first 12 lines of the content" do
    text =
      with_approval("write_file", %{"path" => "notes.md", "content" => numbered("line", 20)})
      |> screen_text()

    assert text =~ "Ask · write_file"
    assert text =~ "line 12"
    refute text =~ "line 13"
    assert text =~ "… 8 more"
  end

  test "outside read-only the card keeps its title" do
    text =
      with_approval(
        "edit_file",
        %{"path" => "a.ex", "old_string" => "a", "new_string" => "b"},
        "auto"
      )
      |> screen_text()

    refute text =~ "Ask · edit_file"
    assert text =~ "wants to change a file"
  end
end
