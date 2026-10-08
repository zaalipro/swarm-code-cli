defmodule Mix.Tasks.SwarmCode.Provenance.DriftTest do
  @moduledoc """
  cli020 A7 (parity-3, owner Q2): the drift gate compares the CLI's pinned
  desktop commit with a desktop ref, read-only. New migrations fail it (a
  desktop release with them would make this CLI refuse the database); code
  drift alone warns, and fails only with `--strict`; no desktop checkout is
  skipped, and fails only with `--strict`.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.SwarmCode.Provenance.Drift

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous) end)

    # cli020 fix S5: ExUnit keeps its `tmp_dir` after the run; nothing of this
    # test may remain in `apps/swarm_code_core/tmp/`. The parents go too when
    # they are empty (`rmdir` leaves a sibling test's directory alone).
    on_exit(fn ->
      File.rm_rf!(tmp)
      module_dir = Path.dirname(tmp)
      _ = File.rmdir(module_dir)
      _ = File.rmdir(Path.dirname(module_dir))
    end)

    upstream = Path.join(tmp, "desktop")
    File.mkdir_p!(Path.join(upstream, "priv/repo/migrations"))
    File.mkdir_p!(Path.join(upstream, "lib/swarm_code"))
    git!(upstream, ["init", "--quiet", "--initial-branch=main"])
    write!(upstream, "priv/repo/migrations/20260820000001_create.exs", "first\n")
    write!(upstream, "lib/swarm_code/engine.ex", "v1\n")
    pin = commit!(upstream, "pin")

    root = Path.join(tmp, "cli")
    File.mkdir_p!(Path.join(root, "provenance"))

    File.write!(
      Path.join(root, "provenance/sync-rules.json"),
      Jason.encode!(%{"version" => 1, "upstream_commit" => pin})
    )

    %{upstream: upstream, root: root, pin: pin}
  end

  test "a new migration at the ref fails, names the file and the re-pin command", c do
    write!(c.upstream, "priv/repo/migrations/20261101000001_more_columns.exs", "second\n")
    write!(c.upstream, "lib/swarm_code/engine.ex", "v2\n")
    head = commit!(c.upstream, "migration")

    {status, out} = drift(c, [])
    assert status == 1

    assert out ==
             [
               "ncode CLI drift: desktop main (#{String.slice(head, 0, 7)}) has 1 migration(s) this CLI does not know:",
               "  20261101000001_more_columns.exs",
               "A desktop release with these would make this CLI refuse the database. " <>
                 "Re-pin: mix swarm_code.provenance.sync --ref #{head}."
             ]

    assert {1, _out} = drift(c, ["--strict"])
    assert pristine?(c.upstream)
  end

  test "code drift alone warns, and fails only with --strict", c do
    write!(c.upstream, "lib/swarm_code/engine.ex", "v2\n")
    commit!(c.upstream, "engine change")
    write!(c.upstream, "README.md", "outside the domain\n")
    commit!(c.upstream, "readme")

    expected = [
      "ncode CLI drift: 1 desktop commits since the pin touch the domain (no new migrations)."
    ]

    assert drift(c, []) == {0, expected}
    assert drift(c, ["--strict"]) == {1, expected}
    assert pristine?(c.upstream)
  end

  test "no drift at all passes, strict or not", c do
    write!(c.upstream, "README.md", "outside the domain\n")
    commit!(c.upstream, "readme")

    assert {0, [line]} = drift(c, ["--strict"])
    assert line =~ "ncode CLI drift: none"
    assert {0, [pinned]} = drift(c, ["--ref", c.pin])
    assert pinned =~ "ncode CLI drift: none"
    assert pristine?(c.upstream)
  end

  test "no desktop checkout is skipped, and fails only with --strict", c do
    missing = Path.join(Path.dirname(c.upstream), "absent")
    expected = ["ncode CLI drift: no desktop checkout at #{missing}; skipped."]

    assert drift(%{c | upstream: missing}, []) == {0, expected}
    assert drift(%{c | upstream: missing}, ["--strict"]) == {1, expected}
  end

  test "an unknown ref or argument is an error, not a pass", c do
    assert {1, [line]} = drift(c, ["--ref", "no-such-branch"])
    assert line =~ "cannot resolve no-such-branch"
    assert_raise Mix.Error, fn -> in_root(c.root, fn -> Drift.run(["--bogus"]) end) end
  end

  defp drift(c, args) do
    status =
      in_root(c.root, fn ->
        try do
          Drift.run(["--upstream", c.upstream | args])
          0
        catch
          :exit, {:shutdown, code} -> code
        end
      end)

    {status, lines([])}
  end

  defp lines(acc) do
    receive do
      {:mix_shell, kind, [line]} when kind in [:info, :error] -> lines([line | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.flat_map(&String.split(&1, "\n"))
    end
  end

  defp in_root(root, fun) do
    previous = File.cwd!()
    File.cd!(root)

    try do
      fun.()
    after
      File.cd!(previous)
    end
  end

  defp pristine?(upstream), do: git!(upstream, ["status", "--porcelain"]) == ""

  defp write!(repo, rel, text) do
    path = Path.join(repo, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
  end

  defp commit!(repo, message) do
    git!(repo, ["add", "-A"])

    git!(repo, [
      "-c",
      "user.name=drift-test",
      "-c",
      "user.email=drift-test@example.com",
      "-c",
      "commit.gpgsign=false",
      "commit",
      "--quiet",
      "-m",
      message
    ])

    repo |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", ["-C", repo | args], stderr_to_stdout: true)
    out
  end
end
