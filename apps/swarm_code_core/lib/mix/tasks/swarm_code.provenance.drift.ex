defmodule Mix.Tasks.SwarmCode.Provenance.Drift do
  @shortdoc "Reports how far the desktop has moved past the CLI's pinned commit"

  @moduledoc """
  The provenance drift gate (cli020 A7): compares the desktop commit this CLI
  is pinned to (`provenance/sync-rules.json`) with a desktop ref, read-only.

      mix swarm_code.provenance.drift [--ref REF] [--upstream PATH] [--strict]

  The upstream checkout is `--upstream`, else `$SWARM_CODE_UPSTREAM`, else
  `~/dev/swarm-code` (as `swarm_code.provenance.sync` resolves it); `REF`
  defaults to `main`. Only `git rev-parse`, `ls-tree` and `rev-list` run
  against it, each bounded to 30 s; nothing is written.

  - Migrations at `REF` that the pin lacks: a desktop release with them would
    make this CLI refuse the shared database. Exit 1.
  - Only code drift (commits since the pin that touch `lib/swarm_code` or
    `priv`): a warning, exit 0; exit 1 with `--strict`.
  - No desktop checkout at the path: skipped, exit 0; exit 1 with `--strict`.
  - C-ARCH-3: the verdict is followed by every ledger entry
    (`provenance/extracted-files.json`) whose upstream file changed since the
    commit that entry was synced from, most-changed first: the web-lineage
    ports (`command_dispatcher.ex` from `workspace_live.ex`) are not under
    `lib/swarm_code`, so the count above never sees them. Information only; it
    never changes the exit status.

  `mix precommit` runs it without `--strict`; `scripts/dev/build_release.sh`
  runs it with `--strict` (escape hatch `NCODE_ALLOW_DRIFT=1`).
  """

  use Mix.Task

  @switches [ref: :string, upstream: :string, strict: :boolean]
  @migrations "priv/repo/migrations/"
  @domain ["lib/swarm_code", "priv"]
  @ledger "provenance/extracted-files.json"
  @ledger_lines 50
  @git_timeout_ms 30_000
  @ref_pattern ~r/\A[0-9A-Za-z][0-9A-Za-z._\/^~-]{0,199}\z/

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)

    if rest != [] or invalid != [] do
      Mix.raise("Unexpected arguments. " <> usage())
    end

    upstream = upstream(opts[:upstream])
    ref = opts[:ref] || "main"
    strict? = opts[:strict] == true

    {status, lines} = drift(File.cwd!(), upstream, ref, strict?)
    shell = Mix.shell()
    Enum.each(lines, fn line -> if status == 0, do: shell.info(line), else: shell.error(line) end)

    if status != 0, do: exit({:shutdown, status})
    :ok
  end

  @doc """
  The gate's verdict for the CLI checkout at `root`: `{exit_status, lines}`.
  """
  @spec drift(Path.t(), Path.t(), String.t(), boolean()) :: {0 | 1, [String.t()]}
  def drift(root, upstream, ref, strict?) do
    if checkout?(upstream) do
      with {:ok, pin} <- pin(root),
           {:ok, pin_sha} <- resolve(upstream, pin),
           {:ok, ref_sha} <- resolve(upstream, ref),
           {:ok, at_pin} <- migrations(upstream, pin_sha),
           {:ok, at_ref} <- migrations(upstream, ref_sha),
           {:ok, commits} <- domain_commits(upstream, pin_sha, ref_sha) do
        {status, lines} = verdict(ref, ref_sha, pin_sha, at_ref -- at_pin, commits, strict?)
        {status, lines ++ ledger_lines(root, upstream, ref_sha)}
      else
        {:error, message} -> {1, ["ncode CLI drift: " <> message]}
      end
    else
      {if(strict?, do: 1, else: 0),
       ["ncode CLI drift: no desktop checkout at #{upstream}; skipped."]}
    end
  end

  defp verdict(ref, ref_sha, _pin_sha, [_ | _] = new, _commits, _strict?) do
    {1,
     [
       "ncode CLI drift: desktop #{ref} (#{short(ref_sha)}) has #{length(new)} migration(s) " <>
         "this CLI does not know:"
     ] ++
       Enum.map(new, &("  " <> &1)) ++
       [
         "A desktop release with these would make this CLI refuse the database. " <>
           "Re-pin: mix swarm_code.provenance.sync --ref #{ref_sha}."
       ]}
  end

  defp verdict(_ref, _ref_sha, _pin_sha, [], commits, strict?) when commits > 0 do
    {if(strict?, do: 1, else: 0),
     [
       "ncode CLI drift: #{commits} desktop commits since the pin touch the domain " <>
         "(no new migrations)."
     ]}
  end

  defp verdict(ref, ref_sha, pin_sha, [], 0, _strict?) do
    {0,
     [
       "ncode CLI drift: none (desktop #{ref} (#{short(ref_sha)}) adds no migration and no " <>
         "domain commit since the pin #{short(pin_sha)})."
     ]}
  end

  defp pin(root) do
    with {:ok, bytes} <- File.read(Path.join(root, "provenance/sync-rules.json")),
         {:ok, %{"upstream_commit" => pin}} when is_binary(pin) <- Jason.decode(bytes) do
      {:ok, pin}
    else
      _ -> {:error, "cannot read the pin from provenance/sync-rules.json."}
    end
  end

  defp resolve(upstream, ref) do
    with true <- Regex.match?(@ref_pattern, ref),
         {:ok, out} <- git(upstream, ["rev-parse", "--verify", "--quiet", ref <> "^{commit}"]),
         sha = String.trim(out),
         true <- Regex.match?(~r/\A[0-9a-f]{40}\z/, sha) do
      {:ok, sha}
    else
      _ -> {:error, "cannot resolve #{ref} in #{upstream}."}
    end
  end

  defp migrations(upstream, sha) do
    case git(upstream, ["ls-tree", "--name-only", sha, @migrations]) do
      {:ok, out} ->
        {:ok,
         out
         |> String.split("\n", trim: true)
         |> Enum.map(&Path.basename/1)
         |> Enum.filter(&String.ends_with?(&1, ".exs"))
         |> Enum.sort()}

      {:error, _} ->
        {:error, "cannot list #{@migrations} at #{short(sha)}."}
    end
  end

  defp domain_commits(upstream, pin_sha, ref_sha) do
    with {:ok, out} <-
           git(upstream, ["rev-list", "--count", "#{pin_sha}..#{ref_sha}", "--" | @domain]),
         {count, ""} <- Integer.parse(String.trim(out)) do
      {:ok, count}
    else
      _ -> {:error, "cannot count the commits #{short(pin_sha)}..#{short(ref_sha)}."}
    end
  end

  # C-ARCH-3: one `rev-list --count` per distinct {commit, upstream path}
  # (at most one per ledger entry), against the commit the entry was synced
  # from. An entry whose commit this checkout does not know is left out.
  defp ledger_lines(root, upstream, ref_sha) do
    entries = ledger(root)

    changed =
      entries
      |> Enum.map(&{&1["upstream_commit"], &1["upstream_path"]})
      |> Enum.uniq()
      |> Map.new(fn {commit, path} = key ->
        {key, entry_commits(upstream, commit, ref_sha, path)}
      end)

    moved =
      for entry <- entries,
          count = Map.get(changed, {entry["upstream_commit"], entry["upstream_path"]}),
          is_integer(count) and count > 0,
          do: {count, entry["upstream_path"], entry["destination"]}

    case Enum.sort_by(moved, fn {count, path, _} -> {-count, path} end) do
      [] ->
        []

      sorted ->
        shown = Enum.take(sorted, @ledger_lines)
        more = length(sorted) - length(shown)

        ["ncode CLI drift: #{length(sorted)} ledger entries changed upstream since their pin:"] ++
          Enum.map(shown, fn {count, path, destination} ->
            "  #{String.pad_leading(Integer.to_string(count), 4)}  #{path} → #{destination}"
          end) ++
          if(more > 0, do: ["  … and #{more} more."], else: [])
    end
  end

  defp ledger(root) do
    with {:ok, bytes} <- File.read(Path.join(root, @ledger)),
         {:ok, %{"entries" => entries}} when is_list(entries) <- Jason.decode(bytes) do
      Enum.filter(entries, fn entry ->
        is_map(entry) and is_binary(entry["upstream_commit"]) and
          Regex.match?(~r/\A[0-9a-f]{40}\z/, entry["upstream_commit"]) and
          is_binary(entry["upstream_path"]) and is_binary(entry["destination"])
      end)
    else
      _ -> []
    end
  end

  defp entry_commits(upstream, commit, ref_sha, path) do
    with {:ok, out} <-
           git(upstream, ["rev-list", "--count", "#{commit}..#{ref_sha}", "--", path]),
         {count, ""} <- Integer.parse(String.trim(out)) do
      count
    else
      _ -> nil
    end
  end

  defp checkout?(upstream) do
    File.dir?(upstream) and match?({:ok, _}, git(upstream, ["rev-parse", "--git-dir"]))
  end

  # Read-only git, bounded: a hung git (a lock, a network filesystem) cannot
  # hold the release build or precommit.
  defp git(upstream, args) do
    task =
      Task.async(fn ->
        try do
          System.cmd("git", ["-C", upstream | args], stderr_to_stdout: false)
        rescue
          error in ErlangError -> {:unavailable, Exception.message(error)}
        end
      end)

    case Task.yield(task, @git_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} -> {:ok, out}
      {:ok, {_out, status}} when is_integer(status) -> {:error, status}
      {:ok, {:unavailable, message}} -> {:error, message}
      nil -> {:error, :timeout}
    end
  end

  defp short(sha), do: String.slice(sha, 0, 7)

  defp upstream(nil) do
    case System.get_env("SWARM_CODE_UPSTREAM") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _unset -> Path.expand("~/dev/swarm-code")
    end
  end

  defp upstream(path), do: Path.expand(path)

  defp usage do
    "Usage: mix swarm_code.provenance.drift [--ref REF] [--upstream PATH] [--strict]"
  end
end
