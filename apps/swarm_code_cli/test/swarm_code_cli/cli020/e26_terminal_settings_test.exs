defmodule SwarmCodeCLI.Cli020.E26TerminalSettingsTest do
  # cli020 E26 (for D3, D5, D8, B21): the new terminal settings in the
  # registry and in `Init.Preferences`, read from and written to cli.json.
  use ExUnit.Case, async: true

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Init.Preferences

  @moduletag :tmp_dir

  test "defaults: the mouse is off, the rest as §8.4" do
    d = Preferences.defaults()
    assert d.mouse? == false
    assert d.notify == :auto
    assert d.title? == true
    assert d.paste_collapse_lines == 8
    assert d.wheel_lines == 3
    assert d.notice_seconds == 6
    assert d.hint_letters == "sfghjklwertuiop"
    assert d.reduced_motion? == false
    assert d.exit_transcript == 3
    assert Preferences.legacy(%{}) == d
  end

  test "a round trip through cli.json", %{tmp_dir: dir} do
    path = Path.join(dir, "cli.json")

    prefs = %{
      notify: :osc9,
      title?: false,
      paste_collapse_lines: 0,
      wheel_lines: 5,
      notice_seconds: 10,
      hint_letters: "sfghjklw",
      reduced_motion?: true,
      exit_transcript: 7,
      mouse?: true
    }

    assert :ok = Preferences.write(path, prefs)
    read = Preferences.read(path)
    assert Map.take(read, Map.keys(prefs)) == prefs
    assert Jason.decode!(File.read!(path))["notify"] == "osc9"
  end

  test "values out of range read as the defaults" do
    read =
      Preferences.legacy(%{
        "notify" => "loud",
        "title" => "yes",
        "paste_collapse_lines" => 500,
        "wheel_lines" => 0,
        "notice_seconds" => 99,
        "hint_letters" => "",
        "exit_transcript" => -1
      })

    d = Preferences.defaults()

    for key <- [
          :notify,
          :title?,
          :paste_collapse_lines,
          :wheel_lines,
          :notice_seconds,
          :hint_letters,
          :exit_transcript
        ],
        do: assert(Map.fetch!(read, key) == Map.fetch!(d, key), inspect(key))
  end

  test "the registry rows" do
    by_key = fn key -> Enum.find(Registry.all(), &(&1.key == key)) end
    assert by_key.("terminal.mouse").default == false
    assert by_key.("terminal.mouse").description =~ "Off: the wheel scrolls"
    assert by_key.("terminal.notify").default == "auto"
    assert by_key.("terminal.title").default == true
    assert by_key.("terminal.paste_collapse_lines").default == 8
    assert by_key.("terminal.exit_transcript").default == 3
    assert by_key.("terminal.wheel_lines").description == "Lines per wheel notch."
    assert by_key.("terminal.panel").default == "auto"
  end
end
