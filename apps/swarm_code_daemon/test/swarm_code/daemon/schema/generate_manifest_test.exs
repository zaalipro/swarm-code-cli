defmodule SwarmCode.Daemon.Schema.GenerateManifestTest do
  use ExUnit.Case, async: false

  @pinned_commit "dbb8804b3d7293178e571fa7afdf6bd47d06a51c"

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

  defp run_generator(upstream, output, fixtures) do
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
        @pinned_commit,
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
