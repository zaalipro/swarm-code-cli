defmodule SwarmCode.Domain.Tools.EditFile do
  @moduledoc """
  Replace an exact string in a file — or several strings in one call.

  spec 66 T9: the byte-exact search is still the first pass and still decides on
  its own whenever it matches anything at all. Only when it finds *nothing* do
  three line-based passes run (trailing whitespace, indentation, then unicode
  quotes/dashes/spaces), so a smart quote or a CRLF file costs a note in the
  result instead of a failed call and a re-read.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.AtomicFile
  alias SwarmCode.Domain.Tools.Grep
  alias SwarmCode.Domain.Tools.Path

  # The same ceiling `read_file` refuses at.
  @max_size 5_000_000

  # spec 66 T9: the table at `codex-rs/apply-patch/src/seek_sequence.rs:84-97`,
  # written as codepoint escapes on purpose — several of these are invisible.
  # (A `~w` sigil is impossible here: every one of @spaces is unicode
  # whitespace, and the sigil would split the list on exactly the members it
  # is meant to hold.)
  @dashes ["\u2010", "\u2011", "\u2012", "\u2013", "\u2014", "\u2015", "\u2212"]
  @squotes ["\u2018", "\u2019", "\u201A", "\u201B"]
  @dquotes ["\u201C", "\u201D", "\u201E", "\u201F"]
  @spaces [
    "\u00A0",
    "\u2002",
    "\u2003",
    "\u2004",
    "\u2005",
    "\u2006",
    "\u2007",
    "\u2008",
    "\u2009",
    "\u200A",
    "\u202F",
    "\u205F",
    "\u3000"
  ]
  @bom "\uFEFF"

  @impl true
  def name, do: "edit_file"

  @impl true
  # Spec 54 §5 (54c H9): the contract, not a one-liner. `old_string` is matched
  # literally, never as a pattern, and the caller cannot see the checkpoint
  # snapshot or the 5 MB refusal from the old text.
  # spec 66 T9/T10: the fuzzy fallback and the `edits` array are part of the
  # contract too — a model that does not know about `edits` pays six round
  # trips for a six-site rename.
  def description,
    do:
      "Replace an exact string in an existing text file, in place. old_string is matched " <>
        "literally, not as a pattern, and must occur exactly once unless replace_all is true; " <>
        "two or more matches without replace_all is an error that changes nothing, so include " <>
        "enough surrounding lines to make the match unique. If the exact text is not found, " <>
        "the match is retried line by line ignoring trailing whitespace, then indentation, " <>
        "then unicode quotes, dashes and spaces, and the result says which pass matched. " <>
        "Pass edits to make several replacements in one call, in order and all-or-nothing: " <>
        "if any one of them fails the file is not written at all. The file must already exist " <>
        "and be text under 5 MB — use write_file for a new file and run_command for a larger " <>
        "one. The write is atomic and snapshotted, so a failed edit leaves the original " <>
        "intact. Returns the number of replacements, not the new content."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the project root"},
        "old_string" => %{"type" => "string", "description" => "Exact text to replace"},
        "new_string" => %{"type" => "string", "description" => "Replacement text"},
        "replace_all" => %{"type" => "boolean", "description" => "Replace every occurrence"},
        # spec 66 T10
        "edits" => %{
          "type" => "array",
          "description" =>
            "Several replacements in one call, applied in order and all-or-nothing: if any " <>
              "one fails, the file is not written at all. Use this instead of calling " <>
              "edit_file repeatedly.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "old_string" => %{"type" => "string"},
              "new_string" => %{"type" => "string"},
              "replace_all" => %{"type" => "boolean"}
            },
            "required" => ["old_string", "new_string"]
          }
        }
      },
      # spec 66 T10: `old_string`/`new_string` are required *unless* `edits` is
      # given, which the registry's flat `required` list cannot say — `run/3`
      # checks the pair itself and names both forms.
      "required" => ["path"]
    }
  end

  @impl true
  def permission(_args), do: :write

  # spec 66 T20: two edits of one file in one model response are run one after
  # the other, never concurrently.
  @impl true
  def parallel?, do: false

  @impl true
  def title(args), do: "edit " <> (args["path"] || "")

  @impl true
  def run(args, ctx, progress) do
    # spec 66 T11: `.git/`, `.swarm_code/` and `.claude/` are read-only to tools.
    with {:ok, edits} <- edits(args),
         {:ok, abs} <- Path.resolve_write(ctx.project_root, args["path"]) do
      rel = Path.relative(ctx.project_root, abs)

      # Spec 51 §7.5 (M9): `read_file` refuses more than 5 MB and `grep` skips
      # binaries; `edit_file` read anything and then made three copies of it.
      # It refuses the same two things now, before the first copy exists.
      case File.stat(abs) do
        {:error, :enoent} ->
          {:error, "file not found: #{rel}"}

        {:error, reason} ->
          {:error, "cannot read #{rel}: #{reason}"}

        {:ok, %{size: size}} when size > @max_size ->
          {:error,
           "file too large to edit: #{rel} (#{size} bytes) — use run_command with sed or perl"}

        {:ok, _stat} ->
          read_and_edit(abs, rel, ctx, edits, progress)
      end
    end
  end

  # spec 66 T10: one normalised list of edits for both call shapes. The
  # single-edit form is `[%{...}]` and takes exactly today's path through
  # `apply_edits/2`.
  defp edits(args) do
    list = args["edits"]
    single? = is_binary(args["old_string"]) or is_binary(args["new_string"])

    cond do
      is_list(list) and list != [] and single? ->
        {:error, "pass either old_string/new_string or edits, not both"}

      is_list(list) and list != [] ->
        case Enum.find_index(list, &(not edit?(&1))) do
          nil -> {:ok, Enum.map(list, &normalise_edit/1)}
          i -> {:error, "edit #{i + 1} of #{length(list)}: needs old_string and new_string"}
        end

      single? and is_binary(args["old_string"]) and is_binary(args["new_string"]) ->
        {:ok, [normalise_edit(args)]}

      true ->
        {:error,
         "edit_file needs old_string and new_string, or a non-empty edits array" <> received(args)}
    end
  end

  defp edit?(edit),
    do: is_map(edit) and is_binary(edit["old_string"]) and is_binary(edit["new_string"])

  defp normalise_edit(edit),
    do: %{
      old: edit["old_string"],
      new: edit["new_string"],
      replace_all: edit["replace_all"] == true
    }

  # spec 68 T20: delegate to the shared Tools.received/1.
  defp received(args), do: SwarmCode.Domain.Tools.received(args)

  defp read_and_edit(abs, rel, ctx, edits, progress) do
    case File.read(abs) do
      {:error, :enoent} ->
        {:error, "file not found: #{rel}"}

      {:error, reason} ->
        {:error, "cannot read #{rel}: #{reason}"}

      {:ok, content} ->
        if Grep.binary?(content) do
          {:error, "cannot edit a binary file: #{rel}"}
        else
          # spec 55 T16 (55a A17): no checkpoint, no edit.
          # spec 60 T26: any failure, not only busy, refuses the edit.
          case SwarmCode.Domain.Checkpoints.snapshot(ctx, abs) do
            :ok -> edit(content, ctx.project_root, abs, rel, edits, progress)
            {:error, reason} -> {:error, SwarmCode.Domain.Checkpoints.error_message(reason)}
          end
        end
    end
  end

  defp edit(content, root, abs, rel, edits, progress) do
    with {:ok, new_content, applied} <- apply_edits(content, edits, rel) do
      cond do
        # spec 60 T18: the tool's contract is "text under 5 MB" — for the
        # result too. spec 66 T10: checked once, against the final content.
        byte_size(new_content) > @max_size ->
          {:error,
           "edit would grow #{rel} past 5 MB (#{byte_size(new_content)} bytes) — " <>
             "use run_command with sed or perl"}

        true ->
          # Spec 32 §1: the replacement lands whole or not at all.
          case AtomicFile.replace(root, abs, new_content) do
            :ok ->
              total = Enum.sum(Enum.map(applied, & &1.count))
              progress.(100, "#{total} replacement(s)")
              {:ok, result_line(rel, edits, applied, total)}

            {:error, reason} ->
              {:error, "cannot write #{rel}: #{AtomicFile.format_error(reason)}"}
          end
      end
    end
  end

  # One line for one edit (today's sentence, plus the pass when it was not
  # exact); one line for a batch (spec 66 T10).
  defp result_line(rel, [_single], [applied], total) do
    "edited #{rel}: #{total} replacement(s)" <> pass_note(applied.pass)
  end

  defp result_line(rel, edits, applied, total) do
    notes =
      applied
      |> Enum.map(& &1.pass)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == :exact))
      |> Enum.map_join("", &pass_note/1)

    "edited #{rel}: #{length(edits)} edits, #{total} replacement(s)" <> notes
  end

  defp pass_note(:exact), do: ""
  defp pass_note(:trailing), do: " (matched ignoring trailing whitespace)"
  defp pass_note(:indent), do: " (matched ignoring indentation)"
  defp pass_note(:unicode), do: " (matched after normalising quotes, dashes and spaces)"

  # spec 66 T10: in order, in memory; the first failure aborts and nothing is
  # written. A single edit keeps its error verbatim.
  # spec 70 C5: made public so EditFiles can reuse the same logic.
  @doc false
  def apply_edits(content, edits, rel) do
    n = length(edits)

    # spec 68 T18: prepend + reverse instead of applied ++ [info].
    case edits
         |> Enum.with_index(1)
         |> Enum.reduce_while({:ok, content, []}, fn {edit, i}, {:ok, acc, applied} ->
           case apply_one(acc, edit, rel) do
             {:ok, next, info} ->
               {:cont, {:ok, next, [info | applied]}}

             {:error, message} when n == 1 ->
               {:halt, {:error, message}}

             {:error, message} ->
               {:halt, {:error, "edit #{i} of #{n}: " <> message}}
           end
         end) do
      {:ok, final, applied} -> {:ok, final, Enum.reverse(applied)}
      error -> error
    end
  end

  defp apply_one(_content, %{old: ""}, _rel), do: {:error, "old_string must not be empty"}

  defp apply_one(content, %{old: old, new: new, replace_all: replace_all}, rel) do
    # Pass 1 — byte-exact, the substring search this tool has always done, and
    # the only pass that can match inside a line. Spec 51 §7.5 (M9):
    # `:binary.matches/2` counts without materialising the fragments.
    case length(:binary.matches(content, old)) do
      0 ->
        fuzzy(content, old, new, replace_all, rel)

      count when count > 1 and not replace_all ->
        {:error,
         "old_string matches #{count} places in #{rel}; provide more context or set replace_all=true"}

      count ->
        replaced = String.replace(content, old, new, global: replace_all)
        {:ok, replaced, %{pass: :exact, count: if(replace_all, do: count, else: 1)}}
    end
  end

  ## spec 66 T9 — the three line-based passes

  # Ported from `codex-rs/apply-patch/src/seek_sequence.rs:12`: the first pass
  # that matches at all decides, and the replacement is made on the **original**
  # lines, so every byte outside the matched region survives untouched.
  defp fuzzy(content, old, new, replace_all, rel) do
    lines = String.split(content, "\n")
    needle = lines_of(old)

    Enum.reduce_while([:trailing, :indent, :unicode], nil, fn pass, _acc ->
      case find_all(lines, needle, pass) do
        [] -> {:cont, nil}
        positions -> {:halt, {pass, positions}}
      end
    end)
    |> case do
      nil ->
        {:error, not_found(content, old, rel)}

      {pass, [_, _ | _] = positions} when not replace_all ->
        {:error,
         "old_string matches #{length(positions)} places in #{rel} (#{ignoring(pass)}); " <>
           "provide more context or set replace_all=true"}

      {pass, positions} ->
        positions = if replace_all, do: positions, else: [hd(positions)]
        replaced = splice(lines, positions, length(needle), new)
        {:ok, Enum.join(replaced, "\n"), %{pass: pass, count: length(positions)}}
    end
  end

  # spec 67 B7: `String.split("foo()\n", "\n")` is `["foo()", ""]`, so a needle
  # that ends with a newline — which is what models send — used to require the
  # *next* line of the file to be blank before any fuzzy pass could match, and
  # a perfectly unambiguous edit came back "old_string not found". The line a
  # trailing newline terminates is the last line of the pattern, nothing more.
  defp lines_of(text) do
    case String.split(text, "\n") do
      [_ | _] = lines ->
        if String.ends_with?(text, "\n"), do: Enum.drop(lines, -1), else: lines

      lines ->
        lines
    end
  end

  defp ignoring(:trailing), do: "ignoring trailing whitespace"
  defp ignoring(:indent), do: "ignoring indentation"
  defp ignoring(:unicode), do: "after normalising quotes, dashes and spaces"

  # Every start index at which `needle` matches `lines` under `pass`, without
  # overlapping a previous match.
  #
  # spec 73 T19: one walk down the list, testing the needle against the
  # current tail — `Enum.slice(haystack, i, k)` inside a `0..last` loop walked
  # `i` cells per position, O(n²) per pass and three passes, so a 100 000-line
  # file spent minutes on one scheduler before answering "not found".
  defp find_all(lines, needle, pass) do
    k = length(needle)
    haystack = Enum.map(lines, &key(&1, pass))
    wanted = Enum.map(needle, &key(&1, pass))
    last = length(lines) - k

    if last < 0, do: [], else: scan(haystack, wanted, k, 0, last, -1, [])
  end

  defp scan(_tail, _wanted, _k, i, last, _busy_until, found) when i > last,
    do: Enum.reverse(found)

  defp scan([_ | rest] = tail, wanted, k, i, last, busy_until, found) do
    if i > busy_until and List.starts_with?(tail, wanted),
      do: scan(rest, wanted, k, i + 1, last, i + k - 1, [i | found]),
      else: scan(rest, wanted, k, i + 1, last, busy_until, found)
  end

  # The comparison key of one line. The BOM is stripped on both sides (a file
  # saved by an editor that writes one is not a different file), and `\r\n` is
  # `\n` — `String.split/2` on "\n" leaves the `\r` at the end of the line.
  defp key(line, pass) do
    line = line |> strip_bom() |> String.trim_trailing("\r")

    case pass do
      :trailing -> String.trim_trailing(line)
      :indent -> String.trim(line)
      :unicode -> normalise(line)
    end
  end

  defp strip_bom(@bom <> rest), do: rest
  defp strip_bom(line), do: line

  defp normalise(line) do
    line
    |> String.trim()
    |> then(&Enum.reduce(@dashes, &1, fn c, acc -> String.replace(acc, c, "-") end))
    |> then(&Enum.reduce(@squotes, &1, fn c, acc -> String.replace(acc, c, "'") end))
    |> then(&Enum.reduce(@dquotes, &1, fn c, acc -> String.replace(acc, c, "\"") end))
    |> then(&Enum.reduce(@spaces, &1, fn c, acc -> String.replace(acc, c, " ") end))
  end

  # Replaces `k` original lines at each position with the replacement's lines,
  # last position first so the earlier indexes stay valid. The file's own line
  # ending and a leading BOM are kept: a CRLF file stays CRLF instead of gaining
  # one LF line in the middle.
  #
  # spec 67 B7: the replacement loses its own trailing newline for the same
  # reason the needle does (it would insert a blank line after every edit), and
  # an empty `new_string` deletes the matched lines instead of leaving `k`
  # blank ones behind — the exact pass has always deleted them.
  #
  # spec 73 T19: one walk as well — three `Enum.slice`s per position were the
  # same quadratic shape as the old `find_all/3` under `replace_all`.
  defp splice(lines, positions, k, new) do
    do_splice(lines, Enum.sort(positions), k, 0, new, [])
  end

  defp do_splice(rest, [], _k, _i, _new, acc), do: Enum.reverse(acc, rest)

  defp do_splice(lines, [i | positions], k, i, new, acc) do
    {original, rest} = Enum.split(lines, k)
    replacement = if new == "", do: [], else: new |> lines_of() |> keep_shape(original, i)
    do_splice(rest, positions, k, i + k, new, Enum.reverse(replacement, acc))
  end

  defp do_splice([line | rest], positions, k, i, new, acc),
    do: do_splice(rest, positions, k, i + 1, new, [line | acc])

  defp keep_shape(replacement, original, index) do
    replacement =
      if original != [] and Enum.all?(original, &String.ends_with?(&1, "\r")) do
        Enum.map(replacement, fn line ->
          if String.ends_with?(line, "\r"), do: line, else: line <> "\r"
        end)
      else
        replacement
      end

    with 0 <- index,
         [first | _] <- original,
         true <- String.starts_with?(first, @bom),
         [head | tail] <- replacement,
         false <- String.starts_with?(head, @bom) do
      [@bom <> head | tail]
    else
      _ -> replacement
    end
  end

  # spec 66 T9: "not found" used to be the whole message, and the model's only
  # move was to re-read the file. The closest line by token overlap is usually
  # the line it meant, one edit away.
  defp not_found(content, old, rel) do
    base = "old_string not found in #{rel}."
    first = old |> String.split("\n") |> List.first() |> to_string()
    wanted = tokens(first)

    closest =
      if wanted == [] do
        nil
      else
        content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.map(fn {line, n} -> {overlap(tokens(line), wanted), n, line} end)
        |> Enum.max_by(fn {score, _n, _line} -> score end, fn -> {0, 0, ""} end)
      end

    case closest do
      {score, n, line} when score > 0 ->
        base <>
          " The closest line is #{n}: #{clip(line)}. Re-read the file if it changed."

      _none ->
        base <> " Re-read the file if it changed."
    end
  end

  defp tokens(line), do: line |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true) |> Enum.uniq()

  defp overlap(line_tokens, wanted) do
    set = MapSet.new(line_tokens)
    Enum.count(wanted, &MapSet.member?(set, &1))
  end

  defp clip(line) do
    line = String.trim_trailing(line)
    if String.length(line) > 120, do: String.slice(line, 0, 119) <> "…", else: line
  end
end
