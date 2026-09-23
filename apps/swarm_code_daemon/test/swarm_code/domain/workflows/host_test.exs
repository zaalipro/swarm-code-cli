defmodule SwarmCode.Domain.Workflows.HostTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Workflows.Host

  setup do
    root = Path.join(System.tmp_dir!(), "host-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, "lib", "app", "web"]))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join([root, "lib", "app.ex"]), "defmodule App do\n  @moon true\nend\n")
    File.write!(Path.join([root, "lib", "app", "core.ex"]), "defmodule App.Core do\nend\n")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  test "list_dir names every entry with its root-relative path and dir flag", %{root: root} do
    entries = Host.run(:list_dir, [path: "lib"], root)

    assert %{name: "app", path: "lib/app", dir?: true} in entries
    assert %{name: "app.ex", path: "lib/app.ex", dir?: false} in entries
  end

  test "subdirs is the sorted list of child directories", %{root: root} do
    assert Host.run(:subdirs, [path: "lib"], root) == ["lib/app"]
    assert Host.run(:subdirs, [path: "."], root) == ["lib", "test"]
    assert Host.run(:subdirs, [path: "nope"], root) == []
  end

  test "files globs files only, glob keeps directories", %{root: root} do
    assert Host.run(:files, [pattern: "lib/**/*.ex"], root) == ["lib/app.ex", "lib/app/core.ex"]
    assert "lib/app" in Host.run(:glob, [pattern: "lib/*"], root)
    refute "lib/app" in Host.run(:files, [pattern: "lib/*"], root)
  end

  test "exists?, dir? and read_file resolve against the project root", %{root: root} do
    assert Host.run(:exists?, [path: "lib/app.ex"], root)
    refute Host.run(:exists?, [path: "lib/nope.ex"], root)
    assert Host.run(:dir?, [path: "lib"], root)
    refute Host.run(:dir?, [path: "lib/app.ex"], root)
    assert Host.run(:read_file, [path: "lib/app.ex"], root) =~ "defmodule App"
  end

  test "paths can never leave the project", %{root: root} do
    assert Host.run(:read_file, [path: "../../etc/hosts"], root) ==
             "path is outside the project root: ../../etc/hosts"

    refute Host.run(:exists?, [path: "../"], root)
    refute Host.run(:dir?, [path: "../"], root)
    assert Host.run(:list_dir, [path: "../.."], root) == []
  end

  test "grep finds matches with file and line", %{root: root} do
    assert [%{file: "lib/app.ex", line: 2, text: "@moon true"}] =
             Host.run(:grep, [pattern: "@moon", path: "lib"], root)

    assert Host.run(:grep, [pattern: "nothing here", path: "lib"], root) == []
  end

  test "git_log is empty outside a repository", %{root: root} do
    assert Host.run(:git_log, [n: 3], root) == []
  end

  test "normalize puts the atom keys back after a journal replay" do
    replayed = [%{"name" => "app", "path" => "lib/app", "dir?" => true}]
    assert Host.normalize(:list_dir, replayed) == [%{name: "app", path: "lib/app", dir?: true}]

    assert Host.normalize(:grep, [%{"file" => "a.ex", "line" => 3, "text" => "x"}]) ==
             [%{file: "a.ex", line: 3, text: "x"}]

    assert Host.normalize(:read_file, "text") == "text"
  end

  test "every op is read-only, so the smoke check may run them for real" do
    assert Enum.all?(Host.ops(), &Host.read_only?/1)
  end
end
