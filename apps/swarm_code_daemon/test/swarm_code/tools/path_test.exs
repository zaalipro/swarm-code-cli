defmodule SwarmCode.Tools.PathTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Tools.Path, as: ToolPath

  test "resolves paths inside the root" do
    assert {:ok, "/tmp/r/a/b.ex"} = ToolPath.resolve("/tmp/r", "a/b.ex")
    assert {:ok, "/tmp/r"} = ToolPath.resolve("/tmp/r", ".")
  end

  test "rejects paths outside the root" do
    assert {:error, "path is outside the project root: ../x"} = ToolPath.resolve("/tmp/r", "../x")

    assert {:error, "path is outside the project root: /etc/passwd"} =
             ToolPath.resolve("/tmp/r", "/etc/passwd")
  end

  test "relative/2" do
    assert ToolPath.relative("/tmp/r", "/tmp/r/a") == "a"
    assert ToolPath.relative("/tmp/r", "/tmp/r") == "."
  end

  test "ignored_dir?/1" do
    assert ToolPath.ignored_dir?("node_modules")
    refute ToolPath.ignored_dir?("lib")
  end

  # Sakana task 1: a repository-controlled link loop used to recurse until the
  # BEAM gave up; every path operation on that repo wedged.
  describe "symlink cycles" do
    # These prove the resolver *terminates* on a cycle instead of looping
    # forever. 100 ms was tight enough that a loaded machine failed it for
    # reasons unrelated to the loop (spec 20 review); seconds still prove it.
    @no_hang_ms 5_000

    setup do
      root = tmp_dir()
      {:ok, root: root}
    end

    test "a self-referential link is an escape, not a hang", %{root: root} do
      File.ln_s!("a", Elixir.Path.join(root, "a"))

      task = Task.async(fn -> ToolPath.resolve(root, "a/x") end)
      assert {:error, "path is outside the project root: a/x"} = Task.await(task, @no_hang_ms)
    end

    test "a two-link loop is an escape, not a hang", %{root: root} do
      File.ln_s!("b", Elixir.Path.join(root, "a"))
      File.ln_s!("a", Elixir.Path.join(root, "b"))

      task = Task.async(fn -> ToolPath.resolve(root, "a/x") end)
      assert {:error, "path is outside the project root: a/x"} = Task.await(task, @no_hang_ms)
      refute ToolPath.confined?(root, "a/x")
    end

    test "an ordinary in-root link still resolves", %{root: root} do
      File.mkdir_p!(Elixir.Path.join(root, "sub"))
      File.write!(Elixir.Path.join(root, "sub/a.ex"), "x")
      File.ln_s!("sub", Elixir.Path.join(root, "link"))

      assert {:ok, path} = ToolPath.resolve(root, "link/a.ex")
      assert path == Elixir.Path.join(root, "link/a.ex")
      assert ToolPath.confined?(root, "link/a.ex")
    end

    test "a link to the filesystem root escapes", %{root: root} do
      File.ln_s!("/", Elixir.Path.join(root, "esc"))

      assert {:error, "path is outside the project root: esc/etc/hosts"} =
               ToolPath.resolve(root, "esc/etc/hosts")

      refute ToolPath.confined?(root, "esc/etc/hosts")
    end

    test "real_path/1 reports the cycle explicitly", %{root: root} do
      File.ln_s!("a", Elixir.Path.join(root, "a"))
      assert {:error, :symlink_cycle} = ToolPath.real_path(Elixir.Path.join(root, "a"))
      assert {:ok, real_root} = ToolPath.real_path(root)
      assert ToolPath.inside?(real_root, real_root)
    end
  end

  describe "pass45 (spec 51 §7.1)" do
    setup do
      root = tmp_dir()
      File.mkdir_p!(Elixir.Path.join(root, "lib/deep"))
      File.mkdir_p!(Elixir.Path.join(root, "_build.noindex/x"))
      File.mkdir_p!(Elixir.Path.join(root, "deps/dep"))
      File.write!(Elixir.Path.join(root, "lib/a.ex"), "a")
      File.write!(Elixir.Path.join(root, "lib/deep/b.exs"), "b")
      File.write!(Elixir.Path.join(root, ".hidden"), "h")
      File.write!(Elixir.Path.join(root, "_build.noindex/x/c.ex"), "c")
      File.write!(Elixir.Path.join(root, "deps/dep/d.ex"), "d")
      {:ok, root: root}
    end

    defp rel(root, paths), do: Enum.map(paths, &ToolPath.relative(root, &1))

    test "walk/3 returns every regular file, sorted, with the build dirs pruned", %{root: root} do
      assert rel(root, ToolPath.walk(root, root)) == [".hidden", "lib/a.ex", "lib/deep/b.exs"]
    end

    test "a nested git checkout is another project and is not entered", %{root: root} do
      # a worktree under .claude/worktrees/, a submodule, a vendored clone —
      # `.git` as a file or as a directory (spec 51 §7.1, Blockers → A 44)
      File.mkdir_p!(Elixir.Path.join(root, ".claude/worktrees/agent-1/lib"))
      File.write!(Elixir.Path.join(root, ".claude/worktrees/agent-1/.git"), "gitdir: elsewhere\n")
      File.write!(Elixir.Path.join(root, ".claude/worktrees/agent-1/lib/a.ex"), "x")
      File.mkdir_p!(Elixir.Path.join(root, "vendor/clone/.git"))
      File.write!(Elixir.Path.join(root, "vendor/clone/c.ex"), "x")

      assert rel(root, ToolPath.walk(root, root)) == [".hidden", "lib/a.ex", "lib/deep/b.exs"]

      assert rel(root, ToolPath.walk(root, root, dirs: true, dot: false)) ==
               ["lib", "lib/a.ex", "lib/deep", "lib/deep/b.exs", "vendor"]
    end

    test "walk/3 can start below the root", %{root: root} do
      assert rel(root, ToolPath.walk(root, Elixir.Path.join(root, "lib/deep"))) ==
               ["lib/deep/b.exs"]
    end

    test "the dot option matches Path.wildcard's match_dot: false", %{root: root} do
      assert rel(root, ToolPath.walk(root, root, dot: false)) == ["lib/a.ex", "lib/deep/b.exs"]
    end

    test "the dirs option adds the directories", %{root: root} do
      assert rel(root, ToolPath.walk(root, root, dirs: true, dot: false)) ==
               ["lib", "lib/a.ex", "lib/deep", "lib/deep/b.exs"]
    end

    test "a glob without a slash matches the base name", %{root: root} do
      assert rel(root, ToolPath.walk(root, root, glob: "*.ex")) == ["lib/a.ex"]

      assert rel(root, ToolPath.walk(root, root, glob: "*.{ex,exs}")) ==
               ["lib/a.ex", "lib/deep/b.exs"]

      assert rel(root, ToolPath.walk(root, root, glob: "?.ex")) == ["lib/a.ex"]
    end

    test "a glob with a slash matches the path relative to the start", %{root: root} do
      assert rel(root, ToolPath.walk(root, root, glob: "lib/**/*.ex*")) ==
               ["lib/a.ex", "lib/deep/b.exs"]

      assert rel(root, ToolPath.walk(root, root, glob: "lib/*")) == ["lib/a.ex"]
      assert ToolPath.walk(root, root, glob: "/etc/*") == []
    end

    test "a malformed glob is taken literally instead of raising", %{root: root} do
      assert ToolPath.walk(root, root, glob: "[a-") == []
    end

    # Sakana tasks 1-3, now inside the walker: confinement is checked before a
    # directory is entered, and a directory is entered once per *real* path.
    test "a link out of the project is never entered", %{root: root} do
      outside = tmp_dir()
      File.write!(Elixir.Path.join(outside, "secret.txt"), "s")
      File.ln_s!(outside, Elixir.Path.join(root, "escape"))
      File.ln_s!("/etc", Elixir.Path.join(root, "etc"))

      files = ToolPath.walk(root, root)
      refute Enum.any?(files, &String.contains?(&1, "secret.txt"))
      refute Enum.any?(files, &String.contains?(&1, "/etc/"))
      assert rel(root, files) == [".hidden", "lib/a.ex", "lib/deep/b.exs"]
    end

    test "a link cycle terminates", %{root: root} do
      File.ln_s!("loop", Elixir.Path.join(root, "loop"))
      File.ln_s!(".", Elixir.Path.join(root, "self"))

      task = Task.async(fn -> ToolPath.walk(root, root) end)
      assert rel(root, Task.await(task, 5_000)) == [".hidden", "lib/a.ex", "lib/deep/b.exs"]
    end

    test "an in-root directory link is followed once", %{root: root} do
      File.ln_s!("lib", Elixir.Path.join(root, "alias"))

      # `lib` and `alias` have the same real path, so the walker enters it once
      # and the file is listed under whichever name it reached first (`alias`,
      # which sorts first) — not twice, as `Path.wildcard/2` used to.
      assert rel(root, ToolPath.walk(root, root, glob: "*.ex")) == ["alias/a.ex"]
    end

    test "confined?/3 agrees with confined?/2", %{root: root} do
      {:ok, real_root} = ToolPath.real_path(root)

      assert ToolPath.confined?(real_root, root, Elixir.Path.join(root, "lib/a.ex"))
      assert ToolPath.confined?(root, Elixir.Path.join(root, "lib/a.ex"))

      File.ln_s!("/etc", Elixir.Path.join(root, "etc"))
      refute ToolPath.confined?(real_root, root, Elixir.Path.join(root, "etc/hosts"))
      refute ToolPath.confined?(root, Elixir.Path.join(root, "etc/hosts"))
    end

    test "entries/4 names each child once with its type and real path", %{root: root} do
      {:ok, real_root} = ToolPath.real_path(root)
      entries = ToolPath.entries(real_root, root, root)

      assert {".hidden", :regular, _abs, _real} = List.keyfind(entries, ".hidden", 0)
      assert {"lib", :directory, _labs, lreal} = List.keyfind(entries, "lib", 0)
      assert lreal == Elixir.Path.join(real_root, "lib")
      refute List.keyfind(entries, "_build.noindex", 0)
      refute List.keyfind(entries, "deps", 0)
    end
  end

  defp tmp_dir do
    dir =
      Elixir.Path.join(System.tmp_dir!(), "tool-regression-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
