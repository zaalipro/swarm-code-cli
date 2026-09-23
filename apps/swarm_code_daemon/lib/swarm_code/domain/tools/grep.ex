defmodule SwarmCode.Domain.Tools.Grep do
  @moduledoc "Search file contents with a regular expression."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.Path
  alias SwarmCode.Domain.Tools.Ripgrep

  @max_file_size 1_000_000

  # Spec 51 §7.2 (R20): OTP's default `match_limit` is 10 000 000 — `(a+)+$` on
  # 100 41-character lines pinned a scheduler for 13.1 s. At 100 000 the same
  # pattern gives up after 1.4 ms and the op says what is wrong.
  @match_limit 100_000
  @max_line 4_096

  @impl true
  def name, do: "grep"

  @impl true
  # Spec 54 §5 (54c H9): what it skips and where it stops.
  def description,
    do:
      "Search file contents with a regular expression (Elixir/PCRE syntax, case-sensitive) " <>
        "and return matching lines as \"path:line: text\". Searches the project tree under " <>
        "path, skipping binaries, files over 1 MB and the usual ignored directories; lines " <>
        "are cut at 4 096 characters and the result stops at max_results, so a broad pattern " <>
        "returns a truncated sample rather than everything. It reports where matches are, " <>
        "not the surrounding code — read_file the hits you care about."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "pattern" => %{"type" => "string", "description" => "Regular expression"},
        "path" => %{
          "type" => "string",
          "description" => "Directory or file to search (default \".\")"
        },
        "glob" => %{"type" => "string", "description" => "File name glob, e.g. \"*.ex\""},
        "max_results" => %{"type" => "integer", "description" => "1-500 (default 100)"}
      },
      "required" => ["pattern"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "grep " <> to_string(args["pattern"] || "")

  @impl true
  def run(args, ctx, progress) do
    with {:ok, abs} <- Path.resolve(ctx.project_root, args["path"] || ".") do
      source = to_string(args["pattern"])
      max = clamp(args["max_results"] || 100, 1, 500)

      case Regex.compile(source, "") do
        {:error, {msg, _}} ->
          {:error, "invalid regex: #{msg}"}

        {:ok, re} ->
          compiled = {Regex.re_pattern(re), file_filter(source)}
          files = file_candidates(abs, args["glob"], ctx.project_root, source)
          scan(files, compiled, max, ctx.project_root, progress)
      end
    end
  end

  # spec 70 C3: true when rg is available and supports --pcre2.
  defp use_rg?, do: Ripgrep.available?() and Ripgrep.pcre2?()

  # spec 70 G1: when rg is available, narrow the candidate list to files that
  # contain a content match before the Elixir scanner touches them. rg cannot
  # restrict matching to the first 4 KB of a line (spec 51 §7.2), so the
  # scanner handles every line-level contract: 4 KB window, match_limit
  # backtracking refusal, progress detail, and output formatting.
  @ignored_globs ~w(_build* .git deps node_modules .elixir_ls .superpowers .DS_Store cover doc)

  defp file_candidates(abs, glob, root, source) do
    all_files = fn -> candidates(abs, glob, root) end

    if File.dir?(abs) and use_rg?() do
      case rg_matching_set(source, abs, root) do
        {:ok, rg_set} when map_size(rg_set) > 0 ->
          all_files.() |> Enum.filter(&Map.has_key?(rg_set, &1))

        {:ok, _empty} ->
          []

        :fallback ->
          all_files.()
      end
    else
      all_files.()
    end
  end

  defp rg_matching_set(pattern, abs_path, _root) do
    rg = Ripgrep.rg_path()
    skip = Enum.flat_map(@ignored_globs, &["--glob", "!#{&1}"])

    args =
      ["--pcre2", "--files-with-matches", "--no-follow", "--color", "never"] ++
        ["--max-filesize", "1M", "--hidden"] ++
        skip ++ [pattern, abs_path]

    case System.cmd(rg, args,
           cd: abs_path,
           env: [{"HOME", System.user_home!()}],
           stderr_to_stdout: true
         ) do
      {output, code} when code in [0, 1] ->
        set =
          output
          |> String.split("\n", trim: true)
          |> Map.new(&{Elixir.Path.expand(&1), true})

        {:ok, set}

      {_output, _code} ->
        :fallback
    end
  rescue
    _ -> :fallback
  end

  # Spec 51 §7.1: 539 files of this repository are 191 000 lines, and one
  # `:re.run` per line is 140 ms of NIF overhead for a pattern that matches
  # nothing at all. The same pattern compiled with `m` — so `^` and `$` still
  # mean "line" — is run **once** over the whole file first, and only a file
  # that can match is split and walked line by line.
  #
  # Two constructs mean something different against a line than against a file:
  # the subject-anchored escapes (`\A`, `\z`, `\Z`, `\G`) and lookbehind, which
  # sees `\n` in a file where it saw the start of the subject in a line. A
  # pattern that uses either keeps the line-by-line pass alone.
  @not_line_safe ["\\A", "\\z", "\\Z", "\\G", "(?<"]

  defp file_filter(source) do
    with false <- Enum.any?(@not_line_safe, &String.contains?(source, &1)),
         {:ok, re} <- Regex.compile(source, "m") do
      Regex.re_pattern(re)
    else
      _no_filter -> nil
    end
  end

  # Sakana task 2: the wildcard followed directory symlinks, so a link to `/etc`
  # inside the repo used to hand back outside files that the starting-directory
  # check never saw. Confinement still runs per candidate, before the file is
  # ever stat-ed or read — but now inside `Path.walk/3`, which prunes the
  # ignored directories before it enters them and resolves the root once
  # (spec 51 §7.1, E3: 20 017 entries and 7.7 s of listing, gone).
  defp candidates(abs, glob, root) do
    cond do
      File.regular?(abs) -> [abs]
      File.dir?(abs) -> Path.walk(root, abs, glob: glob)
      true -> []
    end
  end

  defp scan(files, pattern, max, root, progress) do
    total = length(files)

    result =
      files
      |> Enum.with_index(1)
      |> Enum.reduce_while({[], 0}, fn {file, i}, {acc, count} ->
        if rem(i, 25) == 0 do
          progress.(div(i * 100, max(total, 1)), "#{i}/#{total} files")
        end

        case scan_file(file, pattern, max, root, acc, count) do
          {:error, message} -> {:halt, {:error, message}}
          {acc, count} when count >= max -> {:halt, {acc, count}}
          {acc, count} -> {:cont, {acc, count}}
        end
      end)

    case result do
      {:error, message} ->
        {:error, message}

      {lines, _count} ->
        progress.(100, "#{total}/#{total} files")
        lines = Enum.reverse(lines)

        cond do
          lines == [] -> {:ok, "no matches"}
          length(lines) >= max -> {:ok, Enum.join(lines, "\n") <> "\n…[max_results reached]"}
          true -> {:ok, Enum.join(lines, "\n")}
        end
    end
  end

  defp scan_file(file, pattern, max, root, acc, count) do
    with {:ok, %{size: size}} when size <= @max_file_size <- File.stat(file, time: :posix),
         {:ok, content} <- read_text(file, size) do
      scan_content(content, file, pattern, max, root, acc, count)
    else
      _ -> {acc, count}
    end
  end

  defp scan_content(content, file, {pattern, filter}, max, root, acc, count) do
    # A file-level `:match_limit` deliberately falls through to the line pass:
    # that pass is what names the line in the error (spec 51 §7.2).
    if prefilter(filter, content) == :nomatch do
      {acc, count}
    else
      rel = Path.relative(root, file)

      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.reduce_while({acc, count}, fn {line, n}, {acc, count} ->
        cond do
          count >= max ->
            {:halt, {acc, count}}

          true ->
            case match_line(pattern, line) do
              :match ->
                text = "#{rel}:#{n}: #{String.slice(String.trim_trailing(line), 0, 300)}"
                {:cont, {[text | acc], count + 1}}

              :nomatch ->
                {:cont, {acc, count}}

              :match_limit ->
                {:halt, {:error, "the pattern backtracks too much on #{rel}:#{n} — simplify it"}}
            end
        end
      end)
    end
  end

  defp prefilter(nil, _content), do: :match

  defp prefilter(pattern, content) do
    case :re.run(content, pattern, [
           {:capture, :none},
           {:match_limit, @match_limit},
           :report_errors
         ]) do
      :nomatch -> :nomatch
      _match_or_error -> :match
    end
  end

  # Spec 51 §7.1 (E3): the whole file used to be read before the binary sniff
  # looked at its first 8 000 bytes — 228 MB of reads per op on this repository.
  # The head comes first now and the rest is only read when the head is text.
  @sniff 8_192

  # `:raw` matters: without it every `open`/`read`/`close` is a message round
  # trip through the file server, which is 2 000 round trips for one grep of
  # this repository (spec 51 §7.1).
  defp read_text(file, size) do
    case :file.open(file, [:read, :binary, :raw]) do
      {:ok, fd} ->
        try do
          read_text(fd, size, :file.read(fd, @sniff))
        after
          :file.close(fd)
        end

      {:error, _reason} ->
        :error
    end
  end

  defp read_text(_fd, _size, :eof), do: {:ok, ""}
  defp read_text(_fd, _size, {:error, _reason}), do: :error

  defp read_text(fd, size, {:ok, head}) do
    count_read(byte_size(head))

    cond do
      binary?(head) ->
        :error

      byte_size(head) >= size ->
        {:ok, head}

      true ->
        case :file.read(fd, size - byte_size(head)) do
          {:ok, rest} ->
            count_read(byte_size(rest))
            {:ok, head <> rest}

          :eof ->
            {:ok, head}

          {:error, _reason} ->
            :error
        end
    end
  end

  # Spec 51 §7.1: the acceptance test needs the bytes one op actually read off
  # the disk. Production never sets the key and pays one `Process.get/1` per
  # file; a test puts a `:counters` reference there and reads it back.
  defp count_read(bytes) do
    case Process.get(:read_counter) do
      nil -> :ok
      counter -> :counters.add(counter, 1, bytes)
    end
  end

  defp match_line(pattern, line) do
    subject = binary_part(line, 0, min(byte_size(line), @max_line))

    case :re.run(subject, pattern, [
           {:capture, :none},
           {:match_limit, @match_limit},
           :report_errors
         ]) do
      :match -> :match
      :nomatch -> :nomatch
      {:error, _reason} -> :match_limit
    end
  end

  @doc false
  @spec binary?(binary()) :: boolean()
  def binary?(content) do
    head = binary_part(content, 0, min(byte_size(content), @sniff))
    :binary.match(head, <<0>>) != :nomatch
  end

  # spec 68 T19: delegate to the shared Tools.clamp/3.
  defp clamp(value, min_v, max_v), do: SwarmCode.Domain.Tools.clamp(value, min_v, max_v)
end
