defmodule Mix.Tasks.SwarmCode.Provenance.RepinTest do
  @moduledoc """
  The repin task recomputes a tracked file's digest and rewrites only the
  `sha256` field of its manifest entry.
  """
  use ExUnit.Case, async: false

  @destination "lib/tracked.ex"
  @other "lib/other.ex"

  setup do
    root = Path.join(System.tmp_dir!(), "repin-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "governance"))
    File.mkdir_p!(Path.join(root, "provenance"))
    File.write!(Path.join(root, @destination), "tracked v1\n")
    File.write!(Path.join(root, @other), "other\n")
    write_policy!(root)
    write_manifest!(root, [entry(@destination, "tracked v1\n"), entry(@other, "other\n")])
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "rewrites only the sha256 field of the targeted entry", %{root: root} do
    before = read_manifest!(root)
    File.write!(Path.join(root, @destination), "tracked v2\n")

    in_root(root, fn -> Mix.Tasks.SwarmCode.Provenance.Repin.run([@destination]) end)

    after_manifest = read_manifest!(root)
    assert destinations(after_manifest) == destinations(before)

    {before_target, before_rest} = split(before, @destination)
    {after_target, after_rest} = split(after_manifest, @destination)

    assert after_rest == before_rest
    assert after_target["sha256"] == digest("tracked v2\n")
    assert after_target["sha256"] != before_target["sha256"]
    assert Map.delete(after_target, "sha256") == Map.delete(before_target, "sha256")
  end

  test "re-pinned entry still verifies against the manifest shape", %{root: root} do
    File.write!(Path.join(root, @destination), "tracked v2\n")

    in_root(root, fn -> Mix.Tasks.SwarmCode.Provenance.Repin.run([@destination]) end)

    assert :ok = SwarmCode.Governance.Provenance.verify(root)
  end

  test "errors on a path with no manifest entry and leaves the manifest untouched", %{
    root: root
  } do
    before = File.read!(manifest_path(root))
    File.write!(Path.join(root, "lib/untracked.ex"), "untracked\n")

    assert_raise Mix.Error, ~r/no provenance entry for lib\/untracked\.ex/, fn ->
      in_root(root, fn -> Mix.Tasks.SwarmCode.Provenance.Repin.run(["lib/untracked.ex"]) end)
    end

    assert File.read!(manifest_path(root)) == before
  end

  test "requires at least one path" do
    assert_raise Mix.Error, ~r/Expected at least one path/, fn ->
      Mix.Tasks.SwarmCode.Provenance.Repin.run([])
    end
  end

  defp entry(destination, contents) do
    %{
      "classification" => "source",
      "destination" => destination,
      "sha256" => digest(contents),
      "upstream_commit" => "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
      "upstream_path" => "lib/swarm_code/example.ex",
      "upstream_sha256" => digest("original desktop source")
    }
  end

  defp digest(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp manifest_path(root), do: Path.join(root, "provenance/extracted-files.json")

  defp write_manifest!(root, entries) do
    File.write!(
      manifest_path(root),
      "{\n  \"version\": 2,\n  \"entries\": [\n" <>
        Enum.map_join(entries, ",\n", &format_entry/1) <> "\n  ]\n}\n"
    )
  end

  defp format_entry(entry) do
    "    {\n" <>
      "      \"classification\": \"#{entry["classification"]}\",\n" <>
      "      \"destination\": \"#{entry["destination"]}\",\n" <>
      "      \"sha256\": \"#{entry["sha256"]}\",\n" <>
      "      \"upstream_commit\": \"#{entry["upstream_commit"]}\",\n" <>
      "      \"upstream_path\": \"#{entry["upstream_path"]}\",\n" <>
      "      \"upstream_sha256\": \"#{entry["upstream_sha256"]}\"\n" <>
      "    }"
  end

  defp write_policy!(root) do
    File.write!(
      Path.join(root, "governance/source-policy.json"),
      Jason.encode!(%{
        "version" => 1,
        "audit_baseline" => "dbb8804b3d7293178e571fa7afdf6bd47d06a51c",
        "authorization_status" => "clean_room"
      })
    )
  end

  defp read_manifest!(root), do: root |> manifest_path() |> File.read!() |> Jason.decode!()

  defp destinations(manifest), do: Enum.map(manifest["entries"], & &1["destination"])

  defp split(manifest, destination) do
    {match, rest} = Enum.split_with(manifest["entries"], &(&1["destination"] == destination))
    {hd(match), rest}
  end

  defp in_root(root, fun) do
    File.cd!(root, fun)
  end
end
