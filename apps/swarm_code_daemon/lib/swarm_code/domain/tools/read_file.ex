defmodule SwarmCode.Domain.Tools.ReadFile do
  @moduledoc "Read a text file from the project."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.Path

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

        {:ok, %{size: size}} ->
          read_content(abs, rel, size, args, progress)
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

        {:ok, format(content, rel, args, progress)}
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
        read_loop(fd, size, read, [data | acc], progress)
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
    remaining = total - (offset - 1) - length(slice)
    progress.(100, "#{total} lines")

    suffix =
      if remaining > 0 do
        "\n…[truncated, #{remaining} more lines; call again with offset=#{offset + length(slice)}]"
      else
        ""
      end

    body = Enum.join(slice, "\n")

    body =
      if String.length(body) > @max_chars do
        String.slice(body, 0, @max_chars) <>
          "\n…[truncated: file has #{total} lines; request a range with offset/limit]"
      else
        body
      end

    "#{rel} (#{total} lines)\n" <> body <> suffix
  end
end
