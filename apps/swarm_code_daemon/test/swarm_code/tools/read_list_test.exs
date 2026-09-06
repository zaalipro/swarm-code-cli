defmodule SwarmCode.Tools.ReadListTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Tools

  setup do
    dir = tmp_dir()
    {:ok, dir: dir, ctx: %{project_root: dir}, p: fn _, _ -> :ok end}
  end

  test "reads a file", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "l1\nl2\nl3\n")

    assert {:ok, "a.txt (3 lines)\nl1\nl2\nl3"} =
             Tools.run("read_file", %{"path" => "a.txt"}, ctx, p)
  end

  test "offset and limit", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "l1\nl2\nl3\n")

    assert {:ok, "a.txt (3 lines)\nl2\n…[truncated, 1 more lines; call again with offset=3]"} =
             Tools.run("read_file", %{"path" => "a.txt", "offset" => 2, "limit" => 1}, ctx, p)
  end

  test "missing file", %{ctx: ctx, p: p} do
    assert {:error, "file not found: nope.txt"} =
             Tools.run("read_file", %{"path" => "nope.txt"}, ctx, p)
  end

  test "outside the root", %{ctx: ctx, p: p} do
    assert {:error, "path is outside the project root: ../x"} =
             Tools.run("read_file", %{"path" => "../x"}, ctx, p)
  end

  test "list_dir", %{dir: dir, ctx: ctx, p: p} do
    File.mkdir_p!(Path.join(dir, "b"))
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, "a.txt"), "x")
    File.write!(Path.join([dir, "b", "c.txt"]), "y")

    assert {:ok, "b/\na.txt"} = Tools.run("list_dir", %{}, ctx, p)
    assert {:ok, "b/\nb/c.txt\na.txt"} = Tools.run("list_dir", %{"depth" => 2}, ctx, p)
  end

  test "empty dir", %{dir: dir, ctx: ctx, p: p} do
    File.mkdir_p!(Path.join(dir, "empty"))
    assert {:ok, "(empty)"} = Tools.run("list_dir", %{"path" => "empty"}, ctx, p)
  end

  test "truncates long output", %{dir: dir, ctx: ctx, p: p} do
    content = String.duplicate("x", 120_000)
    File.write!(Path.join(dir, "big.txt"), content)

    assert {:ok, out} = Tools.run("read_file", %{"path" => "big.txt", "limit" => 5000}, ctx, p)
    assert out =~ "[truncated: file has 1 lines; request a range with offset/limit]"
    assert String.length(out) < 41_000
  end

  # Sakana task 2/3: `File.ls/1` follows directory symlinks, so a link out of the
  # project used to name and recurse into the target's children.
  test "list_dir does not name or recurse into an outside symlink", %{dir: dir, ctx: ctx, p: p} do
    outside = tmp_dir()
    File.mkdir_p!(Path.join(outside, "private"))
    File.write!(Path.join([outside, "private", "secret.txt"]), "s")
    File.write!(Path.join(outside, "top.txt"), "t")

    File.mkdir_p!(Path.join(dir, "lib"))
    File.write!(Path.join([dir, "lib", "a.ex"]), "x")
    File.ln_s!(outside, Path.join(dir, "escape"))

    assert {:ok, out} = Tools.run("list_dir", %{"path" => ".", "depth" => 3}, ctx, p)
    assert out =~ "lib/"
    assert out =~ "a.ex"
    refute out =~ "escape"
    refute out =~ "secret.txt"
    refute out =~ "top.txt"
  end

  test "list_dir survives a symlink cycle", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "a.txt"), "x")
    File.ln_s!("loop", Path.join(dir, "loop"))

    task = Task.async(fn -> Tools.run("list_dir", %{"path" => ".", "depth" => 3}, ctx, p) end)
    assert {:ok, out} = Task.await(task, 5_000)
    assert out =~ "a.txt"
    refute out =~ "loop"
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "tool-regression-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
