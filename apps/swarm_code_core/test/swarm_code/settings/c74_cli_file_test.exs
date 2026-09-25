defmodule SwarmCode.Settings.C74CliFileTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Settings.CliFile

  @moduletag :tmp_dir

  defp path(dir), do: Path.join(dir, "cli.json")

  defp write!(dir, body) do
    File.write!(path(dir), body)
    File.chmod!(path(dir), 0o600)
  end

  defp leftovers(dir), do: dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".tmp"))

  test "a missing file reads as the defaults; nil path too", %{tmp_dir: dir} do
    assert %{status: :absent, values: %{}, fingerprint: nil} = CliFile.read_all(path(dir))
    assert %{status: :absent} = CliFile.read_all(nil)
  end

  test "known, invalid and unknown keys are told apart", %{tmp_dir: dir} do
    write!(
      dir,
      ~s({"panel": "compact", "show_diffs": false, "theme": "neon", "keys": {"palette_open": ["Ctrl-P"]}, "x-unknown": 1})
    )

    snapshot = CliFile.read_all(path(dir))
    assert snapshot.status == :ok

    assert snapshot.values == %{
             "panel" => "compact",
             "show_diffs" => false,
             "keys" => %{"palette_open" => ["Ctrl-P"]}
           }

    assert snapshot.invalid == ["theme"]
    assert snapshot.unknown == ["x-unknown"]
    assert snapshot.mode == 0o600
    assert is_binary(snapshot.fingerprint)
  end

  test "a write keeps unknown keys and changes only its own", %{tmp_dir: dir} do
    write!(dir, ~s({"panel": "compact", "x-unknown": 1}))

    assert {:ok, snapshot} =
             CliFile.write_changes(path(dir), %{"diff_lines" => 20}, %{"diff_lines" => :absent})

    assert snapshot.values == %{"panel" => "compact", "diff_lines" => 20}
    assert snapshot.unknown == ["x-unknown"]
    assert JSON.decode!(File.read!(path(dir)))["x-unknown"] == 1
    assert leftovers(dir) == []
  end

  test "compare-and-set: a value changed elsewhere is a conflict and nothing is written", %{
    tmp_dir: dir
  } do
    write!(dir, ~s({"panel": "hidden"}))
    before = File.read!(path(dir))

    assert {:conflict, %{"panel" => "hidden"}} =
             CliFile.write_changes(path(dir), %{"panel" => "full"}, %{"panel" => "compact"})

    assert {:conflict, %{"theme" => :absent}} =
             CliFile.write_changes(path(dir), %{"theme" => "dark"}, %{"theme" => "light"})

    assert File.read!(path(dir)) == before

    assert {:ok, _} =
             CliFile.write_changes(path(dir), %{"panel" => "full"}, %{"panel" => "hidden"})

    assert {:ok, _} =
             CliFile.write_changes(path(dir), %{"panel" => "compact"}, %{"panel" => :any})
  end

  test "an invalid value or an unknown name is refused with its message", %{tmp_dir: dir} do
    assert {:error, :invalid, %{"diff_lines" => "must be between 4 and 200"}} =
             CliFile.write_changes(path(dir), %{"diff_lines" => 2}, %{})

    assert {:error, :invalid, %{"nope" => "not a setting"}} =
             CliFile.write_changes(path(dir), %{"nope" => 1}, %{})

    assert {:error, :invalid, %{"hint_letters" => "each letter once"}} =
             CliFile.write_changes(path(dir), %{"hint_letters" => "sfghjkls"}, %{})

    refute File.exists?(path(dir))
  end

  test "theme follow is the absent key", %{tmp_dir: dir} do
    write!(dir, ~s({"theme": "dark"}))

    assert {:ok, snapshot} =
             CliFile.write_changes(path(dir), %{"theme" => "follow"}, %{"theme" => "dark"})

    refute Map.has_key?(snapshot.values, "theme")
    refute Map.has_key?(JSON.decode!(File.read!(path(dir))), "theme")

    assert {:ok, _} =
             CliFile.write_changes(path(dir), %{"theme" => "light"}, %{"theme" => "follow"})
  end

  test "a 0644 file becomes 0600 on any write, even with no change", %{tmp_dir: dir} do
    write!(dir, ~s({"panel": "compact"}))
    File.chmod!(path(dir), 0o644)
    assert CliFile.read_all(path(dir)).mode == 0o644
    assert {:ok, snapshot} = CliFile.write_changes(path(dir), %{}, %{})
    assert snapshot.mode == 0o600
    assert snapshot.values == %{"panel" => "compact"}
  end

  test "a symbolic link is refused and not followed", %{tmp_dir: dir} do
    target = Path.join(dir, "elsewhere.json")
    File.write!(target, ~s({"panel": "compact"}))
    File.ln_s!(target, path(dir))
    assert %{status: :symlink, values: %{}} = CliFile.read_all(path(dir))
    assert {:error, :symlink} = CliFile.write_changes(path(dir), %{"panel" => "full"}, %{})
    assert File.read!(target) == ~s({"panel": "compact"})
    assert CliFile.words(:symlink) == "cli.json is a symbolic link; SwarmCode will not replace it"
  end

  test "a file that is not JSON is never replaced", %{tmp_dir: dir} do
    write!(dir, "{not json")
    assert %{status: :not_json} = CliFile.read_all(path(dir))
    assert {:error, :not_json} = CliFile.write_changes(path(dir), %{"panel" => "full"}, %{})

    assert {:ok, %{status: :not_json}} =
             CliFile.write_changes(path(dir), %{"panel" => :remove}, %{"panel" => :any})

    assert File.read!(path(dir)) == "{not json"
    assert leftovers(dir) == []
  end

  test "a larger file than 64 KiB is neither read nor written", %{tmp_dir: dir} do
    write!(dir, ~s({"x": ") <> String.duplicate("a", 65_600) <> ~s("}))
    assert %{status: :too_large, values: %{}} = CliFile.read_all(path(dir))
    assert {:error, :too_large} = CliFile.write_changes(path(dir), %{"panel" => "full"}, %{})
  end

  test "a writer between the read and the rename restarts the write once, then busy", %{
    tmp_dir: dir
  } do
    write!(dir, ~s({"panel": "compact"}))
    counter = :counters.new(1, [])

    once = fn attempt, file ->
      :counters.add(counter, 1, 1)
      if attempt == 1, do: File.write!(file, ~s({"panel": "compact", "mouse": false}))
    end

    assert {:ok, snapshot} =
             CliFile.write_changes(path(dir), %{"diff_lines" => 8}, %{"diff_lines" => :absent},
               before_rename: once
             )

    assert :counters.get(counter, 1) == 2
    assert snapshot.values == %{"panel" => "compact", "mouse" => false, "diff_lines" => 8}

    always = fn attempt, file -> File.write!(file, ~s({"panel": "hidden", "n": #{attempt}})) end

    assert {:error, :busy} =
             CliFile.write_changes(path(dir), %{"wheel_lines" => 5}, %{}, before_rename: always)

    assert leftovers(dir) == []
  end

  test "write_text: as typed, with warnings; not JSON, conflicts and symlinks are refused", %{
    tmp_dir: dir
  } do
    write!(dir, ~s({"panel": "compact"}))
    before = CliFile.read_all(path(dir)).fingerprint
    text = ~s({"panel": "hidden",\n  "theme": "neon", "x": 1}\n)

    assert {:ok, snapshot, %{"theme" => "is invalid"}} =
             CliFile.write_text(path(dir), text, before)

    assert File.read!(path(dir)) == text
    assert snapshot.values == %{"panel" => "hidden"}
    assert snapshot.mode == 0o600

    assert {:conflict, fingerprint} = CliFile.write_text(path(dir), ~s({}), before)
    assert fingerprint == snapshot.fingerprint

    assert {:error, {:not_json, 2}} =
             CliFile.write_text(path(dir), "{\n  \"panel\" \"x\"}", snapshot.fingerprint)

    assert File.read!(path(dir)) == text
    assert leftovers(dir) == []

    fresh = Path.join(dir, "fresh.json")
    assert {:ok, _snapshot, %{}} = CliFile.write_text(fresh, ~s({"panel": "full"}), nil)
  end

  test "the directory is created owner-only", %{tmp_dir: dir} do
    nested = Path.join([dir, "a", "b", "cli.json"])
    assert {:ok, _} = CliFile.write_changes(nested, %{"panel" => "hidden"}, %{})
    assert Bitwise.band(File.stat!(Path.dirname(nested)).mode, 0o777) == 0o700
  end
end
