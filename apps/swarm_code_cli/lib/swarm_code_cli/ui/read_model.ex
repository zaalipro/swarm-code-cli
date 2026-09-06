defmodule SwarmCodeCLI.UI.ReadModel do
  @moduledoc "Bounded normalized facts. Snapshots replace slot coverage; streams materialize on demand."
  alias SwarmCodeCLI.UI.{ChunkDeque, Intent}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delta}
  @derive {Inspect, only: []}
  defstruct snapshots: %{},
            runs: %{},
            transcript: %{},
            agents: %{},
            interactions: %{},
            activity: %{},
            order: %{},
            coverage: %{},
            chunks: %ChunkDeque{}

  @type t :: %__MODULE__{}

  def snapshot(model, slot, body) do
    incoming = install(%__MODULE__{}, slot, body)
    old_coverage = Map.get(model.coverage, slot, %{})
    previous = model

    model =
      Enum.reduce([:runs, :transcript, :agents, :interactions, :activity], model, fn field, acc ->
        shared =
          previous.coverage
          |> Map.delete(slot)
          |> Map.values()
          |> Enum.flat_map(&Map.get(&1, field, []))

        incoming_ids = Map.keys(Map.fetch!(incoming, field))

        removed =
          Enum.reject(Map.get(old_coverage, field, []), &(&1 in shared or &1 in incoming_ids))

        Map.update!(acc, field, &Map.drop(&1, removed))
      end)

    replaced =
      Enum.flat_map(incoming.transcript, fn {id, row} ->
        case Map.get(previous.transcript, id) do
          nil -> [id]
          old -> if entity_revision(row) >= entity_revision(old), do: [id], else: []
        end
      end)

    removed = Map.keys(previous.transcript) -- Map.keys(model.transcript)
    chunks = Enum.reduce(Enum.uniq(replaced ++ removed), model.chunks, &ChunkDeque.delete(&2, &1))
    model = %{model | snapshots: Map.put(model.snapshots, slot, body), chunks: chunks}
    install(model, slot, body)
  end

  def items(model, slot) do
    table =
      if slot == :activity,
        do: model.activity,
        else: if(slot == :shell, do: model.runs, else: model.transcript)

    Enum.flat_map(Map.get(model.order, slot, []), fn id ->
      case Map.fetch(table, id) do
        {:ok, item} -> [item]
        :error -> []
      end
    end)
  end

  def transcript_item(model, id) do
    case Map.get(model.transcript, id) do
      nil ->
        nil

      item ->
        %{
          item
          | text: materialize(model, item, :text),
            reasoning: materialize(model, item, :reasoning)
        }
    end
  end

  def delta(model, _slot, %Delta{kind: kind} = delta)
      when kind in [:stream_append, :stream_reset] do
    item = Map.get(model.transcript, delta.entity_id)

    cond do
      is_nil(item) ->
        {:error, :snapshot_required}

      delta.revision <= item.revision ->
        {:ok, model, [item.id], []}

      kind == :stream_append and item.attempt_id != delta.attempt_id ->
        {:error, :snapshot_required}

      true ->
        key = {delta.entity_id, delta.channel, delta.attempt_id}
        chunks = model.chunks

        chunks =
          if kind == :stream_append and not Map.has_key?(chunks.entries, key),
            do: elem(ChunkDeque.append(chunks, key, Map.fetch!(item, delta.channel)), 1),
            else: chunks

        result =
          if kind == :stream_reset,
            do: ChunkDeque.reset(chunks, key, delta.text),
            else: ChunkDeque.append(chunks, key, delta.text)

        case result do
          {:ok, next} ->
            item =
              if kind == :stream_reset and item.attempt_id != delta.attempt_id,
                do: %{item | text: "", reasoning: ""},
                else: item

            item = %{item | attempt_id: delta.attempt_id, revision: delta.revision}

            item =
              if kind == :stream_reset, do: Map.put(item, delta.channel, delta.text), else: item

            {:ok, %{model | chunks: next, transcript: Map.put(model.transcript, item.id, item)},
             [item.id], []}

          {:error, _, _} ->
            {:error, :snapshot_required}
        end
    end
  end

  def delta(model, slot, %Delta{kind: kind, entity_id: id, body: body})
      when kind in [
             :node_upsert,
             :run_update,
             :agent_update,
             :interaction_upsert,
             :activity_upsert
           ] do
    field =
      case kind do
        :node_upsert -> :transcript
        :run_update -> :runs
        :agent_update -> :agents
        :interaction_upsert -> :interactions
        :activity_upsert -> :activity
      end

    table = Map.fetch!(model, field)

    cond do
      not Intent.valid_id?(id) or (not Map.has_key?(table, id) and map_size(table) >= 512) ->
        {:error, :snapshot_required}

      Map.has_key?(table, id) and entity_revision(Map.fetch!(table, id)) > entity_revision(body) ->
        {:ok, model, [], []}

      true ->
        model = Map.put(model, field, Map.put(table, id, body))
        model = track(model, slot, field, [id])
        order = Map.get(model.order, slot, [])

        visible? =
          field == :transcript or (slot == :shell and field == :runs) or
            (slot == :activity and field == :activity)

        order = if visible? and id not in order, do: order ++ [id], else: order

        chunks =
          if kind == :node_upsert, do: ChunkDeque.delete(model.chunks, id), else: model.chunks

        {:ok, %{model | order: Map.put(model.order, slot, order), chunks: chunks},
         if(visible?, do: [id], else: []), []}
    end
  end

  def delta(model, slot, %Delta{kind: kind, entity_id: id})
      when kind in [:transcript_remove, :interaction_remove, :activity_remove] do
    field =
      case kind do
        :transcript_remove -> :transcript
        :interaction_remove -> :interactions
        :activity_remove -> :activity
      end

    model = Map.update!(model, field, &Map.delete(&1, id))

    model = %{
      model
      | coverage:
          Map.new(model.coverage, fn {slot, fields} ->
            {slot, Map.update(fields, field, [], &List.delete(&1, id))}
          end)
    }

    order = Map.update(model.order, slot, [], &List.delete(&1, id))
    {:ok, %{model | order: order, chunks: ChunkDeque.delete(model.chunks, id)}, [], [id]}
  end

  def delta(_model, _slot, %Delta{kind: :snapshot_required}), do: {:error, :snapshot_required}

  def delta(model, slot, %Delta{kind: kind, body: body})
      when kind in [:counts_update, :connection] do
    field = if kind == :counts_update, do: :counts, else: :connection

    snapshots =
      Map.update(model.snapshots, slot, nil, fn snapshot ->
        if Map.has_key?(snapshot, field), do: Map.put(snapshot, field, body), else: snapshot
      end)

    {:ok, %{model | snapshots: snapshots}, [], []}
  end

  defp install(model, slot, body) do
    runs =
      case body do
        %DTO.RunDetailSnapshot{run: run} -> if run, do: [run], else: []
        _ -> Map.get(body, :runs, [])
      end

    transcript =
      case body do
        %DTO.TranscriptWindow{items: rows} -> rows
        %{transcript: %{items: rows}} -> rows
        _ -> []
      end

    activity = if match?(%DTO.ActivitySnapshot{}, body), do: body.items, else: []

    rows =
      case slot do
        :shell -> runs
        :activity -> activity
        _ -> transcript
      end

    interactions =
      Map.get(body, :interactions, []) ++
        Enum.flat_map(activity, fn item ->
          if item.interaction, do: [item.interaction], else: []
        end)

    coverage = %{
      runs: Enum.map(runs, & &1.id),
      transcript: Enum.map(transcript, & &1.id),
      activity: Enum.map(activity, & &1.id),
      agents: Enum.map(Map.get(body, :agents, []), & &1.id),
      interactions: Enum.map(interactions, & &1.id)
    }

    model = %{model | coverage: Map.put(model.coverage, slot, coverage)}

    model
    |> put_rows(:runs, runs)
    |> put_rows(:transcript, transcript)
    |> put_rows(:activity, activity)
    |> put_rows(:agents, Map.get(body, :agents, []))
    |> put_rows(:interactions, interactions)
    |> Map.update!(:order, &Map.put(&1, slot, Enum.map(rows, fn row -> row.id end)))
  end

  defp track(model, slot, field, ids) do
    fields = Map.get(model.coverage, slot, %{})
    fields = Map.update(fields, field, ids, &Enum.uniq(&1 ++ ids))
    %{model | coverage: Map.put(model.coverage, slot, fields)}
  end

  def bounded?(model),
    do:
      Enum.all?(
        [:runs, :transcript, :agents, :interactions, :activity],
        &(map_size(Map.fetch!(model, &1)) <= 512)
      )

  defp entity_revision(row), do: Map.get(row, :revision, Map.get(row, :expected_revision, 0))

  defp put_rows(model, field, rows),
    do:
      Map.update!(model, field, fn table ->
        Enum.reduce(rows, table, fn row, acc ->
          existing = Map.get(acc, row.id)

          if existing &&
               Map.get(existing, :revision, Map.get(existing, :expected_revision, 0)) >
                 Map.get(row, :revision, Map.get(row, :expected_revision, 0)),
             do: acc,
             else: Map.put(acc, row.id, row)
        end)
      end)

  defp materialize(model, item, channel) do
    key = {item.id, channel, item.attempt_id}

    if Map.has_key?(model.chunks.entries, key),
      do: ChunkDeque.materialize(model.chunks, key),
      else: Map.fetch!(item, channel)
  end
end
