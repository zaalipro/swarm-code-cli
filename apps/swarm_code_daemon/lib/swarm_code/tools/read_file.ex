defmodule SwarmCode.Tools.ReadFile do
  @moduledoc "Read a text file from the project."
  @behaviour SwarmCode.Tools.Tool

  alias SwarmCode.Tools.Path

  @chunk 65_536
  @max_size 5_000_000
  # Hard cap on what goes back to the model, whatever the line count is.
  @max_chars 40_000

  @impl true
  def name, do: "read_file"

  @impl true
  # Spec 54 §5 (54c H9): the 40 000-character cap applies whatever `limit` says,
  # and the old text never mentioned it.
  def description,
    do:
      "Read a text file from the project and return its plain content, without line numbers. " <>
        "Files over 5 MB are refused and a directory is an error — use list_dir for those. The " <>
        "result is capped at 40 000 characters whatever the line count is, so page through a " <>
        "long file with offset and limit rather than re-reading it whole."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the project root"},
        "offset" => %{"type" => "integer", "description" => "1-based first line (default 1)"},
        "limit" => %{"type" => "integer", "description" => "Max lines (default 2000, max 5000)"}
      },
      "required" => ["path"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "read " <> (args["path"] || "")

  @impl true
  def run(args, ctx, progress) do
    with {:ok, abs} <- Path.resolve(ctx.project_root, args["path"]) do
      rel = Path.relative(ctx.project_root, abs)

      case File.stat(abs) do
        {:error, :enoent} ->
          {:error, "file not found: " <> rel}

        {:error, reason} ->
          {:error, "cannot read #{rel}: #{reason}"}

        {:ok, %{type: :directory}} ->
          {:error, "#{rel} is a directory"}

        {:ok, %{size: size}} when size > @max_size ->
          {:error, "file too large: #{rel} (#{size} bytes)"}

        {:ok, %{type: :regular, size: size}} ->
          read_content(abs, rel, size, args, progress)

        {:ok, _stat} ->
          {:error, "not a regular file: #{rel}"}
      end
    end
  end

  defp read_content(abs, rel, size, args, progress) do
    case File.open(abs, [:read, :binary]) do
      {:error, reason} ->
        {:error, "cannot read #{rel}: #{reason}"}

      {:ok, fd} ->
        content =
          try do
            read_loop(fd, size, 0, [], progress)
          after
            File.close(fd)
          end

        if String.valid?(content) and not String.contains?(content, <<0>>) do
          {:ok, format(content, rel, args, progress)}
        else
          {:error, "cannot read a binary file: #{rel}"}
        end
    end
  end

  defp read_loop(fd, size, read, acc, progress) do
    case IO.binread(fd, @chunk) do
      :eof ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      {:error, _reason} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()

      data ->
        read = read + byte_size(data)
        pct = min(99, div(read * 100, max(size, 1)))
        progress.(pct, "#{pct}%")

        if read > @max_size do
          throw(:file_grew_too_large)
        else
          read_loop(fd, size, read, [data | acc], progress)
        end
    end
  end

  defp format(content, rel, args, progress) do
    lines = String.split(content, "\n")

    lines =
      if String.ends_with?(content, "\n") and lines != [] do
        Enum.drop(lines, -1)
      else
        lines
      end

    total = length(lines)
    offset = max(args["offset"] || 1, 1)
    limit = args["limit"] || 2000
    limit = limit |> max(1) |> min(5000)
    slice = Enum.slice(lines, offset - 1, limit)
    progress.(100, "#{total} lines")

    "#{rel} (#{total} lines)\n" <> page(slice, offset, total)
  end

  # spec 74 BUGS-44: the resume offset was computed from the `limit` slice
  # *before* the character cap cut the body, so a 3 000-line file came back
  # ending at line 800 with "call again with offset=2001" — a model following
  # the hint never read lines 801–2000. Whole lines are taken while the body
  # stays within `@max_chars`, and the one suffix is built from the lines
  # actually returned.
  defp page([], _offset, _total), do: ""

  defp page([first | _] = slice, offset, total) do
    case take_lines(slice) do
      [] ->
        # One line longer than the whole cap: its head, and the next line.
        chars = String.length(first)

        String.slice(first, 0, @max_chars) <>
          suffix(
            offset,
            offset,
            total,
            " (line #{offset} cut at #{@max_chars} of #{chars} characters)"
          )

      taken ->
        last = offset + length(taken) - 1
        Enum.join(taken, "\n") <> suffix(offset, last, total, "")
    end
  end

  defp take_lines(slice) do
    slice
    |> Enum.reduce_while({[], 0}, fn line, {acc, chars} ->
      chars = chars + String.length(line) + if(acc == [], do: 0, else: 1)
      if chars <= @max_chars, do: {:cont, {[line | acc], chars}}, else: {:halt, {acc, chars}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp suffix(_first, last, total, "") when last >= total, do: ""

  defp suffix(first, last, total, note) when last >= total,
    do: "\n…[showing lines #{first}-#{last} of #{total}#{note}]"

  defp suffix(first, last, total, note),
    do:
      "\n…[showing lines #{first}-#{last} of #{total}#{note}; call again with offset=#{last + 1}]"
end
