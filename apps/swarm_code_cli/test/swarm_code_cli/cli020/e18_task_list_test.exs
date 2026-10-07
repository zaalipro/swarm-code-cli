defmodule SwarmCodeCLI.Cli020.E18TaskListTest do
  # cli020 E18 (ux-live-22): Markdown task items draw ☐ / ☑ in place of the
  # bullet (ASCII keeps `[ ]` / `[x]`), measured under both width policies.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Projector.Markdown
  alias SwarmCodeCLI.UI.Width

  defp text(md, policy, opts \\ []) do
    md
    |> Markdown.rows(40, policy, opts)
    |> Enum.map(fn row -> Enum.map_join(row.segments, "", &elem(&1, 0)) end)
  end

  for policy <- [:narrow, :wide] do
    test "☐ / ☑ under the #{policy} policy" do
      policy = unquote(policy)
      [open, done] = text("- [ ] add tests\n- [x] read the router", policy)
      assert open =~ ~r/^☐ add tests/
      assert done =~ ~r/^☑ read the router/
      refute open =~ "[ ]"
      refute open =~ "•"
    end

    test "a wrapped task hangs under its text (#{policy})" do
      policy = unquote(policy)
      [first, second | _] = text("- [ ] " <> String.duplicate("word ", 12), policy)
      box = Width.cells("☐ ", policy)
      assert String.starts_with?(first, "☐ ")
      assert second =~ ~r/^\s{#{box}}word/
    end
  end

  test "ASCII keeps the brackets" do
    [open, done] = text("- [ ] add tests\n- [x] read the router", :narrow, ascii?: true)
    assert open =~ "[ ] add tests"
    assert done =~ "[x] read the router"
  end
end
