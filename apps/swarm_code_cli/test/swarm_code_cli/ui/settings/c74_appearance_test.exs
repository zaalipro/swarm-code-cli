defmodule SwarmCodeCLI.UI.Settings.C74AppearanceTest do
  @moduledoc "cli74 U3-9: the Appearance page (§2.14, F10)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Settings.{Nav, Sections}

  defp line_words(row), do: Enum.map_join(row.lines, " / ", &words/1)

  defp with_env(state, overrides) do
    facts = Map.put(Nav.ctx(state).launch_facts || %{}, :env_overrides, overrides)
    %{Nav.ctx(state) | launch_facts: facts}
  end

  defp find(rows, id), do: Enum.find(rows, &(&1.id == id))

  test "SWARM_THEME wins while set and the theme row says so" do
    {state, _fake} = opened(:appearance)
    ctx = with_env(state, %{"terminal.theme" => %{var: "SWARM_THEME", value: "light"}})
    theme = ctx |> then(&Sections.rows(:appearance, &1)) |> find("key:terminal.theme")
    assert line_words(theme) =~ "SWARM_THEME=light wins while set · cli.json: "

    ignored =
      with_env(state, %{
        "terminal.theme" => %{var: "SWARM_THEME", value: "blue", ignored: true, note: "?"}
      })

    theme = ignored |> then(&Sections.rows(:appearance, &1)) |> find("key:terminal.theme")
    refute line_words(theme) =~ "wins while set"
  end

  test "the theme row says SWARM_THEME wins once when the launch itself carries the override" do
    # Found in the sandbox (cli74 F24): the generic provenance line and this page's own
    # line were both drawn under the Theme row.
    facts = %{env_overrides: %{"terminal.theme" => %{var: "SWARM_THEME", value: "light"}}}
    {state, _fake} = opened(:appearance, put: [launch_facts: facts, prefs: %{"theme" => "dark"}])
    theme = key_row(state, "terminal.theme")

    assert words(theme.tag) == "env SWARM_THEME"
    wins = Enum.filter(theme.lines, &(words(&1) =~ "wins while set"))
    assert [line] = wins
    assert words(line) == "SWARM_THEME=light wins while set · cli.json: dark"
  end

  test "the F10 rows: colour and glyph tiers this launch, the accent with its contrast" do
    {state, _fake} = opened(:appearance)
    ids = Enum.map(rows(state), & &1.id)

    for key <- ~w(terminal.theme terminal.colors terminal.glyphs terminal.ambiguous_width
                  terminal.reduced_motion terminal.accent) do
      assert ("key:" <> key) in ids, key
    end

    assert line_words(key_row(state, "terminal.colors")) =~ "this launch: auto: "
    assert line_words(key_row(state, "terminal.glyphs")) =~ "this launch: auto: measured"
    accent = key_row(state, "terminal.accent")
    assert words(accent) =~ "#FF6A1A"
    assert line_words(accent) =~ ": 1"
  end

  test "the preview: the same rows in a dark and a light box, and the ASCII twins" do
    {state, _fake} = opened(:appearance)
    text = page_text(state)

    assert text =~ "preview · the same rows in both themes"
    assert text =~ "┌─ dark ───"
    assert text =~ "┌─ light ───"
    assert text =~ "│ ✳ Assistant  deepseek-v4-pro         │ │ ✳ Assistant  deepseek-v4-pro"
    assert text =~ "│ ! deps-agent wants to run            │"

    assert text =~
             "ASCII twins  * S C * # /   * ~ . ! v x o   #-   (Glyphs: ASCII, or SWARM_ASCII=1)"

    # every box line is the same width
    widths =
      for row <- rows(state),
          String.starts_with?(row.id, "info:preview-"),
          row.id != "info:preview-ascii",
          do: row |> words() |> String.length()

    assert [_ | _] = widths
    assert Enum.uniq(widths) |> length() == 1
  end

  test "the desktop app's own theme: g goes to Desktop app" do
    {state, _fake} = opened(:appearance)
    link = key_row(state, "terminal.desktop_theme_link")
    assert words(link) =~ "the terminal keeps its own dark and light"
    assert words(link.tag) == "g More › Desktop app"
    assert [{:section, :desktop}] = Sections.act(:appearance, Nav.ctx(state), link, :goto)
  end
end
