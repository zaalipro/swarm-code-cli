defmodule SwarmCodeCLI.UI.Projector.Support do
  @moduledoc false
  alias SwarmCodeCLI.UI.{ActionTarget, SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span, Style}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Projector.Density
  def text(value, state, width), do: %Block.Text{text: Density.safe(value, state, width)}
  def chrome(key), do: %Block.Text{text: SafeText.chrome(key)}

  def styled(value, role, state, width),
    do: %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(value, state, width),
          style: Theme.style(role, state.capabilities)
        }
      ]
    }

  def section_heading(value, state, width, role \\ :text_faint),
    do: %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(value, state, width),
          style: %Style{role: role, modifiers: [:bold]}
        }
      ]
    }

  # Chrome glyphs rendered as literal row text (not as a Span style prefix) are not
  # reached by Paint.Blocks.prefix_value/2, so the ASCII form is chosen here, where
  # capabilities are known. Both members of each pair are catalogue chrome.
  @ascii_glyphs %{
    glyph_selected: :glyph_selected_ascii,
    glyph_inactive: :glyph_inactive_ascii,
    glyph_workflows: :glyph_workflows_ascii,
    glyph_research: :glyph_research_ascii,
    glyph_memory: :glyph_memory_ascii,
    glyph_changes: :glyph_changes_ascii,
    composer_gutter: :composer_gutter_ascii,
    pipeline_arrow: :pipeline_arrow_ascii,
    plan_done: :plan_done_ascii
  }

  @doc "Catalogue glyph for the terminal's capabilities; always one cell in both width policies."
  def glyph(token, %{capabilities: %{ascii?: true}}) when is_map_key(@ascii_glyphs, token),
    do: SafeText.chrome(Map.fetch!(@ascii_glyphs, token))

  def glyph(token, _state), do: SafeText.chrome(token)

  def glyphs, do: @ascii_glyphs

  def action(label, target), do: {:projector_action, label, ActionTarget.validate!(target)}

  def action(label, target, style),
    do: {:projector_action, label, ActionTarget.validate!(target), style}

  def allowed?(state, dto, permission) do
    permission in Map.get(dto, :allowed_actions, []) and not pending?(state, dto) and
      not accepted_interaction?(state, dto)
  end

  def pending?(state, dto) do
    Enum.any?(state.mutations, fn {_origin, mutation} ->
      case mutation do
        {:pending, _, intent} -> pending_subject?(dto, intent)
        _ -> false
      end
    end)
  end

  defp accepted_interaction?(state, %DTO.PendingInteraction{id: id, expected_revision: revision}) do
    match?({:settled, _, :accepted}, Map.get(state.mutations, {:interaction, id, revision}))
  end

  defp accepted_interaction?(_, _), do: false
  defp pending_subject?(%DTO.RunSummary{id: id}, {:run_control, _, id}), do: true
  defp pending_subject?(%DTO.RunSummary{id: id}, {:retry_run, id, _}), do: true
  defp pending_subject?(%DTO.RunSummary{id: id}, {:steer, id, _, _, _}), do: true
  defp pending_subject?(%DTO.RunSummary{id: id}, {:mark_seen, :run, id, _}), do: true

  defp pending_subject?(%DTO.AgentSummary{id: id, run_id: run}, {:stop_agent, run, id, _}),
    do: true

  defp pending_subject?(%DTO.TranscriptItem{node_id: id, run_id: run}, {:steer, run, id, _, _}),
    do: true

  defp pending_subject?(%DTO.PendingInteraction{id: id}, {:answer_question, _, _, id, _, _}),
    do: true

  defp pending_subject?(%DTO.PendingInteraction{id: id}, {:resolve_approval, _, _, id, _, _}),
    do: true

  defp pending_subject?(%DTO.ActivityItem{id: id}, {:mark_seen, :activity, id, _}), do: true

  defp pending_subject?(
         %DTO.WorkspaceSnapshot{conversation_id: id},
         {:mark_seen, :conversation, id, _}
       ),
       do: true

  defp pending_subject?(_, _), do: false

  def run(state) do
    case state.destination do
      {:run, id} ->
        Map.get(state.read_model.runs, id)

      {:conversation, id} ->
        state.read_model.runs
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.find_value(fn {_, run} -> if run.conversation_id == id, do: run end)

      :activity ->
        nil
    end
  end

  def finalize(value, revision), do: resolve(value, revision, [], %{})

  defp resolve({:projector_action, label, target, style}, rev, path, table) do
    {block, table} = resolve({:projector_action, label, target}, rev, path, table)

    {%Block.RichText{spans: [%Span{text: label, style: style}], action_id: block.action_id},
     table}
  end

  defp resolve({:projector_action, label, target}, rev, path, table) do
    id =
      :crypto.hash(:sha256, :erlang.term_to_binary({rev, path, target}))
      |> Base.url_encode64(padding: false)

    {%Block.Text{text: label, action_id: id}, Map.put(table, id, target)}
  end

  defp resolve(%SafeText{} = text, _rev, _path, table), do: {text, table}

  defp resolve(%{__struct__: module} = value, rev, path, table) do
    {fields, table} = resolve(Map.from_struct(value), rev, path, table)
    {struct(module, fields), table}
  end

  defp resolve(value, rev, path, table) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({%{}, table}, fn {key, item}, {out, table} ->
      {item, table} = resolve(item, rev, [key | path], table)
      {Map.put(out, key, item), table}
    end)
  end

  defp resolve(value, rev, path, table) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.map_reduce(table, fn {item, i}, table -> resolve(item, rev, [i | path], table) end)
  end

  defp resolve(value, _rev, _path, table), do: {value, table}
end
