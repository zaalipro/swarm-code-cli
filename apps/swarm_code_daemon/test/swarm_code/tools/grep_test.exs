defmodule SwarmCode.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Tools

  setup do
    dir = tmp_dir()
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "_build"))
    File.write!(Path.join([dir, "lib", "a.ex"]), "defmodule A do\n  def x, do: 1\nend\n")
    File.write!(Path.join([dir, "lib", "b.txt"]), "def x here\ndef x again\n")
    File.write!(Path.join([dir, "_build", "c.ex"]), "def x, do: 2\n")
    File.write!(Path.join(dir, "bin.dat"), <<0, 1, 2, "def x">>)

    {:ok, dir: dir, ctx: %{project_root: dir}, p: fn _, _ -> :ok end}
  end

  test "finds matches and skips ignored dirs and binaries", %{ctx: ctx, p: p} do
    assert {:ok, "lib/a.ex:2:   def x, do: 1"} =
             Tools.run("grep", %{"pattern" => "def x, do: 1"}, ctx, p)
  end

  test "glob restricts files", %{ctx: ctx, p: p} do
    assert {:ok, out} = Tools.run("grep", %{"pattern" => "def x", "glob" => "*.txt"}, ctx, p)
    assert out =~ "lib/b.txt:1"
    refute out =~ "lib/a.ex"
  end

  test "no matches", %{ctx: ctx, p: p} do
    assert {:ok, "no matches"} = Tools.run("grep", %{"pattern" => "zzzz"}, ctx, p)
  end

  test "invalid regex", %{ctx: ctx, p: p} do
    assert {:error, "invalid regex: " <> _} = Tools.run("grep", %{"pattern" => "("}, ctx, p)
  end

  test "max_results caps the output", %{ctx: ctx, p: p} do
    assert {:ok, out} = Tools.run("grep", %{"pattern" => "def x", "max_results" => 1}, ctx, p)
    assert String.ends_with?(out, "\n…[max_results reached]")
  end

  test "progress ends with the file count", %{ctx: ctx} do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    p = fn pct, detail -> Agent.update(agent, &[{pct, detail} | &1]) end

    assert {:ok, _} = Tools.run("grep", %{"pattern" => "def x"}, ctx, p)
    calls = Agent.get(agent, & &1)
    assert {100, detail} = hd(calls)
    assert detail =~ ~r|^\d+/\d+ files$|
  end

  # Sakana task 2: the starting directory passed confinement, but the wildcard
  # then walked a symlink out of the project.
  test "a symlinked directory outside the root is not searched", %{dir: dir, ctx: ctx, p: p} do
    outside = tmp_dir()
    File.write!(Path.join(outside, "secret.txt"), "def x SUPERSECRET\n")
    File.ln_s!(outside, Path.join(dir, "escape"))

    assert {:ok, out} = Tools.run("grep", %{"pattern" => "def x"}, ctx, p)
    refute out =~ "SUPERSECRET"
    refute out =~ "secret.txt"
    assert out =~ "lib/b.txt"
  end

  test "a symlinked file outside the root is not read", %{dir: dir, ctx: ctx, p: p} do
    outside = tmp_dir()
    File.write!(Path.join(outside, "secret.txt"), "def x SUPERSECRET\n")
    File.ln_s!(Path.join(outside, "secret.txt"), Path.join(dir, "leak.txt"))

    assert {:ok, out} = Tools.run("grep", %{"pattern" => "def x"}, ctx, p)
    refute out =~ "SUPERSECRET"
    assert out =~ "lib/b.txt"
  end

  test "a symlink cycle does not wedge the search", %{dir: dir, ctx: ctx, p: p} do
    File.ln_s!("loop", Path.join(dir, "loop"))

    task = Task.async(fn -> Tools.run("grep", %{"pattern" => "def x"}, ctx, p) end)
    assert {:ok, out} = Task.await(task, 5_000)
    assert out =~ "lib/b.txt"
  end

  describe "pass45 (spec 51 §7.1)" do
    test "every _build* directory is skipped, not only _build", %{dir: dir, ctx: ctx, p: p} do
      File.mkdir_p!(Path.join(dir, "_build.noindex/lib"))
      File.write!(Path.join(dir, "_build.noindex/lib/gen.ex"), "def x, do: 3\n")

      assert {:ok, out} = Tools.run("grep", %{"pattern" => "def x"}, ctx, p)
      refute out =~ "_build"
      assert out =~ "lib/b.txt"
    end

    test "a large binary whose NUL is in the first 8 KB is excluded", %{
      dir: dir,
      ctx: ctx,
      p: p
    } do
      File.write!(Path.join(dir, "big.bin"), <<0>> <> String.duplicate("def x here\n", 50_000))

      assert {:ok, out} = Tools.run("grep", %{"pattern" => "def x here"}, ctx, p)

      refute out =~ "big.bin"
      assert out =~ "lib/b.txt"
    end

    test "a glob with a directory part matches the path under the search root", %{
      dir: dir,
      ctx: ctx,
      p: p
    } do
      File.mkdir_p!(Path.join(dir, "lib/nested"))
      File.write!(Path.join([dir, "lib", "nested", "c.ex"]), "def x deep\n")

      assert {:ok, out} =
               Tools.run("grep", %{"pattern" => "def x", "glob" => "lib/**/*.ex"}, ctx, p)

      assert out =~ "lib/a.ex"
      assert out =~ "lib/nested/c.ex"
      refute out =~ "b.txt"
    end
  end

  describe "pass45 (spec 51 §7.2)" do
    test "a pattern that backtracks is refused, not run to the end", %{dir: dir, ctx: ctx, p: p} do
      File.write!(Path.join(dir, "bt.txt"), String.duplicate("a", 40) <> "b\n")

      {micros, result} = :timer.tc(fn -> Tools.run("grep", %{"pattern" => "(a+)+$"}, ctx, p) end)

      assert {:error, "the pattern backtracks too much on bt.txt:1 — simplify it"} = result
      assert micros < 1_000_000
    end

    test "a line longer than 4 KB is matched on its first 4 KB", %{dir: dir, ctx: ctx, p: p} do
      File.write!(Path.join(dir, "long.txt"), String.duplicate("x", 5_000) <> "needle\n")

      assert {:ok, "no matches"} = Tools.run("grep", %{"pattern" => "needle"}, ctx, p)
      assert {:ok, out} = Tools.run("grep", %{"pattern" => "^x+"}, ctx, p)
      assert out =~ "long.txt:1"
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "tool-regression-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  test "negative lookahead is evaluated per line, not against a trailing newline", %{
    dir: dir,
    ctx: ctx,
    p: p
  } do
    File.write!(Path.join(dir, "lookahead.txt"), "foo\n")

    assert {:ok, "lookahead.txt:1: foo"} =
             Tools.run("grep", %{"path" => "lookahead.txt", "pattern" => "foo(?!\\n)"}, ctx, p)
  end
end
