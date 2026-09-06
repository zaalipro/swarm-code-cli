defmodule SwarmCode.Tools.CodingToolsTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Tools

  setup do
    base = Path.join(System.tmp_dir!(), "coding-tools-#{System.unique_integer([:positive])}")
    root = Path.join(base, "project")
    outside = Path.join(base, "outside")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(base) end)
    %{root: root, outside: outside, ctx: %{project_root: root}, p: fn _, _ -> :ok end}
  end

  test "the closed registry validates before permission or execution", %{ctx: ctx, p: p} do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"
    assert {:error, _} = Tools.permission("unknown", %{})
    assert {:error, _} = Tools.run("unknown", %{}, ctx, p)

    for {tool, args} <- [
          {"write_file", %{"path" => "a", "content" => 42}},
          {"edit_file", %{"path" => "a", "old_string" => "x"}},
          {"read_file", %{"path" => ["a"]}},
          {"list_dir", %{"depth" => "3"}},
          {"grep", %{"pattern" => "x", "max_results" => -1}},
          {"run_command", %{"command" => "touch unwanted", "timeout_ms" => "1"}},
          {"read_file", %{"path" => "a", "surprise" => true}}
        ] do
      assert {:error, _} = Tools.permission(tool, args)
      assert {:error, _} = Tools.run(tool, args, ctx, p)
    end

    assert {:ok, :read} = Tools.permission("read_file", %{"path" => "a"})
    assert {:ok, :write} = Tools.permission("write_file", %{"path" => "a", "content" => ""})
    assert {:ok, :execute} = Tools.permission("run_command", %{"command" => "true"})

    assert Enum.sort(Enum.map(Tools.specs(), & &1.name)) ==
             ~w(edit_file grep list_dir read_file run_command write_file)

    assert File.ls!(ctx.project_root) == []
  end

  test "actual create read search exact edit and list", %{root: root, ctx: ctx, p: p} do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"

    assert {:ok, _} =
             Tools.run(
               "write_file",
               %{"path" => "lib/a.ex", "content" => "alpha\nbeta\n"},
               ctx,
               p
             )

    assert File.read!(Path.join(root, "lib/a.ex")) == "alpha\nbeta\n"

    assert {:ok, read} =
             Tools.run("read_file", %{"path" => "lib/a.ex", "offset" => 2, "limit" => 1}, ctx, p)

    assert read =~ "beta"
    refute read =~ "alpha"
    assert {:ok, search} = Tools.run("grep", %{"pattern" => "^beta$", "glob" => "*.ex"}, ctx, p)
    assert search =~ "lib/a.ex:2: beta"
    assert {:ok, listing} = Tools.run("list_dir", %{"depth" => 2}, ctx, p)
    assert listing =~ "lib/a.ex"

    assert {:ok, _} =
             Tools.run(
               "edit_file",
               %{"path" => "lib/a.ex", "old_string" => "beta", "new_string" => "gamma"},
               ctx,
               p
             )

    assert File.read!(Path.join(root, "lib/a.ex")) == "alpha\ngamma\n"
  end

  test "missing nonunique and empty edits leave original bytes untouched", %{
    root: root,
    ctx: ctx,
    p: p
  } do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"
    File.write!(Path.join(root, "a"), "x x")

    for old <- ["missing", "x", ""] do
      assert {:error, _} =
               Tools.run(
                 "edit_file",
                 %{"path" => "a", "old_string" => old, "new_string" => "changed"},
                 ctx,
                 p
               )

      assert File.read!(Path.join(root, "a")) == "x x"
      assert File.ls!(root) == ["a"]
    end

    assert {:ok, _} =
             Tools.run(
               "edit_file",
               %{"path" => "a", "old_string" => "x", "new_string" => "y", "replace_all" => true},
               ctx,
               p
             )

    assert File.read!(Path.join(root, "a")) == "y y"
  end

  test "all path tools refuse lexical symlink and nested symlink escapes", %{
    root: root,
    outside: outside,
    ctx: ctx,
    p: p
  } do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"
    File.write!(Path.join(outside, "secret"), "outside secret")
    File.mkdir_p!(Path.join(root, "real"))
    File.ln_s!(outside, Path.join(root, "escape"))
    File.ln_s!(outside, Path.join(root, "real/inner"))
    File.ln_s!("real", Path.join(root, "alias"))
    File.ln_s!("loop", Path.join(root, "loop"))

    for path <- ["../outside/secret", "escape/secret", "alias/inner/secret", "loop/a"] do
      for {name, args} <- [
            {"read_file", %{"path" => path}},
            {"write_file", %{"path" => path, "content" => "changed"}},
            {"edit_file", %{"path" => path, "old_string" => "secret", "new_string" => "changed"}},
            {"grep", %{"path" => path, "pattern" => "secret"}},
            {"list_dir", %{"path" => path}}
          ] do
        assert {:error, _} = Tools.run(name, args, ctx, p)
      end
    end

    assert File.read!(Path.join(outside, "secret")) == "outside secret"
    assert {:ok, matches} = Tools.run("grep", %{"pattern" => "secret"}, ctx, p)
    refute matches =~ "outside secret"
  end

  test "writes preserve an in-root symlink and executable mode", %{root: root, ctx: ctx, p: p} do
    assert Code.ensure_loaded?(Tools), "coding tool registry is missing"
    File.write!(Path.join(root, "real"), "old")
    File.chmod!(Path.join(root, "real"), 0o755)
    File.ln_s!("real", Path.join(root, "link"))
    assert {:ok, _} = Tools.run("write_file", %{"path" => "link", "content" => "new"}, ctx, p)
    assert File.read!(Path.join(root, "real")) == "new"
    assert File.lstat!(Path.join(root, "link")).type == :symlink
    assert Bitwise.band(File.stat!(Path.join(root, "real")).mode, 0o777) == 0o755
  end

  test "parent segments in symlink targets follow the physical intermediate directory", %{
    root: root,
    outside: outside,
    ctx: ctx,
    p: p
  } do
    File.mkdir_p!(Path.join(root, "sub"))
    File.mkdir_p!(Path.join(outside, "deep"))
    File.write!(Path.join(outside, "secret"), "outside secret")
    File.write!(Path.join(root, "sub/secret"), "inside original")
    File.ln_s!(Path.join(outside, "deep"), Path.join(root, "sub/alias"))
    File.ln_s!("sub/alias/../secret", Path.join(root, "link"))

    assert File.read!(Path.join(root, "link")) == "outside secret"

    for {name, args} <- [
          {"read_file", %{"path" => "link"}},
          {"write_file", %{"path" => "link", "content" => "changed"}},
          {"edit_file", %{"path" => "link", "old_string" => "secret", "new_string" => "changed"}},
          {"grep", %{"path" => "link", "pattern" => "secret"}}
        ] do
      assert {:error, _} = Tools.run(name, args, ctx, p)
    end

    assert File.read!(Path.join(outside, "secret")) == "outside secret"
    assert File.read!(Path.join(root, "sub/secret")) == "inside original"
    assert {:ok, found} = Tools.run("grep", %{"pattern" => "secret"}, ctx, p)
    refute found =~ "outside secret"
  end

  test "parent segments after an in-root symlink resolve to its physical parent", %{
    root: root,
    ctx: ctx,
    p: p
  } do
    File.mkdir_p!(Path.join(root, "sub"))
    File.mkdir_p!(Path.join(root, "real/deep"))
    File.write!(Path.join(root, "real/target"), "physical")
    File.write!(Path.join(root, "sub/target"), "lexical")
    File.ln_s!("../real/deep", Path.join(root, "sub/alias"))
    File.ln_s!("sub/alias/../target", Path.join(root, "link"))
    assert {:ok, read} = Tools.run("read_file", %{"path" => "link"}, ctx, p)
    assert read =~ "physical"
    assert {:ok, _} = Tools.run("write_file", %{"path" => "link", "content" => "updated"}, ctx, p)
    assert File.read!(Path.join(root, "real/target")) == "updated"
    assert File.read!(Path.join(root, "sub/target")) == "lexical"
    assert File.lstat!(Path.join(root, "link")).type == :symlink
  end
end
