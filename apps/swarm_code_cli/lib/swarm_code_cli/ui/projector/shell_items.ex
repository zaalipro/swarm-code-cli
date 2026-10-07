defmodule SwarmCodeCLI.UI.Projector.ShellItems do
  @moduledoc """
  cli020 M2 (C15 + E15): the conversation's `!` shell commands
  (`read_model.shells`, `DTO.ShellItem`, C15) shown as transcript rows.

  C15 keeps shell commands a separate entity (a `TranscriptItem` needs a
  run); E15 draws an item of `kind: :shell` that stands alone. For one
  projection this module gives each shell command a transcript entry of its
  own (`"shell:" <> id`, its own pseudo run), with the text E15 parses
  (`"$ command\\noutput"`) and the exit, placed in the workspace order by
  its time. The read model itself is never changed.
  """

  alias SwarmCodeCLI.UI.DataSource.DTO.{ShellItem, TranscriptItem}

  @prefix "shell:"

  @doc "Whether `id` is one of the projected shell entries."
  def shell_id?(id), do: is_binary(id) and String.starts_with?(id, @prefix)

  @doc "`state` with the shell commands merged into the transcript and its workspace order."
  def merge(%{read_model: %{shells: shells} = model} = state)
      when is_map(shells) and map_size(shells) > 0 do
    items =
      shells
      |> Map.values()
      |> Enum.filter(&match?(%ShellItem{}, &1))
      |> Enum.sort_by(&{&1.at, &1.id})
      |> Enum.map(&item/1)

    transcript = Enum.reduce(items, model.transcript, &Map.put(&2, &1.id, &1))
    # An empty workspace order means "the transcript's ids, sorted" (Turns.order/1).
    order =
      case Map.get(model.order, :workspace, []) do
        [] -> model.transcript |> Map.keys() |> Enum.sort()
        ids -> ids
      end

    order = insert(order, items, model.transcript)

    %{
      state
      | read_model: %{
          model
          | transcript: transcript,
            order: Map.put(model.order, :workspace, order)
        }
    }
  end

  def merge(state), do: state

  defp item(%ShellItem{} = shell) do
    id = @prefix <> shell.id

    text =
      if shell.output == "",
        do: "$ " <> shell.command,
        else: "$ " <> shell.command <> "\n" <> shell.output

    %TranscriptItem{
      id: id,
      run_id: id,
      conversation_id: shell.conversation_id,
      node_id: id,
      revision: shell.revision,
      role: :assistant,
      kind: :shell,
      state: state(shell.state),
      text: text,
      reasoning: "",
      attempt_id: id,
      allowed_actions: [],
      at: shell.at,
      detail_ref: shell.detail_ref
    }
    |> Map.put(:exit, ShellItem.exit(shell))
  end

  defp state(:running), do: :running
  defp state(:done), do: :done
  defp state(:stopped), do: :stopped
  defp state(_failed), do: :failed

  # Each shell entry goes before the first item that arrived after it (by
  # `at`), so a command run between two turns reads between them.
  defp insert(order, items, transcript) do
    Enum.reduce(items, order, fn item, order ->
      if item.id in order do
        order
      else
        {before, rest} =
          Enum.split_while(order, fn id ->
            case Map.get(transcript, id) do
              %{at: at} when is_integer(at) and at > item.at -> false
              _ -> true
            end
          end)

        before ++ [item.id | rest]
      end
    end)
  end
end
