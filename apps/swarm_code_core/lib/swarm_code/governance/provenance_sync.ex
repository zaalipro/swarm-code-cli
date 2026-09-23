defmodule SwarmCode.Governance.ProvenanceSync do
  @moduledoc """
  Keeps the desktop-lineage files of the CLI (the `SwarmCode.Domain.*` engine,
  its migrations, built-in agents and workflows, and a few pure upstream tests)
  derived from one pinned desktop commit.

  Every synced file is `derive(upstream file at the pin)` — the ordered rewrite
  table of `provenance/sync-rules.json`, then `mix format` for Elixir sources —
  plus, for the few files the CLI patches, a recorded unified diff under
  `provenance/patches/<destination>.diff`. Nothing else may differ:

    * `sync/2` moves the pin. Files the CLI never touched take the new upstream
      text; patched files are merged three ways (base = the old derivation,
      ours = the CLI file, theirs = the new derivation). A conflict writes
      `<destination>.sync-conflict` and changes nothing else.
    * `check/2` re-derives every synced file at the pin and fails on any
      difference, a missing or extra file, or a patch that no longer describes
      the CLI file. `mix precommit` runs it.

  The upstream checkout is only read: `git rev-parse`, `ls-tree`, `cat-file`.
  Manifest entries outside the mappings (the frozen live-runtime copies, the web
  shims) are left untouched and stay covered by `Provenance.verify/1` alone.
  """

  alias __MODULE__.{Git, Ledger, Rules, UnifiedDiff}

  @patches "provenance/patches"
  @max_errors 40

  @type formatter :: (String.t(), binary() -> binary())

  @doc "Formats Elixir source the way `mix format` does without plugins."
  @spec default_formatter(String.t(), binary()) :: binary()
  def default_formatter(_destination, text),
    do: IO.iodata_to_binary([Code.format_string!(text), ?\n])

  @doc """
  Syncs to `opts[:ref]` of `opts[:upstream]`.

  Options: `:formatter` (`fn destination, text -> formatted end`), `:resolved`
  (destinations whose current content is the hand-resolved merge result),
  `:allow_dirty` (skip the clean-worktree requirement; tests only).
  """
  @spec sync(Path.t(), keyword()) :: {:ok, map()} | {:error, map() | String.t()}
  def sync(root, opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    formatter = Keyword.get(opts, :formatter, &default_formatter/2)
    resolved = MapSet.new(Keyword.get(opts, :resolved, []))

    with {:ok, rules} <- Rules.load(root),
         {:ok, ledger} <- Ledger.load(root),
         {:ok, sha} <- Git.resolve(upstream, Keyword.fetch!(opts, :ref)),
         :ok <- clean(upstream, Keyword.get(opts, :allow_dirty, false)),
         {:ok, targets} <- targets(rules, upstream, sha),
         :ok <- unknown_resolved(resolved, targets),
         {:ok, planned} <- plan(root, rules, ledger, upstream, sha, targets, formatter, resolved),
         {:ok, removed} <- removals(root, rules, ledger, upstream, targets, formatter) do
      conflicts = for {:conflict, target, text} <- planned, do: {target, text}
      removal_conflicts = for {:patched, entry} <- removed, do: entry

      if conflicts == [] and removal_conflicts == [] do
        {:ok, apply_plan(root, rules, ledger, sha, planned, removed)}
      else
        for {target, text} <- conflicts,
            do: File.write!(Path.join(root, target.destination <> ".sync-conflict"), text)

        {:error,
         %{
           ref: sha,
           conflicts: Enum.map(conflicts, fn {target, _text} -> target.destination end),
           removed_but_patched: Enum.map(removal_conflicts, & &1["destination"])
         }}
      end
    end
  end

  @doc "Re-derives every synced file at the pinned commit; `:ok` or the differences."
  @spec check(Path.t(), keyword()) :: :ok | {:error, [String.t()]}
  def check(root, opts) do
    upstream = Keyword.fetch!(opts, :upstream)
    formatter = Keyword.get(opts, :formatter, &default_formatter/2)

    with {:ok, rules} <- Rules.load(root),
         {:ok, ledger} <- Ledger.load(root),
         {:ok, sha} <- Git.resolve(upstream, rules.upstream_commit),
         {:ok, targets} <- targets(rules, upstream, sha) do
      by_destination = Map.new(ledger.entries, &{&1["destination"], &1})
      target_paths = MapSet.new(targets, & &1.upstream_path)

      target_errors =
        targets
        |> async(&check_target(root, rules, upstream, sha, by_destination, formatter, &1))
        |> List.flatten()

      extra_errors =
        for entry <- ledger.entries,
            synced?(rules, entry),
            not MapSet.member?(target_paths, entry["upstream_path"]),
            do:
              "#{entry["destination"]}: #{entry["upstream_path"]} is not upstream at #{Git.short(sha)}"

      stale_patch_errors =
        for patch <- patch_destinations(root),
            not Enum.any?(targets, &(&1.destination == patch)),
            do: "#{patch_path(patch)}: no synced file carries this patch"

      case target_errors ++ extra_errors ++ stale_patch_errors do
        [] -> :ok
        errors -> {:error, bounded(errors)}
      end
    else
      {:error, message} when is_binary(message) -> {:error, [message]}
    end
  end

  @doc "The patch file path (relative to the root) of a synced destination."
  @spec patch_path(String.t()) :: String.t()
  def patch_path(destination), do: Path.join(@patches, destination <> ".diff")

  # -- targets -----------------------------------------------------------------

  defp targets(rules, upstream, sha) do
    rules.mappings
    |> Enum.reduce_while({:ok, []}, fn mapping, {:ok, acc} ->
      case Git.ls_tree(upstream, sha, mapping.upstream) do
        {:ok, paths} ->
          owned = Enum.filter(paths, &(Rules.mapping_for(rules, &1) == mapping))

          case missing_files(mapping, owned) do
            [] ->
              found =
                Enum.map(owned, fn path ->
                  %{
                    upstream_path: path,
                    destination: Rules.destination(mapping, path),
                    mapping: mapping
                  }
                end)

              {:cont, {:ok, acc ++ found}}

            missing ->
              {:halt,
               {:error, "#{Enum.join(missing, ", ")} listed in sync rules but absent upstream"}}
          end

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, targets} ->
        destinations = Enum.map(targets, & &1.destination)

        if length(destinations) == length(Enum.uniq(destinations)),
          do: {:ok, targets},
          else: {:error, "two upstream files map to the same destination"}

      error ->
        error
    end
  end

  defp missing_files(%Rules.Mapping{select: {:files, files}} = mapping, owned),
    do: Enum.reject(Enum.map(files, &(mapping.upstream <> &1)), &(&1 in owned))

  defp missing_files(_mapping, _owned), do: []

  defp synced?(rules, entry) do
    case Rules.mapping_for(rules, entry["upstream_path"]) do
      nil -> false
      mapping -> Rules.destination(mapping, entry["upstream_path"]) == entry["destination"]
    end
  end

  defp clean(_upstream, true), do: :ok

  defp clean(upstream, false) do
    if Git.clean?(upstream),
      do: :ok,
      else: {:error, "the upstream checkout #{upstream} has uncommitted changes"}
  end

  defp unknown_resolved(resolved, targets) do
    known = MapSet.new(targets, & &1.destination)

    case Enum.reject(resolved, &MapSet.member?(known, &1)) do
      [] ->
        :ok

      unknown ->
        {:error, "--resolved names files that are not synced: #{Enum.join(unknown, ", ")}"}
    end
  end

  # -- sync --------------------------------------------------------------------

  defp plan(root, rules, ledger, upstream, sha, targets, formatter, resolved) do
    by_destination = Map.new(ledger.entries, &{&1["destination"], &1})

    targets
    |> async(fn target ->
      plan_target(root, rules, upstream, sha, by_destination, formatter, resolved, target)
    end)
    |> collect()
  end

  defp plan_target(root, rules, upstream, sha, by_destination, formatter, resolved, target) do
    entry = Map.get(by_destination, target.destination)
    path = Path.join(root, target.destination)

    with :ok <- ownership(rules, entry, target, path),
         {:ok, raw} <- Git.show(upstream, sha, target.upstream_path),
         {:ok, theirs} <- derive(rules, target.mapping, target.destination, raw, formatter) do
      target = Map.merge(target, %{raw: raw, theirs: theirs, entry: entry})

      if entry == nil do
        {:ok, {:created, target, theirs}}
      else
        merge_target(root, rules, upstream, sha, formatter, resolved, target, entry)
      end
    end
  end

  defp ownership(_rules, nil, target, path) do
    if File.exists?(path),
      do:
        {:error, "#{target.destination} exists but is not a provenance entry (CLI-local file?)"},
      else: :ok
  end

  defp ownership(rules, entry, target, _path) do
    if synced?(rules, entry) and entry["upstream_path"] == target.upstream_path,
      do: :ok,
      else:
        {:error,
         "#{target.destination} is a frozen provenance entry of #{entry["upstream_path"]}"}
  end

  defp merge_target(root, rules, upstream, sha, formatter, resolved, target, entry) do
    with {:ok, ours} <- read_destination(root, target.destination),
         {:ok, base} <- base(rules, upstream, entry, target.mapping, formatter) do
      theirs = target.theirs

      cond do
        MapSet.member?(resolved, target.destination) ->
          {:ok, {:resolved, target, ours}}

        ours == theirs ->
          {:ok, {:unchanged, target, theirs}}

        ours == base ->
          {:ok, {:upstream, target, theirs}}

        true ->
          labels = [
            "cli #{target.destination}",
            "upstream #{Git.short(entry["upstream_commit"])}",
            "upstream #{Git.short(sha)}"
          ]

          case Git.merge(ours, base, theirs, labels) do
            {:ok, merged} ->
              with {:ok, merged} <-
                     reformat(target.mapping, target.destination, merged, formatter),
                   do: {:ok, {:merged, target, merged}}

            {:conflict, text} ->
              {:ok, {:conflict, target, text}}

            {:error, message} ->
              {:error, "#{target.destination}: #{message}"}
          end
      end
    end
  end

  defp removals(root, rules, ledger, upstream, targets, formatter) do
    target_paths = MapSet.new(targets, & &1.upstream_path)

    ledger.entries
    |> Enum.filter(
      &(synced?(rules, &1) and not MapSet.member?(target_paths, &1["upstream_path"]))
    )
    |> async(fn entry ->
      mapping = Rules.mapping_for(rules, entry["upstream_path"])

      with {:ok, base} <- base(rules, upstream, entry, mapping, formatter) do
        case File.read(Path.join(root, entry["destination"])) do
          {:ok, ^base} -> {:ok, {:removed, entry}}
          {:error, :enoent} -> {:ok, {:removed, entry}}
          _patched -> {:ok, {:patched, entry}}
        end
      end
    end)
    |> collect()
  end

  defp apply_plan(root, rules, ledger, sha, planned, removed) do
    results = for {kind, target, content} <- planned, do: {kind, target, content}

    for {_kind, target, content} <- results do
      path = Path.join(root, target.destination)

      if File.read(path) != {:ok, content} do
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end

      write_patch(root, target, sha, content)
      File.rm(path <> ".sync-conflict")
    end

    removed_entries = for {:removed, entry} <- removed, do: entry

    for entry <- removed_entries do
      File.rm(Path.join(root, entry["destination"]))
      File.rm(Path.join(root, patch_path(entry["destination"])))
    end

    target_destinations =
      MapSet.new(results, fn {_kind, target, _content} -> target.destination end)

    for patch <- patch_destinations(root),
        not MapSet.member?(target_destinations, patch),
        do: File.rm(Path.join(root, patch_path(patch)))

    updated =
      Map.new(results, fn {_kind, target, content} ->
        {target.destination, entry(target, sha, content)}
      end)

    dropped = MapSet.new(removed_entries, & &1["destination"])

    kept =
      ledger.entries
      |> Enum.reject(&MapSet.member?(dropped, &1["destination"]))
      |> Enum.map(&Map.get(updated, &1["destination"], &1))

    known = MapSet.new(ledger.entries, & &1["destination"])

    added =
      updated
      |> Map.values()
      |> Enum.reject(&MapSet.member?(known, &1["destination"]))
      |> Enum.sort_by(& &1["destination"])

    Ledger.write(root, kept ++ added)
    Rules.write_pin(rules, sha)

    count = fn kind -> for({^kind, target, _} <- results, do: target.destination) end

    %{
      ref: sha,
      created: count.(:created),
      upstream: count.(:upstream),
      merged: count.(:merged),
      resolved: count.(:resolved),
      unchanged: length(count.(:unchanged)),
      removed: Enum.map(removed_entries, & &1["destination"]),
      patched:
        for({_kind, target, content} <- results, content != target.theirs, do: target.destination)
    }
  end

  defp entry(target, sha, content) do
    %{
      "classification" => target.mapping.classification,
      "destination" => target.destination,
      "sha256" => sha256(content),
      "upstream_commit" => sha,
      "upstream_path" => target.upstream_path,
      "upstream_sha256" => sha256(target.raw)
    }
  end

  defp write_patch(root, target, sha, content) do
    path = Path.join(root, patch_path(target.destination))

    case patch_text(target, sha, content) do
      "" ->
        File.rm(path)

      text ->
        File.mkdir_p!(Path.dirname(path))
        if File.read(path) != {:ok, text}, do: File.write!(path, text)
    end
  end

  # -- check -------------------------------------------------------------------

  defp check_target(root, rules, upstream, sha, by_destination, formatter, target) do
    entry = Map.get(by_destination, target.destination)

    with {:entry, %{} = entry} <- {:entry, entry},
         true <- synced?(rules, entry) || {:entry, :frozen},
         {:ok, raw} <- Git.show(upstream, sha, target.upstream_path),
         {:ok, theirs} <- derive(rules, target.mapping, target.destination, raw, formatter),
         {:ok, current} <- read_destination(root, target.destination) do
      target = Map.merge(target, %{raw: raw, theirs: theirs})
      expected_patch = patch_text(target, sha, current)

      recorded_patch =
        case File.read(Path.join(root, patch_path(target.destination))) do
          {:ok, text} -> text
          {:error, _reason} -> ""
        end

      []
      |> add(
        entry["upstream_commit"] != sha,
        "#{target.destination}: pinned to #{entry["upstream_commit"]}, not #{sha}"
      )
      |> add(
        entry["classification"] != target.mapping.classification,
        "#{target.destination}: classification is not #{target.mapping.classification}"
      )
      |> add(
        entry["upstream_sha256"] != sha256(raw),
        "#{target.destination}: upstream_sha256 does not match #{target.upstream_path}"
      )
      |> add(
        entry["sha256"] != sha256(current),
        "#{target.destination}: sha256 does not match the file"
      )
      |> add(
        expected_patch != recorded_patch,
        if(recorded_patch == "",
          do:
            "#{target.destination}: differs from the upstream derivation and has no recorded patch",
          else:
            "#{target.destination}: #{patch_path(target.destination)} no longer describes the file"
        )
      )
    else
      {:entry, nil} ->
        ["#{target.destination}: #{target.upstream_path} is upstream but not synced"]

      {:entry, :frozen} ->
        ["#{target.destination}: collides with a frozen provenance entry"]

      {:error, message} ->
        ["#{target.destination}: #{message}"]
    end
  end

  # -- derivation --------------------------------------------------------------

  defp derive(rules, mapping, destination, raw, formatter) do
    text = if mapping.rewrite, do: Rules.rewrite(rules, raw), else: raw
    reformat(mapping, destination, text, formatter)
  end

  defp reformat(%Rules.Mapping{format: false}, _destination, text, _formatter), do: {:ok, text}

  defp reformat(%Rules.Mapping{format: true}, destination, text, formatter) do
    {:ok, formatter.(destination, text)}
  rescue
    error -> {:error, "#{destination} does not format: #{Exception.message(error)}"}
  end

  defp base(rules, upstream, entry, mapping, formatter) do
    with {:ok, raw} <- Git.show(upstream, entry["upstream_commit"], entry["upstream_path"]),
         do: derive(rules, mapping, entry["destination"], raw, formatter)
  end

  defp read_destination(root, destination) do
    case File.read(Path.join(root, destination)) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _reason} -> {:error, "#{destination} is tracked but cannot be read"}
    end
  end

  defp patch_text(target, sha, content) do
    case UnifiedDiff.diff(target.theirs, content, target.destination, target.destination) do
      "" ->
        ""

      diff ->
        "# CLI-local change to #{target.upstream_path} at #{Git.short(sha)}, after the rewrite\n" <>
          "# rules of provenance/sync-rules.json. Recorded by mix swarm_code.provenance.sync.\n" <>
          diff
    end
  end

  defp patch_destinations(root) do
    dir = Path.join(root, @patches)

    if File.dir?(dir) do
      dir
      |> Path.join("**/*.diff")
      |> Path.wildcard(match_dot: true)
      |> Enum.map(&(&1 |> Path.relative_to(dir) |> String.replace_suffix(".diff", "")))
      |> Enum.sort()
    else
      []
    end
  end

  # -- helpers -----------------------------------------------------------------

  defp async(items, fun) do
    items
    |> Task.async_stream(fun,
      ordered: true,
      timeout: :infinity,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  defp collect(results) do
    case Enum.split_with(results, &match?({:ok, _}, &1)) do
      {ok, []} ->
        {:ok, Enum.map(ok, fn {:ok, value} -> value end)}

      {_ok, errors} ->
        {:error,
         errors |> Enum.map(fn {:error, message} -> message end) |> bounded() |> Enum.join("\n")}
    end
  end

  defp bounded(errors) when length(errors) > @max_errors,
    do: Enum.take(errors, @max_errors) ++ ["… and #{length(errors) - @max_errors} more"]

  defp bounded(errors), do: errors

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp add(errors, true, message), do: errors ++ [message]
  defp add(errors, false, _message), do: errors
end
