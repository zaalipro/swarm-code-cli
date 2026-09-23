defmodule Mix.Tasks.SwarmCode.Provenance.Sync do
  @shortdoc "Re-derives the desktop-lineage domain from a pinned desktop commit"

  @moduledoc """
  Syncs the extracted desktop files (`SwarmCode.Domain.*`, migrations, built-in
  agents and workflows, pure upstream tests) to a desktop commit, or checks that
  they still derive from the pinned one.

      mix swarm_code.provenance.sync --ref <sha> [--upstream <path>] [--resolved <destination> ...]
      mix swarm_code.provenance.sync --check [--upstream <path>]

  The upstream checkout defaults to `$SWARM_CODE_UPSTREAM`, else
  `~/dev/swarm-code`. It is only read through `git rev-parse`, `ls-tree` and
  `cat-file`; a sync also refuses an upstream worktree with uncommitted changes.

  The rules live in `provenance/sync-rules.json` (the pin, the ordered rewrite
  table, the path mappings and exclusions); the ledger is
  `provenance/extracted-files.json`; CLI-local changes to synced files are
  recorded as `provenance/patches/<destination>.diff`.

  ## Syncing

  Untouched files take the new upstream derivation. A file with a CLI patch is
  merged three ways (base = the old derivation, ours = the CLI file, theirs =
  the new derivation). On a conflict nothing is written except
  `<destination>.sync-conflict`, the merge with diff3 markers. Resolve it by
  copying it over the destination, fixing the markers, deleting the
  `.sync-conflict` file and running the same command again with
  `--resolved <destination>`.

  After editing a synced file on purpose, record the edit as a patch by
  syncing to the pinned commit again: `mix swarm_code.provenance.sync --ref
  <pinned sha>`.

  ## Checking

  `--check` re-derives every synced file at the pin and fails on a difference,
  a missing or extra file, or a stale patch. It is part of `mix precommit`.
  """

  use Mix.Task

  alias SwarmCode.Governance.ProvenanceSync

  @switches [check: :boolean, ref: :string, upstream: :string, resolved: :keep]

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("Unexpected arguments. " <> usage())
    end

    root = File.cwd!()
    upstream = upstream(opts[:upstream])
    formatter = &format(root, &1, &2)

    cond do
      opts[:check] && (opts[:ref] || Keyword.has_key?(opts, :resolved)) ->
        Mix.raise("--check takes no --ref or --resolved. " <> usage())

      opts[:check] ->
        check(root, upstream, formatter)

      is_binary(opts[:ref]) ->
        resolved = Keyword.get_values(opts, :resolved)
        sync(root, upstream, opts[:ref], resolved, formatter)

      true ->
        Mix.raise(usage())
    end
  end

  defp check(root, upstream, formatter) do
    case ProvenanceSync.check(root, upstream: upstream, formatter: formatter) do
      :ok ->
        Mix.shell().info("provenance sync: every synced file derives from the pinned commit")

      {:error, errors} ->
        Mix.raise(
          "provenance sync check failed (upstream #{upstream}):\n  " <>
            Enum.join(errors, "\n  ") <>
            "\nRecord deliberate edits with mix swarm_code.provenance.sync --ref <pinned sha>."
        )
    end
  end

  defp sync(root, upstream, ref, resolved, formatter) do
    case ProvenanceSync.sync(root,
           upstream: upstream,
           ref: ref,
           resolved: resolved,
           formatter: formatter
         ) do
      {:ok, report} ->
        shell = Mix.shell()
        shell.info("provenance sync to #{report.ref}")
        list(shell, "created", report.created)
        list(shell, "updated from upstream", report.upstream)
        list(shell, "merged with the CLI patch", report.merged)
        list(shell, "taken as resolved", report.resolved)
        list(shell, "removed (gone upstream)", report.removed)
        list(shell, "carrying a CLI patch", report.patched)
        shell.info("  unchanged: #{report.unchanged}")

      {:error, %{conflicts: conflicts, removed_but_patched: removed}} ->
        Mix.raise(
          "provenance sync stopped; nothing but the conflict files was written.\n" <>
            Enum.map_join(conflicts, "", &"  conflict: #{&1} (see #{&1}.sync-conflict)\n") <>
            Enum.map_join(removed, "", &"  deleted upstream but patched locally: #{&1}\n") <>
            "Resolve each conflict and rerun with --resolved <destination>."
        )

      {:error, message} ->
        Mix.raise("provenance sync failed: " <> message)
    end
  end

  defp list(_shell, _label, []), do: :ok

  defp list(shell, label, destinations) do
    shell.info("  #{label} (#{length(destinations)}):")
    Enum.each(destinations, &shell.info("    " <> &1))
  end

  defp format(root, destination, text) do
    {formatter, _opts} = Mix.Tasks.Format.formatter_for_file(Path.join(root, destination))
    formatter.(text)
  end

  defp upstream(nil) do
    case System.get_env("SWARM_CODE_UPSTREAM") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _unset -> Path.expand("~/dev/swarm-code")
    end
  end

  defp upstream(path), do: Path.expand(path)

  defp usage do
    "Usage: mix swarm_code.provenance.sync --ref <sha> [--upstream <path>] [--resolved <destination> ...] " <>
      "| mix swarm_code.provenance.sync --check [--upstream <path>]"
  end
end
