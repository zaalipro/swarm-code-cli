defmodule SwarmCode.Domain.Tools.EditFiles do
  @moduledoc """
  Apply exact-match edits across several files in one all-or-nothing call.
  # spec 70 C5
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.AtomicFile
  alias SwarmCode.Domain.Tools.{EditFile, Grep, Path}

  @max_size 5_000_000

  @impl true
  def name, do: "edit_files"

  @impl true
  def description,
    do:
      "Edit several files in one atomic call. Each entry names a file and " <>
        "its edits (old_string/new_string or an edits array, same format " <>
        "as edit_file). All files are checked and edited in memory first; " <>
        "if any edit in any file fails, nothing is written. Use this for " <>
        "cross-file renames and coordinated changes."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "files" => %{
          "type" => "array",
          "description" => "One entry per file to edit.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string",
                "description" => "Path relative to the project root"
              },
              "old_string" => %{"type" => "string"},
              "new_string" => %{"type" => "string"},
              "replace_all" => %{"type" => "boolean"},
              "edits" => %{
                "type" => "array",
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
            "required" => ["path"]
          }
        }
      },
      "required" => ["files"]
    }
  end

  @impl true
  def permission(_args), do: :write

  # spec 70 C5: two edits of multiple files must not run concurrently.
  @impl true
  def parallel?, do: false

  @impl true
  def title(args) do
    count = length(args["files"] || [])
    "edit #{count} file#{if count == 1, do: "", else: "s"}"
  end

  @impl true
  def run(args, ctx, progress) do
    files = args["files"]

    cond do
      not is_list(files) or files == [] ->
        {:error, "edit_files needs a non-empty files array"}

      true ->
        do_run(files, ctx, progress)
    end
  end

  # spec 70 C5: validate, read, edit in memory, then write all.
  defp do_run(file_entries, ctx, progress) do
    root = ctx.project_root

    # Phase 1: validate and edit all files in memory.
    result =
      file_entries
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {entry, i}, {:ok, acc} ->
        case prepare_file(entry, i, length(file_entries), root, ctx) do
          {:ok, prepared} -> {:cont, {:ok, [prepared | acc]}}
          {:error, msg} -> {:halt, {:error, msg}}
        end
      end)

    case result do
      {:error, msg} ->
        {:error, msg}

      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)

        # Phase 2: check that no edited content exceeds the size limit.
        # spec 73 T20: and that no file is listed twice — each entry was
        # edited from the file as read, so the second write of one path
        # replaced the first entry's result while the summary counted both.
        case duplicate_target(prepared) do
          nil ->
            check_sizes_and_write(prepared, root, progress)

          duplicate ->
            {:error,
             "#{duplicate} appears twice in files — put both edits in one entry's edits array"}
        end
    end
  end

  defp check_sizes_and_write(prepared, root, progress) do
    case Enum.find(prepared, fn p -> byte_size(p.new_content) > @max_size end) do
      %{rel: rel, new_content: content} ->
        {:error,
         "edit would grow #{rel} past 5 MB (#{byte_size(content)} bytes) — " <>
           "use run_command with sed or perl"}

      nil ->
        # Phase 3: write all files atomically.
        write_all(prepared, root, progress)
    end
  end

  defp duplicate_target(prepared) do
    prepared
    |> Enum.frequencies_by(& &1.abs)
    |> Enum.find_value(fn {abs, n} ->
      if n > 1, do: Enum.find_value(prepared, &(&1.abs == abs and &1.rel))
    end)
  end

  defp prepare_file(entry, index, total, root, ctx) do
    with {:ok, edits} <- parse_edits(entry, index, total),
         {:ok, abs} <- Path.resolve_write(root, entry["path"]) do
      rel = Path.relative(root, abs)

      case File.stat(abs) do
        {:error, :enoent} ->
          {:error, file_error(index, total, "file not found: #{rel}")}

        {:error, reason} ->
          {:error, file_error(index, total, "cannot read #{rel}: #{reason}")}

        {:ok, %{size: size}} when size > @max_size ->
          {:error,
           file_error(
             index,
             total,
             "file too large to edit: #{rel} (#{size} bytes)"
           )}

        {:ok, _stat} ->
          read_and_prepare(abs, rel, ctx, edits, index, total)
      end
    end
  end

  defp read_and_prepare(abs, rel, ctx, edits, index, total) do
    case File.read(abs) do
      {:error, :enoent} ->
        {:error, file_error(index, total, "file not found: #{rel}")}

      {:error, reason} ->
        {:error, file_error(index, total, "cannot read #{rel}: #{reason}")}

      {:ok, content} ->
        if Grep.binary?(content) do
          {:error, file_error(index, total, "cannot edit a binary file: #{rel}")}
        else
          case SwarmCode.Domain.Checkpoints.snapshot(ctx, abs) do
            :ok ->
              apply_in_memory(content, rel, abs, edits, index, total)

            {:error, reason} ->
              {:error,
               file_error(index, total, SwarmCode.Domain.Checkpoints.error_message(reason))}
          end
        end
    end
  end

  defp apply_in_memory(content, rel, abs, edits, index, total) do
    case EditFile.apply_edits(content, edits, rel) do
      {:ok, new_content, applied} ->
        count = Enum.sum(Enum.map(applied, & &1.count))
        {:ok, %{abs: abs, rel: rel, new_content: new_content, count: count}}

      {:error, msg} ->
        {:error, file_error(index, total, msg)}
    end
  end

  defp write_all(prepared, root, progress) do
    errors =
      for %{abs: abs, rel: rel, new_content: content} <- prepared,
          {:error, reason} <- [AtomicFile.replace(root, abs, content)] do
        "cannot write #{rel}: #{AtomicFile.format_error(reason)}"
      end

    if errors != [] do
      {:error, Enum.join(errors, "; ")}
    else
      total_replacements = Enum.sum(Enum.map(prepared, & &1.count))
      count = length(prepared)
      progress.(100, "#{count} file(s)")

      summary =
        prepared
        |> Enum.map(fn p -> "#{p.rel} (#{p.count})" end)
        |> Enum.join(", ")

      {:ok,
       "edited #{count} file#{if count == 1, do: "", else: "s"}" <>
         " (#{total_replacements} replacement(s)): #{summary}"}
    end
  end

  # Prefix errors with file index when there are multiple files.
  defp file_error(_, 1, msg), do: msg
  defp file_error(i, n, msg), do: "file #{i} of #{n}: #{msg}"

  # Parse edits from a file entry, same logic as EditFile.edits/1.
  defp parse_edits(entry, index, total) do
    list = entry["edits"]
    single? = is_binary(entry["old_string"]) or is_binary(entry["new_string"])

    cond do
      is_list(list) and list != [] and single? ->
        {:error, file_error(index, total, "pass either old_string/new_string or edits, not both")}

      is_list(list) and list != [] ->
        case Enum.find_index(list, &(not edit?(&1))) do
          nil ->
            {:ok, Enum.map(list, &normalise_edit/1)}

          i ->
            {:error, file_error(index, total, "edit #{i + 1}: needs old_string and new_string")}
        end

      single? and is_binary(entry["old_string"]) and is_binary(entry["new_string"]) ->
        {:ok, [normalise_edit(entry)]}

      true ->
        {:error,
         file_error(
           index,
           total,
           "each file entry needs old_string and new_string, or a non-empty edits array"
         )}
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
end
