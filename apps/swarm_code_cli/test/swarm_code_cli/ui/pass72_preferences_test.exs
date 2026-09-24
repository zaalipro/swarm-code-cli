defmodule SwarmCodeCLI.UI.Pass72PreferencesTest do
  @moduledoc "Pass 72 (P6): the CLI preferences file keeps the panel's mode, privately and atomically."
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Init.Preferences

  @moduletag :tmp_dir

  test "a missing, malformed, oversized or foreign file means the full panel", %{tmp_dir: dir} do
    path = Path.join(dir, "cli.json")
    assert Preferences.read(path) == Preferences.defaults()
    assert Preferences.read(nil) == Preferences.defaults()

    assert Preferences.defaults() == %{
             panel_mode: :full,
             show_diffs: true,
             theme: nil,
             mouse?: true
           }

    for body <- [
          "{",
          "[]",
          ~s({"panel": "sideways"}),
          ~s({"panel": 3}),
          String.duplicate(" ", 20_000)
        ] do
      File.write!(path, body)
      assert Preferences.read(path) == Preferences.defaults()
    end

    File.rm!(path)
    File.mkdir!(path)
    assert Preferences.read(path) == Preferences.defaults()
  end

  test "a write is 0600, atomic, keeps keys it does not know and leaves no temporary file",
       %{tmp_dir: dir} do
    path = Path.join(dir, "cli.json")
    File.write!(path, ~s({"theme": "dusk", "panel": "full"}))

    assert Preferences.write(path, %{panel_mode: :compact}) == :ok
    assert Preferences.read(path) == %{Preferences.defaults() | panel_mode: :compact}
    assert JSON.decode!(File.read!(path)) == %{"theme" => "dusk", "panel" => "compact"}
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    assert File.ls!(dir) == ["cli.json"]
  end

  test "a write creates a missing directory owner-only", %{tmp_dir: dir} do
    path = Path.join([dir, "SwarmCode", "cli.json"])
    assert Preferences.write(path, %{panel_mode: :hidden}) == :ok
    assert Preferences.read(path) == %{Preferences.defaults() | panel_mode: :hidden}
    assert File.stat!(Path.dirname(path)).mode |> Bitwise.band(0o777) == 0o700
  end

  test "a write that cannot land cleans up after itself", %{tmp_dir: dir} do
    path = Path.join(dir, "cli.json")
    File.mkdir!(path)
    File.write!(Path.join(path, "keep"), "x")
    assert {:error, _} = Preferences.write(path, %{panel_mode: :compact})
    assert Enum.sort(File.ls!(dir)) == ["cli.json"]
  end
end
