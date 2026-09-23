defmodule SwarmCode.Domain.Tools.GitToolsTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.{Git, Tools}

  setup do
    dir = Path.join([System.tmp_dir!(), "swarm_code_gt", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} = Git.run(dir, ["init", "-q", "-b", "main"])
    {:ok, _} = Git.run(dir, ["config", "user.email", "t@example.com"])
    {:ok, _} = Git.run(dir, ["config", "user.name", "T"])
    File.write!(Path.join(dir, "a.txt"), "one\n")
    {:ok, _} = Git.commit(dir, "init")

    %{dir: dir, ctx: %{project_root: dir}, p: fn _, _ -> :ok end}
  end

  test "git_status", %{dir: dir, ctx: ctx, p: p} do
    assert {:ok, out} = Tools.run("git_status", %{}, ctx, p)
    assert out =~ "On branch main"
    assert out =~ "working tree clean"

    File.write!(Path.join(dir, "a.txt"), "two\n")
    assert {:ok, out} = Tools.run("git_status", %{}, ctx, p)
    assert out =~ "M a.txt"
  end

  test "git_diff", %{dir: dir, ctx: ctx, p: p} do
    assert {:ok, "no changes"} = Tools.run("git_diff", %{}, ctx, p)
    File.write!(Path.join(dir, "a.txt"), "one\ntwo\n")
    assert {:ok, out} = Tools.run("git_diff", %{}, ctx, p)
    assert out =~ "+two"
    assert {:ok, out} = Tools.run("git_diff", %{"path" => "a.txt"}, ctx, p)
    assert out =~ "a.txt"
  end

  test "git_log and git_commit", %{dir: dir, ctx: ctx, p: p} do
    File.write!(Path.join(dir, "b.txt"), "b\n")

    assert {:ok, _} = Tools.run("git_commit", %{"message" => "add b"}, ctx, p)
    assert {:ok, log} = Tools.run("git_log", %{"n" => 5}, ctx, p)
    assert log =~ "add b"
    assert {:ok, "On branch main\nworking tree clean"} = Tools.run("git_status", %{}, ctx, p)
  end

  test "the read-only git tools are offered in plan mode" do
    names = Enum.map(Tools.for_agent("assistant", 0, 2, "plan"), & &1.name)
    assert "git_status" in names
    assert "git_diff" in names
    assert "git_log" in names
    refute "git_commit" in names
  end

  test "outside a git repo the tools say so", %{p: p} do
    dir = Path.join([System.tmp_dir!(), "swarm_code_nogit", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    assert {:error, msg} = Tools.run("git_status", %{}, %{project_root: dir}, p)
    assert msg =~ "not a git repository"
  end
end
