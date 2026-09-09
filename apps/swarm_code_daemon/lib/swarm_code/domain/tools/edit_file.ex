defmodule SwarmCode.Domain.Tools.EditFile do
  @moduledoc "Replace an exact string in a file."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.AtomicFile
  alias SwarmCode.Domain.Tools.Grep
  alias SwarmCode.Domain.Tools.Path

  # The same ceiling `read_file` refuses at.
  @max_size 5_000_000

  @impl true
  def name, do: "edit_file"

  @impl true
  # Spec 54 §5 (54c H9): the contract, not a one-liner. `old_string` is matched
  # with `:binary.matches/2` — literally, never as a pattern — and the caller
  # cannot see the checkpoint snapshot or the 5 MB refusal from the old text.
  def description,
    do:
      "Replace an exact string in an existing text file, in place. old_string is matched " <>
        "literally, not as a pattern, and must occur exactly once unless replace_all is true; " <>
        "zero matches and (without replace_all) two or more are both errors that change " <>
        "nothing, so include enough surrounding lines to make the match unique. The file must " <>
        "already exist and be text under 5 MB — use write_file for a new file and run_command " <>
        "for a larger one. The write is atomic and snapshotted, so a failed edit leaves the " <>
        "original intact. Returns the number of replacements, not the new content."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path relative to the project root"},
        "old_string" => %{"type" => "string", "description" => "Exact text to replace"},
        "new_string" => %{"type" => "string", "description" => "Replacement text"},
        "replace_all" => %{"type" => "boolean", "description" => "Replace every occurrence"}
      },
      "required" => ["path", "old_string", "new_string"]
    }
  end

  @impl true
  def permission(_args), do: :write

  @impl true
  def title(args), do: "edit " <> (args["path"] || "")

  @impl true
  def run(args, ctx, progress) do
    with {:ok, abs} <- Path.resolve(ctx.project_root, args["path"]) do
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
          read_and_edit(abs, rel, ctx, args, progress)
      end
    end
  end

  defp read_and_edit(abs, rel, ctx, args, progress) do
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
            :ok -> edit(content, ctx.project_root, abs, rel, args, progress)
            {:error, reason} -> {:error, SwarmCode.Domain.Checkpoints.error_message(reason)}
          end
        end
    end
  end

  defp edit(content, root, abs, rel, args, progress) do
    old = args["old_string"]
    replace_all = args["replace_all"] == true

    cond do
      old == "" ->
        {:error, "old_string must not be empty"}

      true ->
        # Spec 51 §7.5 (M9): `String.split/2` materialised every fragment just
        # to count them — a second copy of the file for one integer.
        count = length(:binary.matches(content, old))

        cond do
          count == 0 ->
            {:error, "old_string not found in #{rel}"}

          count > 1 and not replace_all ->
            {:error,
             "old_string matches #{count} places in #{rel}; provide more context or set replace_all=true"}

          # spec 60 T18: the tool's contract is "text under 5 MB" — for the result too.
          projected_size(content, old, args["new_string"], count, replace_all) > @max_size ->
            {:error,
             "edit would grow #{rel} past 5 MB (#{projected_size(content, old, args["new_string"], count, replace_all)} bytes) — use run_command with sed or perl"}

          true ->
            new_content = String.replace(content, old, args["new_string"], global: replace_all)

            # Spec 32 §1: the replacement lands whole or not at all.
            case AtomicFile.replace(root, abs, new_content) do
              :ok ->
                n = if replace_all, do: count, else: 1
                progress.(100, "#{count} replacement(s)")
                {:ok, "edited #{rel}: #{n} replacement(s)"}

              {:error, reason} ->
                {:error, "cannot write #{rel}: #{AtomicFile.format_error(reason)}"}
            end
        end
    end
  end

  # spec 60 T18: the byte size the replacement would produce, without producing it.
  defp projected_size(content, old, new, count, replace_all),
    do:
      byte_size(content) + if(replace_all, do: count, else: 1) * (byte_size(new) - byte_size(old))
end
