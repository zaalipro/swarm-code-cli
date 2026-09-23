defmodule SwarmCode.Domain.GitTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Git

  setup do
    dir = Path.join([System.tmp_dir!(), "swarm_code_git", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    init!(dir)
    File.write!(Path.join(dir, "a.txt"), "one\n")
    {:ok, _} = Git.commit(dir, "init")

    %{dir: dir}
  end

  defp init!(dir) do
    {:ok, _} = Git.run(dir, ["init", "-q", "-b", "main"])
    {:ok, _} = Git.run(dir, ["config", "user.email", "test@example.com"])
    {:ok, _} = Git.run(dir, ["config", "user.name", "Test"])
    {:ok, _} = Git.run(dir, ["config", "commit.gpgsign", "false"])
  end

  test "repo?/1", %{dir: dir} do
    assert Git.repo?(dir)

    refute Git.repo?(
             System.tmp_dir!()
             |> Path.join("swarm_code_not_a_repo_#{:rand.uniform(999)}")
           )

    refute Git.repo?(nil)
  end

  test "head, current_branch, log", %{dir: dir} do
    assert Git.current_branch(dir) == "main"
    assert String.length(Git.head(dir)) == 40
    assert {:ok, log} = Git.log(dir, 5)
    assert log =~ "init"
  end

  test "status and diff", %{dir: dir} do
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    File.write!(Path.join(dir, "b.txt"), "new\n")

    status = Git.status(dir)
    assert %{path: "a.txt", y: "M"} = Enum.find(status, &(&1.path == "a.txt"))
    assert %{untracked?: true} = Enum.find(status, &(&1.path == "b.txt"))

    diff = Git.diff(dir)
    assert diff =~ "+two"

    {summary, files} = Git.diff_stat(dir)
    assert summary =~ "1 file changed"
    assert [%{path: "a.txt", added: 1, removed: 0}] = files

    # spec 60 T25: " -> " is a rename marker only on R/C entries.
    File.write!(Path.join(dir, "a -> b.txt"), "x")
    assert %{untracked?: true} = Enum.find(Git.status(dir), &(&1.path == "a -> b.txt"))

    {:ok, _} = Git.run(dir, ["mv", "a.txt", "c.txt"])
    assert %{x: "R"} = Enum.find(Git.status(dir), &(&1.path == "c.txt"))
  end

  test "commit stages everything by default", %{dir: dir} do
    File.write!(Path.join(dir, "c.txt"), "c\n")
    assert {:ok, _} = Git.commit(dir, "add c")
    assert Git.status(dir) == []
  end

  # spec 60 T24: a commit with paths commits only those paths.
  test "commit with paths leaves the rest of the index staged", %{dir: dir} do
    File.write!(Path.join(dir, "b.txt"), "b\n")
    {:ok, _} = Git.run(dir, ["add", "b.txt"])
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")

    assert {:ok, _} = Git.commit(dir, "only a", ["a.txt"])

    {:ok, shown} = Git.run(dir, ["show", "--stat", "--format=", "HEAD"])
    assert shown =~ "a.txt"
    refute shown =~ "b.txt"
    assert Git.run(dir, ["diff", "--cached", "--name-only"]) == {:ok, "b.txt\n"}

    assert Git.commit(dir, "x", ["-rf"]) == {:error, "invalid path"}
  end

  test "worktree add/remove and merge", %{dir: dir} do
    wt = Path.join(dir, ".swarm_code/worktrees/w1")
    assert {:ok, _} = Git.worktree_add(dir, wt, "swarm/w1")
    assert File.dir?(wt)

    File.write!(Path.join(wt, "from_branch.txt"), "hello\n")
    assert {:ok, _} = Git.commit(wt, "branch work")

    refute File.exists?(Path.join(dir, "from_branch.txt"))
    assert {:ok, _} = Git.merge(dir, "swarm/w1")
    assert File.exists?(Path.join(dir, "from_branch.txt"))

    assert {:ok, _} = Git.worktree_remove(dir, wt)
    assert {:ok, _} = Git.branch_delete(dir, "swarm/w1")
  end

  test "merge conflicts are reported and aborted", %{dir: dir} do
    wt = Path.join(dir, ".swarm_code/worktrees/w2")
    {:ok, _} = Git.worktree_add(dir, wt, "swarm/w2")

    File.write!(Path.join(wt, "a.txt"), "branch\n")
    {:ok, _} = Git.commit(wt, "branch change")

    File.write!(Path.join(dir, "a.txt"), "root\n")
    {:ok, _} = Git.commit(dir, "root change")

    assert {:error, {:conflicts, paths}} = Git.merge(dir, "swarm/w2")
    assert "a.txt" in paths
    # Aborted: the work tree is clean again.
    assert Git.status(dir) == []
  end

  test "exclude! is idempotent", %{dir: dir} do
    Git.exclude!(dir, ".swarm_code/")
    Git.exclude!(dir, ".swarm_code/")
    text = File.read!(Path.join(dir, ".git/info/exclude"))
    assert length(Enum.filter(String.split(text, "\n"), &(&1 == ".swarm_code/"))) == 1
  end

  test "errors do not raise", %{dir: dir} do
    assert {:error, out} = Git.run(dir, ["not-a-command"])
    assert is_binary(out)
  end

  test "validates revisions before they become git operands" do
    for revision <- ["HEAD", "HEAD~1", "main", "feature/x", "a1b2c3d"] do
      assert Git.validate_revision(revision) == {:ok, revision}
    end

    for revision <- ["--upload-pack=x", "-n", "a b", "$(id)", ""] do
      assert Git.validate_revision(revision) == {:error, "invalid git revision: " <> revision}
    end
  end

  test "large output is drained but returns the existing character cap", %{dir: dir} do
    shim = Path.join(dir, "git-flood")

    File.write!(shim, """
    #!/bin/sh
    yes x | head -c 5000000
    """)

    File.chmod!(shim, 0o755)
    assert {:ok, output} = Git.run(dir, ["status"], executable: shim)
    assert String.length(output) == 200_000 + String.length("\n…[truncated]")
    assert String.ends_with?(output, "\n…[truncated]")
  end

  # ------------------------------------- sakana task 18: git trees are reaped

  # The shim must be allowed the whole timeout window to be forked, and the
  # grandchild must outlive that window, or the test measures machine load
  # instead of the kill (spec 20 review).
  @git_timeout_ms 6_000
  @grandchild_s 10

  test "a timed-out git leaves no process behind", %{dir: dir} do
    marker = Path.join(dir, "git_delayed.marker")
    ready = Path.join(dir, "git_shim.ready")
    shim = Path.join(dir, "git-shim")

    # `ready` is the shim's first action; the grandchild fires well after the
    # timeout, so it can only exist if the kill missed it.
    File.write!(shim, """
    #!/bin/sh
    touch #{ready}
    sh -c 'sleep #{@grandchild_s} && touch #{marker}' &
    sleep 120
    """)

    File.chmod!(shim, 0o755)

    # The property under test is that the timeout reaps the whole process tree,
    # not how fast the OS gets around to forking the shim. With 16 parallel
    # ExUnit cases that fork can take seconds, which failed this test at a 1 s,
    # then 3 s, then 3 s-poll budget (spec 20 review). The shim now gets the
    # whole timeout window to come up, and the grandchild sleeps past it.
    timeout = @git_timeout_ms
    task = Task.async(fn -> Git.run(dir, ["status"], timeout: timeout, executable: shim) end)

    unless wait_for_file(ready, timeout) do
      flunk("""
      the shim never started within #{timeout} ms
        dir listing: #{inspect(File.ls(dir))}
        task alive?: #{inspect(Process.alive?(task.pid))}
        early result: #{inspect(Task.yield(task, 0))}
      """)
    end

    assert {:error, message} = Task.await(task, timeout + 10_000)
    assert message == "git timed out after #{timeout} ms"

    # Past the grandchild's sleep, counted from when it was spawned: it must
    # never have fired, and nothing of the tree is left running.
    Process.sleep((@grandchild_s + 2) * 1_000)
    refute File.exists?(marker)
  end

  defp wait_for_file(path, remaining) when remaining <= 0, do: File.exists?(path)

  defp wait_for_file(path, remaining) do
    if File.exists?(path) do
      true
    else
      Process.sleep(20)
      wait_for_file(path, remaining - 20)
    end
  end

  test "a missing git executable is a clean error", %{dir: dir} do
    assert {:error, message} = Git.run(dir, ["status"], executable: "definitely-not-git-xyz")
    assert message =~ "command not found"
  end
end
