defmodule SwarmCodeCLI.UI.Pass73PreferencesTest do
  @moduledoc "pass73 T1/T2/T9: cli.json keeps the diffs, the theme and the wheel beside the panel."
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Init.Preferences

  @moduletag :tmp_dir

  test "each key reads back, and a bad value falls back to its default alone", %{tmp_dir: dir} do
    path = Path.join(dir, "cli.json")

    File.write!(
      path,
      ~s({"panel": "compact", "show_diffs": false, "theme": "light", "mouse": false})
    )

    assert Preferences.read(path) == %{
             panel_mode: :compact,
             show_diffs: false,
             theme: :light,
             mouse?: false
           }

    File.write!(path, ~s({"panel": "compact", "show_diffs": "no", "theme": "dusk", "mouse": 0}))

    assert Preferences.read(path) == %{
             panel_mode: :compact,
             show_diffs: true,
             theme: nil,
             mouse?: true
           }
  end

  test "a write changes only the keys it is given and keeps every other", %{tmp_dir: dir} do
    path = Path.join(dir, "cli.json")
    File.write!(path, ~s({"panel": "hidden", "future": {"x": 1}}))

    assert Preferences.write(path, %{show_diffs: false}) == :ok
    assert Preferences.write(path, %{theme: :light, mouse?: false}) == :ok

    assert JSON.decode!(File.read!(path)) == %{
             "panel" => "hidden",
             "future" => %{"x" => 1},
             "show_diffs" => false,
             "theme" => "light",
             "mouse" => false
           }

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.ls!(dir) == ["cli.json"]
  end

  test "a write refuses unknown keys, bad values and nothing at all", %{tmp_dir: dir} do
    path = Path.join(dir, "cli.json")

    for bad <- [%{}, %{theme: :dusk}, %{theme: nil}, %{mouse?: "yes"}, %{colour: :red}, :x] do
      assert Preferences.write(path, bad) == {:error, :invalid}
    end

    refute File.exists?(path)
  end
end
