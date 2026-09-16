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
    plan_done: :plan_done_ascii,
    glyph_failed: :glyph_failed_ascii,
    stripe: :stripe_ascii,
    stripe_off: :stripe_off_ascii,
    corner_tl: :corner_tl_ascii,
    corner_tr: :corner_tr_ascii,
    corner_bl: :corner_bl_ascii,
    corner_br: :corner_br_ascii,
    seg_on: :seg_on_ascii,
    seg_off: :seg_off_ascii,
    rule: :rule_ascii,
    dot_small: :dot_small_ascii,
    dot: :dot_ascii,
    agent_lead: :agent_lead_ascii,
    agent_sub: :agent_sub_ascii,
    assistant_mark: :assistant_mark_ascii,
    kind_swarm_mark: :kind_swarm_mark_ascii,
    kind_consensus_mark: :kind_consensus_mark_ascii,
    kind_plan: :kind_plan_ascii,
    close_mark: :close_mark_ascii,
    settings_mark: :settings_mark_ascii,
    logo_mark: :logo_mark_ascii,
    search_mark: :search_mark_ascii,
    branch_mark: :branch_mark_ascii,
    retry_mark: :retry_mark_ascii,
    enter_key: :enter_key_ascii,
    check_mark: :check_mark_ascii,
    chevron: :chevron_ascii,
    write_mark: :write_mark_ascii,
    clock_mark: :clock_mark_ascii,
    effort_mark: :effort_mark_ascii,
    shield_mark: :shield_mark_ascii,
    usage_mark: :usage_mark_ascii,
    hex_full: :hex_full_ascii,
    hex_empty: :hex_empty_ascii,
    judge: :judge_ascii,
    caret: :caret_ascii,
    collapsed: :collapsed_ascii,
    expanded: :expanded_ascii,
    check: :check_ascii,
    fail: :fail_ascii,
    gauge_on: :gauge_on_ascii,
    gauge_off: :gauge_off_ascii,
    waiting: :waiting_ascii
  }

  @doc "Catalogue glyph for the terminal's capabilities; always one cell in both width policies."
  def glyph(token, %{capabilities: %{ascii?: true}}) when is_map_key(@ascii_glyphs, token),
    do: SafeText.chrome(Map.fetch!(@ascii_glyphs, token))

  def glyph(token, _state), do: SafeText.chrome(token)

  def glyphs, do: @ascii_glyphs

  def action(label, target), do: {:projector_action, label, ActionTarget.validate!(target)}

  def action(label, target, style),
    do: {:projector_action, label, ActionTarget.validate!(target), style}

  @doc """
  A clickable row built from already-styled spans.

  `action/3` collapses its label into a single span, which cannot express a row
  whose segments carry different roles (a kind-coloured title beside a
  status-coloured word beside a two-tone gauge). This keeps the spans and still
  resolves to one opaque action id for the whole line.
  """
  def action_spans(spans, target) when is_list(spans),
    do: {:projector_action_spans, spans, ActionTarget.validate!(target)}

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

      # The newest run is the conversation's current one: it is where the
      # message just sent went and where the reply will stream. Picking the
      # lowest id, as this used to, kept the transcript on the first run for
      # ever and put every reply into a tab the user was not looking at. Both
      # data sources fill `created_sequence`; the id breaks ties.
      {:conversation, id} ->
        state.read_model.runs
        |> Map.values()
        |> Enum.filter(&(&1.conversation_id == id))
        |> Enum.max_by(&{&1.created_sequence, &1.id}, fn -> nil end)

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

  defp resolve({:projector_action_spans, spans, target}, rev, path, table) do
    id =
      :crypto.hash(:sha256, :erlang.term_to_binary({rev, path, target}))
      |> Base.url_encode64(padding: false)

    {spans, table} = resolve(spans, rev, path, Map.put(table, id, target))
    {%Block.RichText{spans: spans, action_id: id}, table}
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
