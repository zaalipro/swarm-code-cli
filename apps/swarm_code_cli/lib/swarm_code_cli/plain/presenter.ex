defmodule SwarmCodeCLI.Plain.Presenter do
  @moduledoc "Bounded append-only presentation facts. No IO, terminal mode or request side effects."
  alias SwarmCodeCLI.Plain.Options
  alias SwarmCodeCLI.UI.{SafeText, RequestResolver}
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}
  alias RequestResolver.Context

  @derive {Inspect, only: [:status, :generation]}
  defstruct options: %Options{},
            scope: nil,
            inspector_tab: :overview,
            generation: 0,
            source_epoch: nil,
            status: :connecting,
            runs: %{},
            agents: %{},
            nodes: %{},
            interactions: %{},
            conversations: %{},
            activities: %{},
            current_prompt: nil,
            target_catalogue: MapSet.new(),
            detail_refs: %{},
            staged_refs: [],
            allowed_actions: [],
            sequences: %{},
            delivered: MapSet.new(),
            delivered_order: [],
            retired_epochs: []

  @type t :: %__MODULE__{}
  @type output_record :: {:stdout | :stderr, iodata()}
  @limit 256
  def new(%Options{} = options), do: %__MODULE__{options: options}

  def focus_scope(p, scope) do
    changed? = p.scope != nil and {p.scope.kind, p.scope.id} != {scope.kind, scope.id}
    p = if changed?, do: %{p | interactions: %{}, current_prompt: nil}, else: p
    %{p | scope: scope, generation: scope.generation, status: :connecting}
  end

  def inspector_tab(p, tab) when tab in [:overview, :agents, :timeline, :changes],
    do: %{p | inspector_tab: tab}

  def present(%__MODULE__{} = p, epoch, %Delivery{} = delivery)
      when is_binary(epoch) and byte_size(epoch) in 1..256 do
    with {:ok, _} <- Delivery.validate(delivery),
         false <- epoch in p.retired_epochs,
         false <- stale?(p, epoch, delivery),
         false <- duplicate?(p, epoch, delivery) do
      p =
        if p.source_epoch != nil and p.source_epoch != epoch,
          do: %{
            new(p.options)
            | retired_epochs: Enum.take([p.source_epoch | p.retired_epochs], 32)
          },
          else: p

      p = %{p | source_epoch: epoch}

      p =
        if delivery.kind in [:watch_ready, :response] and delivery.scope.kind != :global,
          do: %{p | scope: delivery.scope, generation: delivery.generation},
          else: p

      p =
        if p.scope == nil,
          do: %{p | scope: delivery.scope, generation: delivery.generation},
          else: p

      p = remember(p, epoch, delivery)
      {p, records} = apply_delivery(p, delivery)
      # Each retained transcript can expose text and reasoning, and each
      # interaction can expose arguments. Derive this bounded index from the
      # retained facts so an advertised link cannot be evicted independently.
      refs =
        for item <- Map.values(p.nodes) ++ Map.values(p.interactions),
            ref <- DTO.Details.refs(item),
            into: %{},
            do: {ref.id, ref}

      p = %{p | detail_refs: refs}
      p = select_prompt(p)

      {p,
       render_records(
         records ++ if(records == [], do: [], else: raw_prompt_records(p)),
         p.options
       )}
    else
      _ -> {p, []}
    end
  end

  def present(p, _, _), do: {p, []}

  def prompt_records(p), do: render_records(raw_prompt_records(p), p.options)

  defp raw_prompt_records(%{status: status}) when status in [:resyncing, :closed], do: []
  defp raw_prompt_records(%{current_prompt: nil}), do: []

  defp raw_prompt_records(%{current_prompt: %DTO.PendingInteraction{} = item}) do
    reference = item.id <> "@" <> Integer.to_string(item.expected_revision)

    case item.kind do
      :question ->
        options = if item.question, do: item.question.options, else: []

        [
          record([
            "QUESTION ",
            reference,
            " ",
            if(item.question, do: item.question.prompt, else: "")
          ])
        ] ++
          Enum.map(Enum.with_index(options, 1), fn {option, index} ->
            record([Integer.to_string(index), ". ", option.id, " ", option.label])
          end) ++
          [
            record([
              "answer ",
              reference,
              " ",
              Enum.map_join(Enum.take(options, 1), " ", & &1.id)
            ])
          ]

      :approval ->
        commands = Enum.filter([:approve, :deny, :always_allow], &(&1 in item.allowed_actions))

        [record(["APPROVAL ", reference])] ++
          approval_records(item) ++
          Enum.map(commands, fn command -> record([approval_verb(command), " ", reference]) end)
    end
  end

  defp approval_records(%{approval: nil}), do: []

  defp approval_records(%{approval: approval}) do
    [
      record(["TOOL ", approval.tool, " ", Atom.to_string(approval.permission)]),
      record(["ARGUMENTS ", approval.arguments_preview])
    ] ++
      if(approval.arguments_detail_ref,
        do: [record(["detail ", approval.arguments_detail_ref.id])],
        else: []
      )
  end

  def context(%__MODULE__{} = p, intent, scope) do
    if p.status != :ready or p.scope == nil or scope != p.scope do
      {:error, :invalid_context}
    else
      base = %Context{
        scope: scope,
        scope_generation: p.generation,
        origin: {:run, "invalid"},
        active_run_id: nil,
        active_run_state: nil,
        active_node_id: nil,
        active_agent_id: nil,
        subject_revision: nil,
        interaction: nil,
        editor_text: "",
        dispatch_target: :main,
        attachment_refs: [],
        allowed_actions: []
      }

      with {:ok, context} <- context_subject(p, intent, base),
           do:
             Context.validate(%{
               context
               | allowed_actions:
                   Enum.filter(context.allowed_actions, &SwarmCodeCLI.UI.Intent.permission?/1)
             })
    end
  end

  defp context_subject(p, {:dispatch, _, text, target, refs}, c) do
    conversation = if c.scope.kind == :conversation, do: c.scope.id, else: nil

    if conversation && Map.has_key?(p.conversations, conversation),
      do:
        {:ok,
         %{
           c
           | origin: {:draft, {conversation, :main}},
             editor_text: text,
             dispatch_target: target,
             attachment_refs: refs,
             allowed_actions: p.allowed_actions
         }},
      else: {:error, :invalid_context}
  end

  defp context_subject(p, {:steer, run, node, text, refs}, c) do
    with %DTO.RunSummary{id: ^run} = r <- p.runs[run],
         true <- subject_scope?(c.scope, run, r.conversation_id),
         %DTO.TranscriptItem{run_id: ^run, node_id: ^node} = n <- p.nodes[{run, node}],
         true <- n.state != :superseded and n.conversation_id == r.conversation_id do
      {:ok,
       %{
         c
         | origin: {:draft, {r.conversation_id, :main}},
           active_run_id: run,
           active_run_state: r.state,
           active_node_id: node,
           editor_text: text,
           attachment_refs: refs,
           allowed_actions: r.allowed_actions
       }}
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp context_subject(p, {:run_control, _, run}, c), do: run_context(p, run, c, {:run, run}, nil)

  defp context_subject(p, {:retry_run, run, revision}, c),
    do: run_context(p, run, c, {:run_revision, run, revision}, :revision)

  defp context_subject(p, {:stop_agent, run, agent, _}, c) do
    with %DTO.RunSummary{id: ^run} = r <- p.runs[run],
         true <- subject_scope?(c.scope, run, r.conversation_id),
         %DTO.AgentSummary{id: ^agent, run_id: ^run} = a <- p.agents[{run, agent}] do
      {:ok,
       %{
         c
         | origin: {:agent, run, agent, a.revision},
           active_run_id: run,
           active_run_state: r.state,
           active_agent_id: agent,
           subject_revision: a.revision,
           allowed_actions: a.allowed_actions
       }}
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp context_subject(p, {kind, run, node, id, _, _}, c)
       when kind in [:answer_question, :resolve_approval] do
    with %DTO.PendingInteraction{state: :pending, run_id: ^run, node_id: ^node} = i <-
           p.interactions[id],
         true <- subject_scope?(c.scope, run, i.conversation_id),
         {:ok, run_state} <- interaction_run_state(p, i) do
      {:ok,
       %{
         c
         | origin: {:interaction, id, i.expected_revision},
           active_run_id: run,
           active_run_state: run_state,
           active_node_id: node,
           interaction: {i.kind, run, node, id, i.expected_revision},
           allowed_actions: i.allowed_actions
       }}
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp context_subject(p, {:mark_seen, kind, id, _}, c) do
    table =
      case kind do
        :conversation -> p.conversations
        :run -> p.runs
        :activity -> p.activities
      end

    with %{revision: revision, allowed_actions: actions} = subject <- table[id],
         true <- seen_scope?(c.scope, kind, id, subject) do
      {:ok, %{c | origin: {:seen, kind, id, revision}, allowed_actions: actions}}
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp context_subject(_, _, _), do: {:error, :invalid_context}

  defp interaction_run_state(p, interaction) do
    case p.runs[interaction.run_id] do
      %DTO.RunSummary{} = run ->
        if run.id == interaction.run_id and run.conversation_id == interaction.conversation_id,
          do: {:ok, run.state},
          else: {:error, :invalid_context}

      nil ->
        expected_state =
          if interaction.kind == :question, do: :waiting_question, else: :waiting_approval

        found =
          Enum.any?(p.activities, fn {_id, item} ->
            item.kind == interaction.kind and item.state == expected_state and
              item.run_id == interaction.run_id and
              item.conversation_id == interaction.conversation_id and
              match?(%DTO.PendingInteraction{}, item.interaction) and
              item.interaction.id == interaction.id and
              item.interaction.run_id == interaction.run_id and
              item.interaction.node_id == interaction.node_id and
              item.interaction.kind == interaction.kind and
              item.interaction.conversation_id == interaction.conversation_id and
              item.interaction.expected_revision == interaction.expected_revision and
              item.interaction.state == :pending
          end)

        if found, do: {:ok, expected_state}, else: {:error, :invalid_context}

      _ ->
        {:error, :invalid_context}
    end
  end

  defp run_context(p, run, c, origin, revision) do
    with %DTO.RunSummary{id: ^run} = r <- p.runs[run],
         true <- subject_scope?(c.scope, run, r.conversation_id) do
      {:ok,
       %{
         c
         | origin: origin,
           active_run_id: run,
           active_run_state: r.state,
           subject_revision: if(revision, do: r.revision),
           allowed_actions: r.allowed_actions
       }}
    else
      _ -> {:error, :invalid_context}
    end
  end

  defp subject_scope?(%{kind: :global}, _, _), do: true
  defp subject_scope?(%{kind: :run, id: run}, run, _), do: true
  defp subject_scope?(%{kind: :conversation, id: conversation}, _, conversation), do: true
  defp subject_scope?(_, _, _), do: false

  defp seen_scope?(%{kind: :conversation, id: id}, :conversation, id, _), do: true
  defp seen_scope?(_, :conversation, _, _), do: false

  defp seen_scope?(scope, :run, id, %DTO.RunSummary{id: id} = run),
    do: subject_scope?(scope, id, run.conversation_id)

  defp seen_scope?(scope, :activity, id, %DTO.ActivityItem{id: id} = item),
    do: subject_scope?(scope, item.run_id, item.conversation_id)

  defp seen_scope?(_, _, _, _), do: false

  defp stale?(%{source_epoch: epoch} = p, epoch, d) do
    key = {d.scope.kind, d.scope.id}

    older_generation =
      Enum.any?(p.sequences, fn {{_, kind, id, gen, _}, _} ->
        {kind, id} == key and gen > d.generation
      end)

    older_generation or
      (d.kind == :delta and d.sequence <= Map.get(p.sequences, sequence_key(epoch, d), -1))
  end

  defp stale?(_, _, %{kind: :delta}), do: true
  defp stale?(_, _, _), do: false
  defp sequence_key(epoch, d), do: {epoch, d.scope.kind, d.scope.id, d.generation, d.watch_ref}

  defp delivery_key(epoch, d),
    do: {sequence_key(epoch, d), d.kind, d.sequence, d.revision, d.request_id, d.watch_ref}

  defp duplicate?(%{status: :resyncing}, _, %{kind: :watch_ready}), do: false
  defp duplicate?(p, epoch, d), do: MapSet.member?(p.delivered, delivery_key(epoch, d))

  defp remember(p, epoch, d) do
    key = delivery_key(epoch, d)
    order = Enum.take([key | p.delivered_order], 512)

    sequence =
      d.sequence || if(is_map(d.body), do: Map.get(d.body, :through_sequence, 0), else: 0)

    sequences =
      put_bounded(
        p.sequences,
        sequence_key(epoch, d),
        max(sequence, Map.get(p.sequences, sequence_key(epoch, d), 0))
      )

    %{p | delivered: MapSet.new(order), delivered_order: order, sequences: sequences}
  end

  defp apply_delivery(p, %{kind: :resyncing}),
    do: {%{p | status: :resyncing}, [record("RESYNCING")]}

  defp apply_delivery(p, %{kind: :closed}), do: {%{p | status: :closed}, [record("CLOSED")]}
  defp apply_delivery(p, %{kind: :error}), do: {p, [record("Data source error.", :stderr)]}
  defp apply_delivery(p, %{kind: :watch_ready, body: body}), do: body(%{p | status: :ready}, body)

  defp apply_delivery(p, %{kind: :response, body: %module{} = body})
       when module in [
              DTO.WorkspaceSnapshot,
              DTO.RunDetailSnapshot,
              DTO.TranscriptWindow,
              DTO.PendingInteractionWindow,
              DTO.ActivitySnapshot,
              DTO.ShellSnapshot
            ],
       do: body(%{p | status: :ready}, body)

  defp apply_delivery(p, %{body: body}), do: body(p, body)

  defp body(p, %DTO.WorkspaceSnapshot{} = snapshot) do
    settled = removed_prompts(p, snapshot.interactions)

    p = %{
      p
      | runs: %{},
        interactions: %{},
        nodes: %{},
        target_catalogue: MapSet.new(),
        detail_refs: %{},
        allowed_actions: snapshot.allowed_actions
    }

    p =
      if snapshot.conversation_id,
        do: %{
          p
          | conversations:
              put_bounded(p.conversations, snapshot.conversation_id, %{
                revision: snapshot.revision,
                allowed_actions: snapshot.allowed_actions
              })
        },
        else: p

    {p, records} =
      reduce_bodies(p, snapshot.runs ++ [snapshot.transcript] ++ snapshot.interactions)

    {p, settled ++ records}
  end

  defp body(p, %DTO.ShellSnapshot{} = s), do: reduce_bodies(p, s.runs)

  defp body(p, %DTO.RunDetailSnapshot{} = s) do
    # Retain all admitted facts for exact command authorization; tabs choose
    # which records are displayed without inventing absent change DTOs.
    {p, run_records} = reduce_bodies(%{p | agents: %{}}, [s.run])
    {p, text_records} = reduce_bodies(p, [s.transcript])
    {p, agent_records} = reduce_bodies(p, s.agents)

    records =
      case p.inspector_tab do
        :overview -> text_records ++ agent_records
        :agents -> agent_records
        :timeline -> text_records
        :changes -> [record("Change data is unavailable in this synthetic source.")]
      end

    {p, [record(["INSPECTOR ", Atom.to_string(p.inspector_tab)])] ++ run_records ++ records}
  end

  defp body(p, %DTO.TranscriptWindow{} = s), do: reduce_bodies(p, s.items)

  defp body(p, %DTO.PendingInteractionWindow{} = s) do
    settled = removed_prompts(p, s.items)
    {p, records} = reduce_bodies(%{p | interactions: %{}}, s.items)
    {p, settled ++ records}
  end

  defp body(p, %DTO.ActivitySnapshot{} = s) do
    prompts =
      Enum.flat_map(s.items, fn item -> if item.interaction, do: [item.interaction], else: [] end)

    full_coverage? = s.presence == :covered and s.before_cursor == nil and s.after_cursor == nil
    settled = if full_coverage?, do: removed_prompts(p, prompts), else: []

    {p, records} =
      reduce_bodies(%{p | activities: %{}, interactions: %{}, current_prompt: nil}, s.items)

    {p, settled ++ records}
  end

  defp body(p, %DTO.RunSummary{} = r) do
    conversations =
      if Map.has_key?(p.conversations, r.conversation_id),
        do: p.conversations,
        else: put_bounded(p.conversations, r.conversation_id, %{revision: 0, allowed_actions: []})

    {%{p | runs: put_bounded(p.runs, r.id, r), conversations: conversations},
     [
       record([
         "RUN ",
         r.id,
         "@",
         Integer.to_string(r.revision),
         " ",
         Atom.to_string(r.state),
         " ",
         r.title
       ])
     ]}
  end

  defp body(p, %DTO.AgentSummary{} = a),
    do:
      {%{p | agents: put_bounded(p.agents, {a.run_id, a.id}, a)},
       [
         record([
           "AGENT ",
           a.run_id,
           "/",
           a.id,
           "@",
           Integer.to_string(a.revision),
           " ",
           Atom.to_string(a.state)
         ])
       ]}

  defp body(p, %DTO.TranscriptItem{} = n) do
    targets =
      Enum.reduce(
        [{:reply, n.node_id}, {:thread, n.node_id}, {:revise, n.node_id}],
        p.target_catalogue,
        &MapSet.put(&2, &1)
      )
      |> Enum.take(@limit)
      |> MapSet.new()

    details = Enum.reduce(DTO.Details.refs(n), p.detail_refs, &put_bounded(&2, &1.id, &1))

    preview =
      if n.detail_ref,
        do: [
          " (preview; detail ",
          n.detail_ref.id,
          "; total ",
          Integer.to_string(n.detail_ref.total_bytes),
          " bytes)"
        ],
        else: []

    {%{
       p
       | nodes: put_bounded(p.nodes, {n.run_id, n.node_id}, n),
         target_catalogue: targets,
         detail_refs: details
     },
     [record(["TEXT ", n.run_id, "/", n.node_id] ++ preview ++ [" ", n.text])] ++
       if(n.reasoning_detail_ref,
         do: [record(["REASONING preview; detail ", n.reasoning_detail_ref.id])],
         else: []
       ) ++
       if(n.reasoning == "",
         do: [],
         else: [record(["REASONING ", n.run_id, "/", n.node_id, " ", n.reasoning])]
       )}
  end

  defp body(p, %DTO.PendingInteraction{state: :resolved} = i),
    do:
      {%{p | interactions: Map.delete(p.interactions, i.id)},
       [record(["SETTLED ", i.id, "@", Integer.to_string(i.expected_revision)])]}

  defp body(p, %DTO.PendingInteraction{} = i) do
    previous = p.interactions[i.id]

    records =
      if previous && previous.expected_revision != i.expected_revision,
        do: [record(["SETTLED ", i.id, "@", Integer.to_string(previous.expected_revision)])],
        else: []

    refs = Enum.reduce(DTO.Details.refs(i), p.detail_refs, &put_bounded(&2, &1.id, &1))

    {%{p | interactions: put_bounded(p.interactions, i.id, i), detail_refs: refs},
     records ++ [record(["PENDING ", i.id, "@", Integer.to_string(i.expected_revision)])]}
  end

  defp body(p, %DTO.ActivityItem{} = a) do
    {p, extra} = body(%{p | activities: put_bounded(p.activities, a.id, a)}, a.interaction)

    {p,
     [
       record([
         "ACTIVITY ",
         a.id,
         "@",
         Integer.to_string(a.revision),
         " ",
         Atom.to_string(a.state),
         " ",
         a.title
       ])
       | extra
     ]}
  end

  defp body(p, %DTO.Outcome{} = o) do
    {p, records} = body(p, o.interaction)
    {p, [record(["OUTCOME ", o.request_id, " ", Atom.to_string(o.status)]) | records]}
  end

  defp body(p, %DTO.DetailWindow{state: :error}),
    do: {p, [record("Detail could not be loaded; use detail retry.", :stderr)]}

  defp body(p, %DTO.DetailWindow{} = d) do
    follow = if d.next_offset, do: "detail next", else: "DETAIL COMPLETE"

    {p,
     [
       record(["DETAIL ", d.detail_ref.id, " ", Integer.to_string(d.offset), " ", d.text]),
       record(follow)
     ]}
  end

  defp body(p, %Delta{kind: :interaction_remove, entity_id: id}) do
    {%{p | interactions: Map.delete(p.interactions, id)}, [record(["SETTLED ", id])]}
  end

  defp body(p, %Delta{kind: :activity_remove, entity_id: id}) do
    interaction =
      case p.activities[id] do
        %DTO.ActivityItem{interaction: %DTO.PendingInteraction{} = interaction} -> interaction
        _ -> nil
      end

    {interactions, settled} =
      if interaction do
        current = p.interactions[interaction.id]

        interactions =
          if current && current.expected_revision == interaction.expected_revision &&
               current.run_id == interaction.run_id && current.node_id == interaction.node_id,
             do: Map.delete(p.interactions, interaction.id),
             else: p.interactions

        {interactions,
         [
           record([
             "SETTLED ",
             interaction.id,
             "@",
             Integer.to_string(interaction.expected_revision)
           ])
         ]}
      else
        {p.interactions, []}
      end

    {%{p | activities: Map.delete(p.activities, id), interactions: interactions},
     [record(["SETTLED ", id])] ++ settled}
  end

  defp body(p, %Delta{kind: :transcript_remove, entity_id: id}) do
    removed = Enum.filter(Map.values(p.nodes), &(&1.id == id))
    nodes = Map.reject(p.nodes, fn {_key, n} -> n.id == id end)

    targets =
      Enum.reduce(removed, p.target_catalogue, fn n, targets ->
        Enum.reduce([:reply, :thread, :revise], targets, fn kind, targets ->
          MapSet.delete(targets, {kind, n.node_id})
        end)
      end)

    details =
      Enum.reduce(removed, p.detail_refs, fn n, refs ->
        Map.drop(refs, Enum.map(DTO.Details.refs(n), & &1.id))
      end)

    {%{p | nodes: nodes, target_catalogue: targets, detail_refs: details},
     [record(["REMOVED ", id])]}
  end

  defp body(p, %Delta{kind: kind, run_id: run, entity_id: id, text: text, channel: channel})
       when kind in [:stream_append, :stream_reset],
       do:
         {p,
          [
            record([
              if(kind == :stream_reset, do: "RESET ", else: ""),
              if(channel == :reasoning, do: "REASONING ", else: "TEXT "),
              run,
              "/",
              id,
              " ",
              text
            ])
          ]}

  defp body(p, %Delta{kind: :snapshot_required}),
    do: {%{p | status: :resyncing}, [record("RESYNCING")]}

  defp body(p, %Delta{body: body}), do: body(p, body)

  defp body(p, %DTO.Connection{state: state}),
    do: {p, [record(["CONNECTION ", Atom.to_string(state)])]}

  defp body(p, _), do: {p, []}

  defp reduce_bodies(p, bodies),
    do:
      Enum.reduce(bodies, {p, []}, fn item, {p, records} ->
        {p, new} = body(p, item)
        {p, records ++ new}
      end)

  defp removed_prompts(p, items) do
    current = MapSet.new(Enum.map(items, & &1.id))

    p.interactions
    |> Map.values()
    |> Enum.reject(&MapSet.member?(current, &1.id))
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn item ->
      record(["SETTLED ", item.id, "@", Integer.to_string(item.expected_revision)])
    end)
  end

  defp select_prompt(p) do
    prompt =
      p.interactions
      |> Map.values()
      |> Enum.filter(&(&1.state == :pending))
      |> Enum.sort_by(&{&1.created_at, &1.id})
      |> List.first()

    %{p | current_prompt: prompt}
  end

  defp put_bounded(table, key, value) do
    table =
      if map_size(table) >= @limit and not Map.has_key?(table, key),
        do: Map.delete(table, table |> Map.keys() |> Enum.sort() |> List.first()),
        else: table

    Map.put(table, key, value)
  end

  defp approval_verb(:always_allow), do: "always-allow"
  defp approval_verb(:approve), do: "approve"
  defp approval_verb(:deny), do: "deny"
  # Each external field is sanitized independently: fixed metadata never consumes
  # the field's admitted 64 KiB input budget. A delivery has a DTO-bounded count
  # of records; no accepted record is discarded to fit an unrelated page budget.
  defp record(parts, stream \\ :stdout), do: {:raw_record, stream, parts}

  defp render_records(records, options) do
    Enum.map(records, fn {:raw_record, stream, parts} ->
      fragments = if is_binary(parts), do: [parts], else: parts
      limits = %{Limits.content() | ambiguous_width: options.ambiguous_width}

      sanitized =
        Enum.map(fragments, fn fragment ->
          case SafeText.external(fragment, limits) do
            {:ok, safe} -> SafeText.value(safe)
            _ -> "Content exceeds plain output limit."
          end
        end)

      {stream, [sanitized, "\n"]}
    end)
  end
end
