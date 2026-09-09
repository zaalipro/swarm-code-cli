defmodule SwarmCode.Commands.FilesTest do
  use ExUnit.Case, async: true
  alias SwarmCode.Commands.Files

  setup do
    root = Path.join(System.tmp_dir!(), "command-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "project/.swarm_code/commands"))
    File.mkdir_p!(Path.join(root, "global/commands"))
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, project: Path.join(root, "project"), global: Path.join(root, "global")}
  end

  test "loads front matter and project commands override global by normalized name", c do
    File.write!(Path.join(c.global, "commands/ship.md"), "global prompt")

    File.write!(
      Path.join(c.project, ".swarm_code/commands/Ship.md"),
      "---\ndescription: Ship safely\nmode: plan\nswarm: true\n---\nReview $ARGUMENTS\n"
    )

    assert {:ok, [command]} = Files.list(project_root: c.project, global_root: c.global)
    assert command.name == "ship"
    assert command.scope == :project
    assert command.description == "Ship safely"
    assert command.mode == "plan"
    assert command.swarm

    assert {:ok, %{prompt: "Review tests", action: :start_swarm}} =
             SwarmCode.Commands.parse("/ship tests", custom: [command])
  end

  test "refuses escaping symlink, oversized file, invalid UTF8 and bad metadata", c do
    dir = Path.join(c.project, ".swarm_code/commands")
    File.write!(Path.join(c.root, "outside.md"), "secret")
    File.ln_s!(Path.join(c.root, "outside.md"), Path.join(dir, "escape.md"))
    File.write!(Path.join(dir, "huge.md"), String.duplicate("x", 262_145))
    File.write!(Path.join(dir, "bad.md"), <<255>>)
    File.write!(Path.join(dir, "mode.md"), "---\nmode: full_access\n---\nhello")
    assert {:error, errors} = Files.list(project_root: c.project, global_root: c.global)
    assert length(errors) == 4
    refute inspect(errors) =~ "secret"
  end

  test "missing directories are empty and create is exclusive and confined", c do
    assert {:ok, []} = Files.list(project_root: c.project, global_root: c.global)
    assert {:ok, path} = Files.create(c.project, :project, "review")
    assert File.read!(path) =~ "$ARGUMENTS"
    assert {:error, :exists} = Files.create(c.project, :project, "review")
    assert {:error, :invalid_name} = Files.create(c.project, :project, "../escape")
  end

  test "invalid options and paths return typed errors without raising", c do
    for opts <- [
          nil,
          %{},
          [1],
          [{:project_root, c.project} | :bad],
          [project_root: <<255>>, global_root: c.global],
          [project_root: c.project, global_root: <<255>>],
          [project_root: "a\0b", global_root: c.global],
          [project_root: c.project, global_root: c.global, unknown: true]
        ] do
      assert {:error, [:invalid_options]} = Files.list(opts)
    end

    assert {:error, :invalid_options} = Files.create(<<255>>, :project, "ok")
    assert {:error, :invalid_name} = Files.create(c.project, :project, <<255>>)
  end

  test "plain prompts default to filename description and no mode override", c do
    File.write!(Path.join(c.project, ".swarm_code/commands/plain.md"), "  A prompt  \n")
    assert {:ok, [command]} = Files.list(project_root: c.project, global_root: c.global)
    assert command.description == "plain"
    assert command.mode == nil
    assert command.body == "A prompt"
    refute command.swarm
  end

  test "front matter supports quoted values CRLF truthy values and absent mode", c do
    File.write!(
      Path.join(c.project, ".swarm_code/commands/quoted.md"),
      "---\r\nDescription: \"Check: carefully\"\r\nmode: 'plan'\r\nswarm: 'yes'\r\n---\r\n$ARGUMENTS\r\n"
    )

    assert {:ok, [command]} = Files.list(project_root: c.project, global_root: c.global)
    assert command.description == "Check: carefully"
    assert command.mode == "plan"
    assert command.swarm

    assert {:ok, %{mode: :plan, prompt: "a"}} =
             SwarmCode.Commands.parse("/quoted a", custom: [command])
  end

  test "directory symlink escapes are refused before reading or creating", c do
    outside = Path.join(c.root, "outside")
    File.mkdir_p!(outside)
    File.rm_rf!(Path.join(c.project, ".swarm_code"))
    File.ln_s!(outside, Path.join(c.project, ".swarm_code"))
    assert {:error, _} = Files.list(project_root: c.project, global_root: c.global)
    assert {:error, :outside_root} = Files.create(c.project, :project, "escape")
    refute File.exists?(Path.join(outside, "commands"))
  end

  test "symlinks in final commands directory and target are not followed", c do
    dir = Path.join(c.project, ".swarm_code/commands")
    outside = Path.join(c.root, "outside")
    File.mkdir_p!(outside)
    File.rm_rf!(dir)
    File.ln_s!(outside, dir)
    assert {:error, :outside_root} = Files.create(c.project, :project, "escape")
    assert File.ls!(outside) == []
    File.rm!(dir)
    File.mkdir!(dir)
    target = Path.join(outside, "target")
    File.write!(target, "unchanged")
    File.ln_s!(target, Path.join(dir, "escape.md"))
    assert {:error, :outside_root} = Files.create(c.project, :project, "escape")
    assert File.read!(target) == "unchanged"
  end

  test "aggregate input bytes across both roots are capped at 8 MiB", c do
    for n <- 1..17 do
      File.write!(
        Path.join(c.project, ".swarm_code/commands/p#{n}.md"),
        String.duplicate("p", 262_144)
      )

      File.write!(Path.join(c.global, "commands/g#{n}.md"), String.duplicate("g", 262_144))
    end

    assert {:error, errors} = Files.list(project_root: c.project, global_root: c.global)
    assert :aggregate_limit in errors
  end

  test "directory members are counted even when not markdown and across both roots", c do
    for n <- 1..513 do
      File.write!(Path.join(c.project, ".swarm_code/commands/p#{n}.txt"), "")
      File.write!(Path.join(c.global, "commands/g#{n}.txt"), "")
    end

    assert {:error, errors} = Files.list(project_root: c.project, global_root: c.global)
    assert :entry_limit in errors
  end

  test "exclusive publication is private complete and leaves no temporary files", c do
    results =
      1..8
      |> Task.async_stream(fn _ -> Files.create(c.project, :project, "same") end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :exists})) == 7
    dir = Path.join(c.project, ".swarm_code/commands")
    assert File.ls!(dir) == ["same.md"]
    assert Bitwise.band(File.stat!(Path.join(dir, "same.md")).mode, 0o777) == 0o600
    assert {:ok, [command]} = Files.list(project_root: c.project, global_root: c.global)
    assert command.mode == nil
    assert String.contains?(command.body, "$ARGUMENTS")
  end
end
