defmodule SwarmCodeCLI.UI.Switcher.Entry do
  @moduledoc "Stable switcher catalogue row with a stored semantic target."
  # `title` and `detail` are the two halves of `label` ("Fix login" and
  # "3 runs · live") for a surface that draws them apart; `current?` marks the
  # conversation or model in use.
  # `order` keeps a source's own order among equally good matches (the
  # service lists conversations newest first); 0 for everything else.
  defstruct [
    :id,
    :label,
    :kind,
    :target,
    :title,
    :detail,
    recent?: false,
    current?: false,
    order: 0
  ]

  @type t :: %__MODULE__{}
end

defmodule SwarmCodeCLI.UI.Switcher do
  @moduledoc "Closed-prefix, deterministic switcher over destinations supported by this spike."
  alias SwarmCodeCLI.UI.{
    Drafts,
    Editor,
    FieldEditors,
    ModelPicker,
    MutationState,
    RequestResolver,
    State
  }

  alias SwarmCodeCLI.UI.Reducer.Commands
  alias SwarmCodeCLI.UI.Switcher.Entry
  @kinds [:command, :workflow, :project, :repository, :conversation, :research, :run, :action]
  def open(state, _opener), do: {:switcher, elem(State.next_id(state, :layer), 0)}

  def field_key({kind, id}) when kind in [:switcher, :jump, :action_menu],
    do: {:layer_query, id, kind}

  def field_key({:region_filter, id}), do: {:region_filter, id}
  def field_key({:model_picker, _, _} = layer), do: ModelPicker.field_key(layer)
  def field_key(_), do: nil

  def catalogue(state) do
    local = [
      entry("Activity", :action, {:local, {:navigate, :activity}}, true),
      entry("Help", :action, {:local, {:open_layer, :help}}, true),
      entry("Quit", :action, {:local, {:quit_requested, :detach}}),
      entry("New conversation", :conversation, {:local, :new_conversation}),
      entry("Plain presenter", :action, {:local, {:presenter_handoff_requested, :plain}}),
      entry("Toggle Inspector", :action, {:local, {:toggle_dock, :inspector}}),
      entry("Open visual companion", :action, {:local, :open_companion}),
      vim_mode_entry(state)
    ]

    # Both pickers open on the same next layer id: only one of them ever does.
    models =
      for target <- ModelPicker.targets(),
          do:
            entry(
              ModelPicker.label(target),
              :action,
              {:local, {:open_layer, ModelPicker.open(state, target)}}
            )

    runs = state.read_model.runs |> Map.values() |> Enum.sort_by(& &1.id)

    libraries =
      if state.banner in [:live_banner, :persisted_banner] do
        Enum.map(SwarmCodeCLI.UI.Library.features(), fn feature ->
          entry(
            SwarmCodeCLI.UI.Library.title(feature),
            :action,
            {:local, {:open_layer, {:library, feature}}}
          )
        end)
      else
        []
      end

    local ++
      models ++
      libraries ++
      local_entries(state) ++
      domain_entries(state) ++
      conversation_entries(state) ++
      Enum.map(runs, &entry(run_label(&1), :run, {:local, {:navigate, {:run, &1.id}}}))
  end

  # The project's conversations by title, newest first, as the service listed
  # them; the one on screen is marked rather than offered as a switch.
  # The others come first in the service's order (newest first), then the
  # one on screen, then "New conversation": Enter after /resume opens the
  # most recent other conversation.
  defp conversation_entries(%{conversations: %{items: items}}) when is_list(items) do
    {current, others} = Enum.split_with(items, &(&1.current == true))

    (others ++ current)
    |> Enum.with_index(-1_000)
    |> Enum.map(fn {item, order} ->
      title = conversation_title(item)
      detail = conversation_detail(item)

      %{
        entry(title <> " · " <> detail, :conversation, {:local, {:open_conversation, item.id}})
        | title: title,
          detail: detail,
          current?: item.current == true,
          order: order
      }
    end)
  end

  defp conversation_entries(_state), do: []

  defp conversation_title(%{title: title}) when is_binary(title) do
    case String.trim(title) do
      "" -> "Untitled conversation"
      trimmed -> trimmed
    end
  end

  defp conversation_title(_item), do: "Untitled conversation"

  defp conversation_detail(item) do
    runs =
      case item.run_count do
        1 -> "1 run"
        count -> "#{count} runs"
      end

    [
      runs,
      if(item.live, do: "live"),
      if(is_integer(item.waiting) and item.waiting > 0, do: "#{item.waiting} waiting"),
      if(item.current, do: "open")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp run_label(%{title: title}) when is_binary(title) and title != "",
    do: "Run: " <> String.trim(title)

  defp run_label(_run), do: "Run: untitled"

  def entries(state, table \\ %{}) do
    intents =
      table
      |> Map.values()
      |> Enum.uniq()
      |> Enum.flat_map(fn
        {:intent, intent} = target ->
          [entry(label(intent), :action, target)]

        {:local, action} = target ->
          case local_label(action) do
            nil -> []
            label -> [entry(label, :action, target)]
          end

        _ ->
          []
      end)

    Enum.uniq_by(catalogue(state) ++ intents, & &1.id)
  end

  def visible(state, table \\ %{}) do
    case state.layers do
      [layer | _] ->
        case field_key(layer) do
          nil -> entries(state, table)
          key -> rank(FieldEditors.fetch(state.field_editors, key), entries(state, table))
        end

      _ ->
        entries(state, table)
    end
  end

  def rank(editor, entries) do
    {kinds, query} = prefix(Editor.text(editor))
    query = String.downcase(String.trim(query))

    entries
    |> Enum.filter(&(&1.kind in kinds))
    |> Enum.flat_map(fn entry ->
      label = String.downcase(entry.label)

      score =
        cond do
          query == "" ->
            if(entry.recent?, do: 0, else: 1)

          String.starts_with?(label, query) ->
            0

          Enum.any?(String.split(label), &String.starts_with?(&1, query)) ->
            1

          String.contains?(label, query) or String.contains?(String.downcase(entry.id), query) ->
            2

          true ->
            nil
        end

      if is_nil(score),
        do: [],
        else: [
          {{score, Enum.find_index(@kinds, &(&1 == entry.kind)) || 99, entry.order, label,
            entry.id}, entry}
        ]
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Enum.take(if(query == "", do: 24, else: 512))
  end

  def repair_selection(id, previous_index, entries) do
    cond do
      Enum.any?(entries, &(&1.id == id)) -> id
      entries == [] -> "query"
      true -> Enum.at(entries, min(max(previous_index, 0), length(entries) - 1)).id
    end
  end

  defp local_entries(state) do
    details =
      for item <-
            Map.values(state.read_model.transcript) ++ Map.values(state.read_model.interactions),
          ref <- SwarmCodeCLI.UI.DataSource.DTO.Details.refs(item),
          do: {:open_detail, item.run_id, ref.id}

    inspectors =
      for {id, _} <- state.read_model.runs, do: {:open_layer, {:run_inspector, id, :overview}}

    interactions =
      for {id, item} <- state.read_model.interactions,
          item.state == :pending,
          do: {:open_layer, {item.kind, id}}

    tabs = for tab <- SwarmCodeCLI.UI.Keymap.Bindings.inspector_tabs(), do: {:set_tab, tab}

    # Only the inspector is offered: a "navigator width" command would mutate a
    # preference no pane reads any more.
    layouts =
      for preset <- [:compact, :balanced, :wide],
          do: {:layout_adjust, :inspector, {:preset, preset}}

    Enum.map(
      details ++ inspectors ++ interactions ++ tabs ++ layouts ++ [{:composer_height, :reset}],
      fn action -> entry(local_label(action), :action, {:local, action}) end
    )
  end

  defp local_label({:open_detail, _, _}), do: "Full detail"
  defp local_label({:detail_page, direction}), do: "Detail " <> Atom.to_string(direction)
  defp local_label({:open_layer, {:run_inspector, _, _}}), do: "Inspect run"
  defp local_label({:open_layer, {:question, _}}), do: "Open question"
  defp local_label({:open_layer, {:approval, _}}), do: "Open approval"
  defp local_label({:set_tab, tab}), do: "Tab " <> Atom.to_string(tab)

  defp local_label({:layout_adjust, dock, {:preset, preset}}),
    do: Atom.to_string(dock) <> " width " <> Atom.to_string(preset)

  defp local_label({:composer_height, :reset}), do: "Composer height reset"

  defp local_label({:retry_page, slot, direction}),
    do: "Retry " <> Atom.to_string(slot) <> " " <> Atom.to_string(direction)

  defp local_label(_), do: nil

  defp domain_entries(state) do
    slot = if state.destination == :activity, do: :activity, else: :workspace

    if match?(%{status: :ready}, state.watches[slot]) do
      domain_candidates(state)
      |> Enum.uniq()
      |> Enum.filter(fn intent ->
        with {:ok, context} <- Commands.context(state, intent),
             false <- MutationState.pending?(state.mutations[context.origin]),
             false <-
               match?({:interaction, _, _}, context.origin) and
                 match?({:settled, _, :accepted}, state.mutations[context.origin]),
             :ok <- RequestResolver.authorize(intent, context),
             do: true,
             else: (_ -> false)
      end)
      |> Enum.map(fn intent ->
        kind = if match?({:dispatch, :queue, _, _, _}, intent), do: :command, else: :action
        entry(label(intent), kind, {:intent, intent})
      end)
    else
      []
    end
  end

  defp domain_candidates(state) do
    dispatch =
      case State.current_draft_key(state) do
        nil ->
          []

        key ->
          draft = Drafts.fetch(state.drafts, key)

          if Map.has_key?(state.drafts.pending, key) or
               not Enum.all?(draft.attachments, &(&1.status == :ready)) or
               match?({:invalid, _}, draft.staged_validation) do
            []
          else
            for op <- [:send, :queue],
                do:
                  {:dispatch, op, Editor.text(draft.editor),
                   if(draft.target == :none, do: :main, else: draft.target),
                   Enum.map(draft.attachments, & &1.reference)}
          end
      end

    runs =
      Enum.flat_map(state.read_model.runs, fn {id, run} ->
        [
          {:retry_run, id, run.revision}
          | Enum.map([:pause, :continue, :resume, :stop], &{:run_control, &1, id})
        ]
      end)

    agents =
      Enum.map(state.read_model.agents, fn {id, agent} ->
        {:stop_agent, agent.run_id, id, agent.revision}
      end)

    interactions =
      Enum.flat_map(state.read_model.interactions, fn {id, item} ->
        case item do
          %{state: :pending, kind: :question, question: %{options: options, multiple: multiple}} ->
            choices =
              if multiple,
                do: [Map.get(state.selection, {:question, id}, [])],
                else: Enum.map(options, &[&1.id])

            for choice <- choices,
                choice != [],
                do:
                  {:answer_question, item.run_id, item.node_id, id, item.expected_revision,
                   choice}

          %{state: :pending, kind: :approval} ->
            for decision <- [:approve, :deny, :always_allow],
                do:
                  {:resolve_approval, item.run_id, item.node_id, id, item.expected_revision,
                   decision}

          _ ->
            []
        end
      end)

    dispatch ++ runs ++ agents ++ interactions
  end

  defp prefix("/" <> query), do: {[:command, :workflow], query}
  defp prefix("@" <> query), do: {[:project, :repository], query}
  defp prefix("#" <> query), do: {[:conversation, :research, :run], query}
  defp prefix(">" <> query), do: {[:action], query}
  defp prefix(query), do: {@kinds, query}

  # The one place the vim keymap is switched from inside the shell. The label
  # names the state it is in, the target the state it will be in.
  defp vim_mode_entry(%{keymap: :vim}),
    do: entry("Vim mode: on", :action, {:local, {:set_keymap, :default}})

  defp vim_mode_entry(_state),
    do: entry("Vim mode: off", :action, {:local, {:set_keymap, :vim}})

  defp entry(label, kind, target, recent? \\ false),
    do: %Entry{
      id:
        :crypto.hash(:sha256, :erlang.term_to_binary(target)) |> Base.url_encode64(padding: false),
      label: label,
      kind: kind,
      target: target,
      recent?: recent?
    }

  defp label({:dispatch, :send, _, _, _}), do: "Send"
  defp label({:dispatch, :queue, _, _, _}), do: "Queue"
  defp label({:steer, _, _, _, _}), do: "Steer"

  defp label({:run_control, operation, _}),
    do: String.capitalize(Atom.to_string(operation)) <> " run"

  defp label({:retry_run, _, _}), do: "Retry failed run"
  defp label({:stop_agent, _, _, _}), do: "Stop agent"
  defp label({:answer_question, _, _, _, _, _}), do: "Answer question"

  defp label({:resolve_approval, _, _, _, _, decision}),
    do: String.capitalize(Atom.to_string(decision))

  defp label({:mark_seen, _, _, _}), do: "Mark read"
end
