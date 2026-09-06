defmodule SwarmCode.Tools.WriteEditTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Tools

  setup do
    dir = tmp_dir()
    {:ok, dir: dir, ctx: %{project_root: dir}, p: fn _, _ -> :ok end}
  end

  test "write creates parent directories", %{dir: dir, ctx: ctx, p: p} do
    assert {:ok, "wrote 5 bytes to sub/dir/new.txt"} =
             Tools.run("write_file", %{"path" => "sub/dir/new.txt", "content" => "hello"}, ctx, p)

    assert File.read!(Path.join([dir, "sub", "dir", "new.txt"])) == "hello"
  end

  test "write outside the root", %{ctx: ctx, p: p} do
    assert {:error, "path is outside the project root: ../x.txt"} =
             Tools.run("write_file", %{"path" => "../x.txt", "content" => "x"}, ctx, p)
  end

  test "edit unique match", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "alpha beta")

    assert {:ok, "edited a.txt: 1 replacement(s)"} =
             Tools.run(
               "edit_file",
               %{"path" => "a.txt", "old_string" => "beta", "new_string" => "gamma"},
               ctx,
               p
             )

    assert File.read!(Path.join(dir, "a.txt")) == "alpha gamma"
  end

  test "edit not found", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "alpha")

    assert {:error, "old_string not found in a.txt"} =
             Tools.run(
               "edit_file",
               %{"path" => "a.txt", "old_string" => "zzz", "new_string" => "y"},
               ctx,
               p
             )
  end

  test "edit ambiguous", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "x y x")

    assert {:error,
            "old_string matches 2 places in a.txt; provide more context or set replace_all=true"} =
             Tools.run(
               "edit_file",
               %{"path" => "a.txt", "old_string" => "x", "new_string" => "z"},
               ctx,
               p
             )
  end

  test "edit replace_all", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "x y x")

    assert {:ok, "edited a.txt: 2 replacement(s)"} =
             Tools.run(
               "edit_file",
               %{
                 "path" => "a.txt",
                 "old_string" => "x",
                 "new_string" => "z",
                 "replace_all" => true
               },
               ctx,
               p
             )

    assert File.read!(Path.join(dir, "a.txt")) == "z y z"
  end

  test "edit empty old_string", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "x")

    assert {:error, "old_string must not be empty"} =
             Tools.run(
               "edit_file",
               %{"path" => "a.txt", "old_string" => "", "new_string" => "y"},
               ctx,
               p
             )
  end

  # ------------------------------------------------------------------ spec 32 §1

  test "a write lands whole and leaves no temporary", %{dir: dir, ctx: ctx, p: p} do
    content = String.duplicate("x", 200_000)

    assert {:ok, _} =
             Tools.run("write_file", %{"path" => "big.txt", "content" => content}, ctx, p)

    assert File.read!(Path.join(dir, "big.txt")) == content
    assert dir |> File.ls!() |> Enum.filter(&String.contains?(&1, "swarm-code-")) == []
  end

  test "a link inside the project is written through, not replaced", %{dir: dir, ctx: ctx, p: p} do
    File.mkdir_p!(Path.join(dir, "docs"))
    File.write!(Path.join(dir, "docs/real.md"), "old")
    File.ln_s!("docs/real.md", Path.join(dir, "README.md"))

    assert {:ok, _} =
             Tools.run("write_file", %{"path" => "README.md", "content" => "new"}, ctx, p)

    # The user's layout is not the model's to change.
    assert File.lstat!(Path.join(dir, "README.md")).type == :symlink
    assert File.read!(Path.join(dir, "docs/real.md")) == "new"
  end

  test "a link out of the project is refused, and the target is untouched", %{
    dir: dir,
    ctx: ctx,
    p: p
  } do
    outside = Path.join(System.tmp_dir!(), "escape_#{System.unique_integer([:positive])}.txt")
    File.write!(outside, "safe")
    on_exit(fn -> File.rm(outside) end)
    File.ln_s!(outside, Path.join(dir, "escape.txt"))

    assert {:error, message} =
             Tools.run("write_file", %{"path" => "escape.txt", "content" => "pwned"}, ctx, p)

    assert message =~ "outside the project root"
    assert File.read!(outside) == "safe"

    assert {:error, _} =
             Tools.run(
               "edit_file",
               %{"path" => "escape.txt", "old_string" => "safe", "new_string" => "pwned"},
               ctx,
               p
             )

    assert File.read!(outside) == "safe"
  end

  describe "pass45 (spec 51 §7.5)" do
    # M9: `edit_file` read and split anything `read_file` would have refused.
    test "a file over 5 MB is refused before it is read", %{dir: dir, ctx: ctx, p: p} do
      path = Path.join(dir, "huge.txt")
      File.write!(path, String.duplicate("x", 6_000_000))

      assert {:error, message} =
               Tools.run(
                 "edit_file",
                 %{"path" => "huge.txt", "old_string" => "x", "new_string" => "y"},
                 ctx,
                 p
               )

      assert message ==
               "file too large to edit: huge.txt (6000000 bytes) — use run_command with sed or perl"

      assert File.stat!(path).size == 6_000_000
    end

    test "a binary file is refused", %{dir: dir, ctx: ctx, p: p} do
      File.write!(Path.join(dir, "b.bin"), <<0, 1, 2>>)

      assert {:error, "cannot edit a binary file: b.bin"} =
               Tools.run(
                 "edit_file",
                 %{"path" => "b.bin", "old_string" => <<1>>, "new_string" => <<3>>},
                 ctx,
                 p
               )

      assert File.read!(Path.join(dir, "b.bin")) == <<0, 1, 2>>
    end

    test "the occurrence count agrees with String.replace/4", %{dir: dir, ctx: ctx, p: p} do
      content = "ab ab ab\nabab\n"
      File.write!(Path.join(dir, "c.txt"), content)

      expected = length(String.split(content, "ab")) - 1
      assert expected == length(:binary.matches(content, "ab"))

      assert {:error, message} =
               Tools.run(
                 "edit_file",
                 %{"path" => "c.txt", "old_string" => "ab", "new_string" => "z"},
                 ctx,
                 p
               )

      assert message =~ "old_string matches #{expected} places in c.txt"

      assert {:ok, "edited c.txt: 5 replacement(s)"} =
               Tools.run(
                 "edit_file",
                 %{
                   "path" => "c.txt",
                   "old_string" => "ab",
                   "new_string" => "z",
                   "replace_all" => true
                 },
                 ctx,
                 p
               )

      assert File.read!(Path.join(dir, "c.txt")) == String.replace(content, "ab", "z")
    end

    test "a missing file still reports not found", %{ctx: ctx, p: p} do
      assert {:error, "file not found: nope.txt"} =
               Tools.run(
                 "edit_file",
                 %{"path" => "nope.txt", "old_string" => "a", "new_string" => "b"},
                 ctx,
                 p
               )
    end

    # spec 60 T18: the result is capped at the same 5 MB as the source.
    test "an edit whose result would pass 5 MB is refused", %{dir: dir, ctx: ctx, p: p} do
      content = String.duplicate("a", 500_000)
      File.write!(Path.join(dir, "big.txt"), content)

      assert {:error, msg} =
               Tools.run(
                 "edit_file",
                 %{
                   "path" => "big.txt",
                   "old_string" => "a",
                   "new_string" => "bbbbbbbbbbbb",
                   "replace_all" => true
                 },
                 ctx,
                 p
               )

      assert msg =~ "past 5 MB"
      assert File.read!(Path.join(dir, "big.txt")) == content
      assert File.ls!(dir) == ["big.txt"]
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "tool-regression-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
