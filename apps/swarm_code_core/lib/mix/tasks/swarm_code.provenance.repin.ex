defmodule Mix.Tasks.SwarmCode.Provenance.Repin do
  @shortdoc "Re-pins the sha256 of provenance-tracked files after deliberate edits"

  @moduledoc """
  Recomputes the `sha256` of each given destination file and rewrites only that
  field in its `provenance/extracted-files.json` entry.

      mix swarm_code.provenance.repin <path> [<path> ...]

  Paths are relative to the umbrella root (for example
  `apps/swarm_code_core/lib/swarm_code/commands.ex`). Every path must already
  have a manifest entry; a path with no entry exits non-zero and the manifest
  is left untouched. The other five keys (`classification`, `destination`,
  `upstream_commit`, `upstream_path`, `upstream_sha256`) and every other entry
  are preserved, and entry order is unchanged.
  """

  use Mix.Task

  alias SwarmCode.Governance.Provenance

  @impl Mix.Task
  def run([]) do
    Mix.raise("Expected at least one path: mix swarm_code.provenance.repin <path> ...")
  end

  def run(paths) when is_list(paths) do
    root = File.cwd!()
    manifest_path = Path.join(root, "provenance/extracted-files.json")
    manifest = read_manifest!(manifest_path)
    entries = manifest_entries!(manifest)

    repinned =
      Enum.map(paths, fn path ->
        destination = normalize!(path, root)
        entry = find_entry!(entries, destination)
        digest = digest_file!(root, destination)
        {destination, entry["sha256"], digest}
      end)

    before = read_bytes!(manifest_path)

    after_bytes =
      Enum.reduce(repinned, before, fn {destination, _before, digest}, acc ->
        replace_entry_sha256!(acc, destination, digest)
      end)

    case File.write(manifest_path, after_bytes) do
      :ok -> :ok
      {:error, _reason} -> Mix.raise("cannot write #{manifest_path}")
    end

    for {destination, before_digest, digest} <- repinned do
      Mix.shell().info("#{destination}: #{before_digest} -> #{digest}")
    end

    :ok
  end

  defp read_manifest!(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, %{} = manifest} <- Jason.decode(bytes) do
      manifest
    else
      _other -> Mix.raise("cannot read valid JSON from #{path}")
    end
  end

  defp manifest_entries!(%{"entries" => entries}) when is_list(entries), do: entries
  defp manifest_entries!(_manifest), do: Mix.raise("extracted-files ledger has an invalid shape")

  defp find_entry!(entries, destination) do
    case Enum.find(entries, &(&1["destination"] == destination)) do
      nil -> Mix.raise("no provenance entry for #{destination}")
      entry -> entry
    end
  end

  defp digest_file!(root, destination) do
    case Provenance.digest_file(Path.join(root, destination)) do
      {:ok, digest} ->
        digest

      {:error, _reason} ->
        Mix.raise("cannot read destination file for #{destination}")
    end
  end

  defp normalize!(path, root) do
    expanded = Path.expand(path, root)
    expanded_root = Path.expand(root)

    if expanded != expanded_root and String.starts_with?(expanded, expanded_root <> "/") do
      Path.relative_to(expanded, expanded_root)
    else
      Mix.raise("no provenance entry for #{path}")
    end
  end

  defp read_bytes!(path) do
    case File.read(path) do
      {:ok, bytes} -> bytes
      {:error, _reason} -> Mix.raise("cannot read valid JSON from #{path}")
    end
  end

  defp replace_entry_sha256!(bytes, destination, digest) do
    escaped = Regex.escape(destination)

    pattern =
      ~r/"destination": "#{escaped}",\n      "sha256": "[0-9a-f]{64}"/

    replacement = ~s("destination": "#{destination}",\n      "sha256": "#{digest}")

    parts = Regex.split(pattern, bytes, include_captures: true, parts: 3)

    case parts do
      [before, _match, remainder] -> before <> replacement <> remainder
      _other -> Mix.raise("no provenance entry for #{destination}")
    end
  end
end
