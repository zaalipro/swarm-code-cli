defmodule SwarmCode.Domain.Tools.CliProtectedPathsTest do
  @moduledoc """
  cli020 A9 (parity-6): the cases of the desktop's
  `test/swarm_code/tools/polish74_o2_protected_paths_test.exs` (a64d6ff6, spec
  74 BUGS-1) against the synced `SwarmCode.Domain.Tools`. The desktop file is
  not mapped into the sync: it uses `SwarmCode.DataCase`, which the CLI does
  not have. Its fourth case (an auto-mode turn on `LLM.Fake`) is the same
  refusal seen through a model turn; the write tools' refusal is pinned here,
  the live runtime's copy in `tools/path_test.exs`.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  import SwarmCode.Domain.Fixtures

  alias SwarmCode.Domain.Tools

  @protected [
    ".swarm_code/config.json",
    ".SWARM_CODE/CONFIG.JSON",
    ".GIT/config",
    ".GIT/hooks/pre-commit",
    ".Claude/settings.json",
    ".swarm_code/memory.md"
  ]

  setup do
    dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(dir) end)

    # The real files, so a case-folded write on APFS would land on them.
    File.mkdir_p!(Path.join(dir, ".git/hooks"))
    File.mkdir_p!(Path.join(dir, ".claude"))
    File.mkdir_p!(Path.join(dir, ".swarm_code"))
    File.write!(Path.join(dir, ".git/config"), "[core]\n")
    File.write!(Path.join(dir, ".git/hooks/pre-commit"), "#!/bin/sh\n")
    File.write!(Path.join(dir, ".claude/settings.json"), "{}\n")
    File.write!(Path.join(dir, ".swarm_code/MEMORY.md"), "# memory\n")
    File.write!(Path.join(dir, ".swarm_code/config.json"), "{}\n")
    File.write!(Path.join(dir, "plain.txt"), "plain\n")

    {:ok, dir: dir, ctx: %{project_root: dir}, p: fn _, _ -> :ok end}
  end

  defp snapshot(dir) do
    for rel <- [
          ".git/config",
          ".git/hooks/pre-commit",
          ".claude/settings.json",
          ".swarm_code/MEMORY.md",
          ".swarm_code/config.json",
          "plain.txt"
        ],
        into: %{},
        do: {rel, File.read!(Path.join(dir, rel))}
  end

  defp protected_error?(message),
    do:
      message =~ "cannot be written by a tool" or message =~ "memory tool's own file" or
        message =~ "edited by the user"

  test "every write tool refuses every protected path, case-folded or not", %{
    dir: dir,
    ctx: ctx,
    p: p
  } do
    before = snapshot(dir)

    for path <- @protected do
      calls = [
        {"write_file", %{"path" => path, "content" => "evil"}},
        {"edit_file", %{"path" => path, "old_string" => "{", "new_string" => "evil"}},
        {"edit_files",
         %{"files" => [%{"path" => path, "old_string" => "{", "new_string" => "evil"}]}},
        {"move_file", %{"from" => path, "to" => "moved.txt"}},
        {"move_file", %{"from" => "plain.txt", "to" => path, "overwrite" => true}},
        {"delete_file", %{"path" => path}}
      ]

      for {tool, args} <- calls do
        assert {:error, message} = Tools.run(tool, args, ctx, p),
               "#{tool} #{inspect(args)} was not refused"

        assert protected_error?(message), "#{tool} #{path}: #{message}"
      end
    end

    assert snapshot(dir) == before
    refute File.exists?(Path.join(dir, "moved.txt"))
  end

  test "config.json gets its own message, not the memory one" do
    assert {:error, message} = Tools.Path.resolve_write(tmp_dir(), ".swarm_code/config.json")
    assert message =~ "hooks and config"
    refute message =~ "memory tool"

    assert {:error, message} = Tools.Path.resolve_write(tmp_dir(), ".swarm_code/Memory.md")
    assert message =~ "memory tool"
  end

  test "the rest of .swarm_code stays writable (specs, commands)", %{dir: dir, ctx: ctx, p: p} do
    for path <- [".swarm_code/specs/a.md", ".swarm_code/commands/x.md"] do
      assert {:ok, _} = Tools.run("write_file", %{"path" => path, "content" => "ok"}, ctx, p)
      assert File.read!(Path.join(dir, path)) == "ok"
    end
  end
end
