defmodule SwarmCode.Daemon.Schema.GenerateManifestTest do
  use ExUnit.Case, async: false

  @pinned_commit "dbb8804b3d7293178e571fa7afdf6bd47d06a51c"

  test "rejects an unreviewed commit before opening upstream or creating output" do
    root = temporary_directory!()
    upstream = Path.join(root, "missing-upstream")
    output = Path.join(root, "manifest.json")
    fixtures = Path.join(root, "fixtures")

    {message, status} = run_generator(upstream, output, fixtures, String.duplicate("a", 40))
    assert status != 0
    assert message =~ "unsupported upstream commit"
    refute File.exists?(upstream)
    refute File.exists?(output)
    refute File.exists?(fixtures)
  end

  test "rejects direct, ancestor-normalized, and symlink-aliased upstream outputs without mutation" do
    root = temporary_directory!()
    upstream = Path.join(root, "upstream")
    alias_path = Path.join(root, "upstream-alias")
    outside = Path.join(root, "outside")
    File.mkdir!(upstream)
    File.mkdir!(outside)
    git!(upstream, ["init", "--quiet"])
    File.ln_s!(upstream, alias_path)
    before = porcelain(upstream)

    cases = [
      {Path.join(upstream, "manifest.json"), Path.join(outside, "fixtures")},
      {Path.join(outside, "manifest.json"), Path.join(alias_path, "fixtures")},
      {Path.join([outside, "..", "upstream", "manifest.json"]), Path.join(outside, "fixtures")}
    ]

    for {output, fixtures} <- cases do
      {message, status} = run_generator(upstream, output, fixtures)

      assert status != 0
      assert message =~ "generator outputs must resolve outside upstream worktree"
      refute File.exists?(output)
      refute File.exists?(fixtures)
      assert porcelain(upstream) == before
    end
  end

  test "rejects case and Unicode normalization aliases by filesystem identity before .git writes" do
    root = temporary_directory!()
    upstream = Path.join(root, "audit-caf\u00E9")
    filesystem_alias = Path.join(root, "AUDIT-CAFE\u0301")
    File.mkdir!(upstream)
    git!(upstream, ["init", "--quiet"])

    if File.dir?(filesystem_alias) do
      upstream_identity = filesystem_identity(upstream)
      assert filesystem_identity(filesystem_alias) == upstream_identity

      assert filesystem_identity(Path.join(filesystem_alias, ".GIT")) ==
               filesystem_identity(Path.join(upstream, ".git"))

      output = Path.join(filesystem_alias, ".GIT/alias-manifest.json")
      fixtures = Path.join(filesystem_alias, ".GIT/alias-fixtures")
      before_porcelain = porcelain(upstream)
      before_git_entries = File.ls!(Path.join(upstream, ".git")) |> Enum.sort()

      {message, status} = run_generator(upstream, output, fixtures)

      assert status != 0
      assert message =~ "generator outputs must resolve outside upstream worktree"
      refute File.exists?(output)
      refute File.exists?(fixtures)
      assert porcelain(upstream) == before_porcelain
      assert File.ls!(Path.join(upstream, ".git")) |> Enum.sort() == before_git_entries
    else
      refute :os.type() == {:unix, :darwin}
    end
  end

  test "rejects canceled nonexisting prefixes before mkdir can touch upstream .git" do
    root = temporary_directory!()
    upstream = Path.join(root, "upstream")
    outside = Path.join(root, "outside")
    output = Path.join(outside, "manifest.json")

    fixtures =
      Path.join(upstream, ".git/review-nonexistent/../../../outside/fixtures")

    canceled_prefix = Path.join(upstream, ".git/review-nonexistent")
    File.mkdir!(upstream)
    git!(upstream, ["init", "--quiet"])
    before_porcelain = porcelain(upstream)
    before_git_entries = File.ls!(Path.join(upstream, ".git")) |> Enum.sort()

    assert Path.expand(fixtures) == Path.join(outside, "fixtures")

    File.mkdir_p!(fixtures)
    assert File.dir?(canceled_prefix)
    assert porcelain(upstream) == before_porcelain
    refute File.ls!(Path.join(upstream, ".git")) |> Enum.sort() == before_git_entries

    File.rmdir!(canceled_prefix)
    File.rm_rf!(outside)
    assert File.ls!(Path.join(upstream, ".git")) |> Enum.sort() == before_git_entries

    {message, status} = run_generator(upstream, output, fixtures)

    assert status != 0
    assert message =~ "generator output paths must not contain dot or canceled components"
    refute File.exists?(output)
    refute File.exists?(fixtures)
    refute File.exists?(canceled_prefix)
    assert porcelain(upstream) == before_porcelain
    assert File.ls!(Path.join(upstream, ".git")) |> Enum.sort() == before_git_entries
  end

  defp run_generator(upstream, output, fixtures, commit \\ @pinned_commit) do
    System.cmd(
      find_mix!(),
      [
        "run",
        "--no-start",
        generator_path(),
        "--",
        "--upstream",
        upstream,
        "--commit",
        commit,
        "--output",
        output,
        "--fixtures-dir",
        fixtures
      ],
      cd: File.cwd!(),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp find_mix!, do: System.find_executable("mix") || raise("mix executable not found")

  defp generator_path do
    Path.join(File.cwd!(), "priv/schema/generate_manifest.exs")
  end

  defp porcelain(upstream) do
    {output, 0} = git!(upstream, ["status", "--porcelain", "--untracked-files=all"])
    output
  end

  defp git!(upstream, args) do
    System.cmd("git", ["-C", upstream | args], stderr_to_stdout: true)
  end

  defp filesystem_identity(path) do
    stat = File.stat!(path)
    {stat.major_device, stat.minor_device, stat.inode}
  end

  defp temporary_directory! do
    directory =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-manifest-generator-test-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(directory)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end
end
