defmodule SwarmCodeCLI.UI.DataSource.Fake.Script do
  @moduledoc """
  Pure synthetic canonical facts and explicit virtual-clock barriers. Decoding
  accepts a bounded committed fixture, never a filename or arbitrary operation.
  """
  alias SwarmCode.Protocol.JsonLimits
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delta, DTO, Request}
  alias DTO.Schema
  alias SwarmCodeCLI.UI.DataSource.Fake.{Compose, Details, Session}

  @clock "2026-09-03T12:00:00Z"
  @clock_ms 1_788_436_800_000
  @barriers [
    "a1-a2-b1-step-1",
    "a1-b1-step-2",
    "sequence-gap",
    "catalogue-retry",
    "catalogue-agent-stop",
    "catalogue-activity",
    "catalogue-statuses"
  ]
  @ids %{
    a: "00000000-0000-4000-8000-00000000000a",
    b: "00000000-0000-4000-8000-00000000000b",
    a1: "00000000-0000-4000-8000-0000000000a1",
    a2: "00000000-0000-4000-8000-0000000000a2",
    b1: "00000000-0000-4000-8000-0000000000b1",
    q1: "00000000-0000-4000-8000-0000000000c1",
    q2: "00000000-0000-4000-8000-0000000000c2",
    approval: "00000000-0000-4000-8000-0000000000c3",
    node_a1: "00000000-0000-4000-8000-0000000000d1",
    node_a2: "00000000-0000-4000-8000-0000000000d2",
    node_b1: "00000000-0000-4000-8000-0000000000d3",
    failed_retry: "00000000-0000-4000-8000-0000000000f1",
    failed_no_retry: "00000000-0000-4000-8000-0000000000f2",
    agent_stop: "00000000-0000-4000-8000-0000000000e1",
    agent_no_stop: "00000000-0000-4000-8000-0000000000e2",
    request: "00000000-0000-4000-8000-000000000001",
    lead: "00000000-0000-4000-8000-00000000a201",
    scout_1: "00000000-0000-4000-8000-00000000a202",
    scout_2: "00000000-0000-4000-8000-00000000a203",
    builder_4: "00000000-0000-4000-8000-00000000a204",
    judge: "00000000-0000-4000-8000-00000000a205",
    change_1: "00000000-0000-4000-8000-00000000a2c1",
    change_2: "00000000-0000-4000-8000-00000000a2c2",
    change_3: "00000000-0000-4000-8000-00000000a2c3",
    node_tool_1: "00000000-0000-4000-8000-00000000a2e1",
    node_tool_2: "00000000-0000-4000-8000-00000000a2e2",
    node_tool_3: "00000000-0000-4000-8000-00000000a2e3",
    node_thinking: "00000000-0000-4000-8000-00000000a2e4",
    node_error: "00000000-0000-4000-8000-00000000a2e5"
  }
  defstruct clock: @clock,
            runs: %{},
            agents: %{},
            transcript: %{},
            interactions: %{},
            activity: %{},
            changes: %{},
            verdicts: %{},
            statuses: [],
            sequence: 0,
            revision: 0,
            barriers: @barriers,
            completed: [],
            details: %{},
            commands: %{},
            conversation_seen: %{},
            # pass70 C1: the session-level facts (conversation list, project
            # approval mode and trust, diffs, background commands, rate limits).
            session: nil

  @type t :: %__MODULE__{
          clock: binary(),
          runs: %{binary() => DTO.RunSummary.t()},
          agents: %{binary() => DTO.AgentSummary.t()},
          transcript: %{binary() => DTO.TranscriptItem.t()},
          interactions: %{binary() => DTO.PendingInteraction.t()},
          activity: %{binary() => DTO.ActivityItem.t()},
          changes: %{binary() => DTO.Change.t()},
          verdicts: %{binary() => DTO.Verdict.t()},
          statuses: [DTO.StatusEntry.t()],
          sequence: non_neg_integer(),
          revision: non_neg_integer(),
          barriers: [binary()],
          completed: [binary()],
          details: map(),
          commands: map(),
          conversation_seen: %{binary() => non_neg_integer()},
          session: Session.t() | nil
        }
  @type snapshot :: t()
  def id(key), do: Map.fetch!(@ids, key)
  def clock_ms, do: @clock_ms
  def barriers, do: @barriers

  @spec decode(term()) :: {:ok, t()} | {:error, AdmissionError.t()}
  def decode(input) do
    with {:ok,
          %{"version" => 1, "clock" => @clock, "runs" => runs, "barriers" => @barriers} = raw} <-
           JsonLimits.decode(input, max_bytes: 1_048_576, max_depth: 12, max_entries: 4096),
         true <- map_size(raw) == 4,
         true <- Schema.bounded_list?(runs, 3, fn _ -> true end) and length(runs) == 3,
         {:ok, decoded} <- decode_runs(runs),
         true <- Enum.map(decoded, & &1.id) == [id(:a1), id(:a2), id(:b1)],
         true <- Enum.all?(decoded, &(&1.state == :running and &1.revision == 1)),
         true <-
           Enum.map(decoded, &{&1.conversation_id, &1.kind}) == [
             {id(:a), :chat},
             {id(:a), :swarm},
             {id(:b), :research}
           ] do
      decoded =
        Enum.map(
          decoded,
          &%{&1 | allowed_actions: Enum.uniq(&1.allowed_actions ++ [:steer, :mark_seen])}
        )

      runs =
        Map.new(Enum.with_index(decoded, 1), fn {run, index} ->
          {run.id, hive_run(%{run | created_sequence: index})}
        end)

      script = %__MODULE__{runs: runs}

      transcript = [
        item(:a1, :node_a1, "message-A-1", "Authentication review started.",
          at: @clock_ms - 95_000,
          tokens_in: 1_180,
          tokens_out: 96
        ),
        item(:a2, :node_a2, "message-A-2", "Swarm plan\nReview authentication\nand its tests",
          agent_id: id(:lead),
          at: @clock_ms - 80_000,
          tokens_in: 2_410,
          tokens_out: 188
        ),
        item(:b1, :node_b1, "message-B-1", "Research started.",
          at: @clock_ms - 60_000,
          tokens_in: 640,
          tokens_out: 42
        )
      ]

      validate(%{
        script
        | transcript:
            Map.new(Enum.with_index(transcript, 1), fn {item, index} ->
              {item.id, %{item | created_sequence: index}}
            end),
          activity: Map.new(Map.values(runs), fn run -> {run.id, activity(run)} end),
          agents: Map.new(hive_agents(), &{&1.id, &1}),
          changes: Map.new(hive_changes(), &{&1.id, &1}),
          verdicts: Map.new([hive_verdict()], &{&1.id, &1}),
          session: Session.initial(@clock_ms, @ids)
      })
    else
      _ -> {:error, AdmissionError.new(:invalid_fixture)}
    end
  end

  @doc "Decode the two bounded, closed presentation-only catalogue fixtures."
  def decode_catalogue(input) do
    with {:ok, raw} <-
           JsonLimits.decode(input, max_bytes: 1_048_576, max_depth: 16, max_entries: 8192),
         {:ok, result} <- decode_catalogue_map(raw) do
      {:ok, result}
    else
      _ -> {:error, AdmissionError.new(:invalid_fixture)}
    end
  end

  defp decode_catalogue_map(%{"catalogue" => "statuses", "items" => items} = raw)
       when map_size(raw) == 2 do
    if Schema.bounded_list?(items, 200, fn _ -> true end) do
      Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
        case DTO.StatusEntry.decode(item) do
          {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
          _ -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp decode_catalogue_map(%{"catalogue" => "activity", "page" => page} = raw)
       when map_size(raw) == 2,
       do: DTO.ActivitySnapshot.decode(page)

  defp decode_catalogue_map(_), do: :error

  def validate(%__MODULE__{} = script) do
    valid =
      map_size(script) == map_size(%__MODULE__{}) and
        Enum.all?(Map.keys(%__MODULE__{}), &Map.has_key?(script, &1)) and
        script.clock == @clock and script.barriers == @barriers and
        Schema.valid?(:revision, script.sequence) and Schema.valid?(:revision, script.revision) and
        Enum.all?(
          [
            {script.runs, DTO.RunSummary},
            {script.agents, DTO.AgentSummary},
            {script.transcript, DTO.TranscriptItem},
            {script.interactions, DTO.PendingInteraction},
            {script.activity, DTO.ActivityItem},
            {script.changes, DTO.Change},
            {script.verdicts, DTO.Verdict}
          ],
          fn {items, module} ->
            is_map(items) and not is_struct(items) and map_size(items) <= 200 and
              Enum.all?(items, fn {key, item} ->
                Schema.valid?(:id, key) and Schema.valid?({:dto, module}, item) and item.id == key
              end)
          end
        ) and Schema.valid?({:list, {:dto, DTO.StatusEntry}}, script.statuses) and
        Schema.bounded_list?(script.completed, length(@barriers), &(&1 in @barriers)) and
        Enum.uniq(script.completed) == script.completed and canonical_references?(script) and
        supported_permissions?(script) and canonical_extensions?(script) and
        (is_nil(script.session) or Session.valid?(script.session))

    if valid, do: {:ok, script}, else: {:error, AdmissionError.new(:invalid_fixture)}
  end

  def validate(_), do: {:error, AdmissionError.new(:invalid_fixture)}

  defp supported_permissions?(script) do
    Enum.all?(script.transcript, fn {_, item} ->
      Enum.all?(item.allowed_actions, &(&1 in [:inspect, :copy, :fork]))
    end) and
      Enum.all?(
        [script.runs, script.agents, script.transcript, script.interactions, script.activity],
        fn items ->
          Enum.all?(items, fn {_, item} ->
            Enum.all?(item.allowed_actions, &(&1 not in [:send, :queue])) and
              (:steer not in item.allowed_actions or
                 item.state in [:running, :streaming, :retrying])
          end)
        end
      )
  end

  defp canonical_extensions?(script) do
    Details.valid?(script.details) and
      is_map(script.commands) and not is_struct(script.commands) and
      map_size(script.commands) <= 200 and
      Enum.all?(script.commands, fn {id, value} ->
        Schema.valid?(:id, id) and match?(%{fingerprint: _, outcome: %DTO.Outcome{}}, value) and
          map_size(value) == 2 and is_binary(value.fingerprint) and
          byte_size(value.fingerprint) == 32 and
          Schema.valid?({:dto, DTO.Outcome}, value.outcome) and value.outcome.request_id == id
      end) and
      is_map(script.conversation_seen) and not is_struct(script.conversation_seen) and
      map_size(script.conversation_seen) <= 200 and
      Enum.all?(script.conversation_seen, fn {id, revision} ->
        Schema.valid?(:id, id) and Schema.valid?(:revision, revision) and
          revision <= conversation_revision(script, id) and
          (Enum.any?(script.runs, fn {_, run} -> run.conversation_id == id end) or
             Session.conversation?(script, id))
      end) and
      Enum.all?(script.transcript, fn {_, item} ->
        is_nil(item.detail_ref) or
          case Map.get(script.details, item.detail_ref.id) do
            %{ref: ref, run_id: run_id, conversation_id: conversation_id, text: text} ->
              ref == item.detail_ref and run_id == item.run_id and
                conversation_id == item.conversation_id and String.starts_with?(text, item.text)

            _ ->
              false
          end
      end) and
      Enum.all?(script.details, fn {id, _} ->
        Enum.any?(script.transcript, fn {_, item} ->
          item.detail_ref && item.detail_ref.id == id
        end)
      end)
  end

  def next_created_sequence(script) do
    Enum.reduce(
      Map.values(script.runs) ++ Map.values(script.transcript),
      script.sequence,
      fn item, last -> max(item.created_sequence, last) end
    ) + 1
  end

  def workspace_actions(script, %{kind: :conversation, id: id}) do
    if Enum.any?(script.runs, fn {_, run} -> run.conversation_id == id end) or
         Session.conversation?(script, id),
       do: [:send, :queue, :mark_seen],
       else: []
  end

  def workspace_actions(_, _), do: []

  def conversation_revision(script, id),
    do:
      script.runs
      |> Map.values()
      |> Enum.filter(&(&1.conversation_id == id))
      |> Enum.map(& &1.revision)
      |> Enum.sum()

  def conversation_seen_revision(script, id), do: Map.get(script.conversation_seen, id, 0)

  defp canonical_references?(script) do
    Enum.all?([:a1, :a2, :b1], &Map.has_key?(script.runs, id(&1))) and
      Enum.all?(
        ["message-A-1", "message-A-2", "message-B-1"],
        &Map.has_key?(script.transcript, &1)
      ) and
      Enum.all?(script.agents, fn {_, item} -> Map.has_key?(script.runs, item.run_id) end) and
      Enum.all?(script.verdicts, fn {_, item} -> Map.has_key?(script.runs, item.run_id) end) and
      Enum.all?(script.changes, fn {_, change} ->
        Map.has_key?(script.runs, change.run_id) and
          (is_nil(change.agent_id) or
             match?(
               %{run_id: run_id} when run_id == change.run_id,
               script.agents[change.agent_id]
             ))
      end) and
      Enum.all?(script.runs, fn {_, run} ->
        is_nil(run.parent_run_id) or
          case Map.get(script.runs, run.parent_run_id) do
            nil -> false
            parent -> parent.conversation_id == run.conversation_id
          end
      end) and
      Enum.all?([script.transcript, script.interactions, script.activity], fn items ->
        Enum.all?(items, fn {_, item} ->
          case Map.get(script.runs, item.run_id) do
            nil -> false
            run -> item.conversation_id == run.conversation_id
          end
        end)
      end)
  end

  defp decode_runs(runs) do
    Enum.reduce_while(runs, {:ok, []}, fn raw, {:ok, acc} ->
      case DTO.RunSummary.decode(raw) do
        {:ok, run} -> {:cont, {:ok, acc ++ [run]}}
        _ -> {:halt, :error}
      end
    end)
  end

  @spec advance(t(), binary()) ::
          {:ok, t(), [Delta.t()]} | {:error, :unknown_barrier | AdmissionError.t()}
  def advance(script, barrier) when barrier in @barriers do
    cond do
      barrier in script.completed ->
        {:ok, script, []}

      barrier == "a1-b1-step-2" and "a1-a2-b1-step-1" not in script.completed ->
        {:error, :unknown_barrier}

      true ->
        case step(script, barrier) do
          {:error, _} = error ->
            error

          {next, deltas} ->
            next = %{next | completed: script.completed ++ [barrier]}
            validate_transition(next, deltas)
        end
    end
  end

  def advance(_, _), do: {:error, :unknown_barrier}

  defp step(script, "a1-a2-b1-step-1") do
    node = %{
      script.transcript["message-A-1"]
      | revision: script.transcript["message-A-1"].revision + 1
    }

    a1 = %{script.runs[id(:a1)] | revision: script.runs[id(:a1)].revision + 1, progress: 25}

    a2 = %{
      script.runs[id(:a2)]
      | revision: script.runs[id(:a2)].revision + 1,
        state: :waiting_question,
        allowed_actions: [:stop],
        needs: 1
    }

    b1 = %{script.runs[id(:b1)] | revision: script.runs[id(:b1)].revision + 1, progress: 40}
    q = question(:q1, :a2, :node_a2, 7, :high, @clock_ms + 60_000)

    a2_facts =
      if Map.has_key?(script.interactions, q.id),
        do: [],
        else: running_facts(script, :a2, [fact(:interaction_upsert, q), fact(:run_update, a2)])

    deltas =
      running_facts(script, :a1, [
        fact(:node_upsert, node),
        stream(node, :text, " Authentication paths checked."),
        stream(node, :reasoning, " Check the test boundaries."),
        fact(:run_update, a1)
      ]) ++
        a2_facts ++
        hive_facts(script) ++
        running_facts(script, :b1, [
          stream(script.transcript["message-B-1"], :text, " Report sources collected."),
          fact(:run_update, b1)
        ])

    apply_deltas(script, deltas)
  end

  defp step(script, "a1-b1-step-2") do
    deltas =
      running_facts(script, :a1, [
        stream(script.transcript["message-A-1"], :text, " Tests reviewed."),
        fact(:run_update, %{
          script.runs[id(:a1)]
          | revision: script.runs[id(:a1)].revision + 1,
            progress: 60
        })
      ]) ++
        running_facts(script, :b1, [
          stream(script.transcript["message-B-1"], :text, " Report comparisons completed."),
          fact(:run_update, %{
            script.runs[id(:b1)]
            | revision: script.runs[id(:b1)].revision + 1,
              progress: 70
          })
        ])

    apply_deltas(script, deltas)
  end

  defp step(script, "sequence-gap"),
    do: {%{script | sequence: script.sequence + 1}, [%Delta{kind: :snapshot_required}]}

  defp step(script, "catalogue-retry") do
    runs = [
      catalogue_run(:failed_retry, :failed, [:retry], 41),
      catalogue_run(:failed_no_retry, :failed, [], 43)
    ]

    apply_deltas(
      script,
      runs |> Enum.reject(&Map.has_key?(script.runs, &1.id)) |> Enum.map(&fact(:run_update, &1))
    )
  end

  defp step(script, "catalogue-agent-stop") do
    agents = [
      %DTO.AgentSummary{
        id: id(:agent_stop),
        run_id: id(:a1),
        revision: 51,
        state: :running,
        allowed_actions: [:stop_agent],
        launched_by_superseded: true
      },
      %DTO.AgentSummary{
        id: id(:agent_no_stop),
        run_id: id(:a1),
        revision: 61,
        state: :running,
        allowed_actions: []
      }
    ]

    apply_deltas(
      script,
      agents
      |> Enum.reject(&Map.has_key?(script.agents, &1.id))
      |> Enum.map(&fact(:agent_update, &1))
    )
  end

  defp step(script, "catalogue-activity") do
    q1 = question(:q1, :a2, :node_a2, 7, :high, @clock_ms + 60_000)
    q2 = question(:q2, :b1, :node_b1, 9, :urgent, @clock_ms + 30_000)

    approval = %{
      question(:approval, :a1, :node_a1, 11, :normal, @clock_ms + 120_000)
      | kind: :approval,
        question: nil,
        approval: Session.approval(@clock_ms),
        allowed_actions: [:approve, :deny, :always_allow]
    }

    paused = %DTO.RunSummary{
      id: "catalogue-paused",
      conversation_id: id(:b),
      title: "Paused work",
      revision: 71,
      state: :paused,
      allowed_actions: [:continue, :stop]
    }

    done = %DTO.RunSummary{
      id: "catalogue-done",
      conversation_id: id(:b),
      title: "Completed work",
      revision: 81,
      state: :done,
      progress: 100
    }

    failed = catalogue_run(:failed_retry, :failed, [:retry], 41)

    deltas =
      ([q1, q2, approval]
       |> Enum.reject(
         &(Map.has_key?(script.interactions, &1.id) or
             script.runs[&1.run_id].state not in [:running, :streaming, :retrying])
       )
       |> Enum.map(&fact(:interaction_upsert, &1))) ++
        ([paused, failed, done]
         |> Enum.reject(&Map.has_key?(script.runs, &1.id))
         |> Enum.map(&fact(:run_update, &1)))

    apply_deltas(script, deltas)
  end

  defp step(script, "catalogue-statuses") do
    superseded = %{
      item(:a1, :node_a1, "message-A-superseded", "Original superseded authentication proposal.")
      | state: :superseded,
        revision: 91
    }

    case apply_deltas(script, [fact(:node_upsert, superseded)]) do
      {:error, _} = error -> error
      {next, deltas} -> {%{next | statuses: status_catalogue()}, deltas}
    end
  end

  # A catalogue barrier is a source of initial facts, not permission to undo a
  # user's later command. Controlled branches retain their exact canonical facts.
  defp running_facts(script, key, deltas) do
    if script.runs[id(key)].state in [:running, :streaming, :retrying], do: deltas, else: []
  end

  def status_catalogue do
    states = [
      :connecting,
      :empty,
      :loading,
      :running,
      :streaming,
      :queued,
      :waiting_question,
      :waiting_approval,
      :paused,
      :retrying,
      :done,
      :failed,
      :stopped,
      :interrupted,
      :stale,
      :resyncing,
      :disconnected,
      :superseded,
      :mutation_pending
    ]

    base =
      Enum.map(states, fn state ->
        %DTO.StatusEntry{
          id: "status-" <> Atom.to_string(state),
          state: state,
          revision: 91,
          allowed_actions: if(state == :superseded, do: [:inspect, :copy, :fork], else: []),
          page_state: if(state == :loading, do: :loading_before, else: :idle),
          request_id: if(state in [:loading, :mutation_pending], do: id(:request), else: nil)
        }
      end)

    base ++
      [
        %DTO.StatusEntry{
          id: "status-failed-retry",
          state: :failed,
          revision: 41,
          allowed_actions: [:retry]
        },
        %DTO.StatusEntry{
          id: "status-interrupted-resume",
          state: :interrupted,
          revision: 92,
          allowed_actions: [:resume]
        }
      ]
  end

  defp apply_deltas(script, deltas) do
    if append_capacity?(script, deltas) do
      do_apply_deltas(script, deltas)
    else
      {:error, AdmissionError.new(:capacity_exceeded)}
    end
  end

  defp append_capacity?(script, deltas) do
    initial =
      Map.new(script.transcript, fn {id, item} ->
        {id, %{text: byte_size(item.text), reasoning: byte_size(item.reasoning)}}
      end)

    Enum.reduce_while(deltas, initial, fn
      %Delta{kind: :node_upsert, body: item}, sizes ->
        {:cont,
         Map.put(sizes, item.id, %{
           text: byte_size(item.text),
           reasoning: byte_size(item.reasoning)
         })}

      %Delta{kind: :stream_append, entity_id: id, channel: channel, text: text}, sizes ->
        size = get_in(sizes, [id, channel])

        if is_integer(size) and size + byte_size(text) <= 65_536,
          do: {:cont, put_in(sizes, [id, channel], size + byte_size(text))},
          else: {:halt, :overflow}

      _, sizes ->
        {:cont, sizes}
    end) != :overflow
  end

  defp creation_order(script, deltas) do
    {ordered, _} =
      Enum.map_reduce(deltas, next_created_sequence(script), fn
        %Delta{kind: kind, body: %{created_sequence: 0} = item} = delta, ordinal
        when kind in [:run_update, :node_upsert] ->
          existing =
            if kind == :run_update,
              do: Map.get(script.runs, item.id),
              else: Map.get(script.transcript, item.id)

          created = if existing, do: existing.created_sequence, else: ordinal

          {%{delta | body: %{item | created_sequence: created}},
           if(existing, do: ordinal, else: ordinal + 1)}

        delta, ordinal ->
          {delta, ordinal}
      end)

    ordered
  end

  defp do_apply_deltas(script, deltas) do
    deltas = creation_order(script, deltas)
    next = Enum.reduce(deltas, script, &apply_delta/2)

    activity_deltas =
      Enum.flat_map(deltas, fn
        %Delta{kind: kind, entity_id: id} when kind in [:run_update, :interaction_upsert] ->
          [fact(:activity_upsert, Map.fetch!(next.activity, id))]

        %Delta{kind: :interaction_remove} = delta ->
          [
            %Delta{
              kind: :activity_remove,
              entity_id: delta.entity_id,
              run_id: delta.run_id,
              conversation_id: delta.conversation_id
            }
          ]

        _ ->
          []
      end)

    {next, deltas ++ activity_deltas ++ [%Delta{kind: :counts_update, body: counts(next)}]}
  end

  defp apply_delta(%Delta{kind: :node_upsert, body: item}, script),
    do: %{script | transcript: Map.put(script.transcript, item.id, item)}

  defp apply_delta(
         %Delta{kind: :stream_append, entity_id: id, channel: channel, text: text},
         script
       ) do
    item = Map.fetch!(script.transcript, id)
    updated = Map.update!(item, channel, &(&1 <> text))
    %{script | transcript: Map.put(script.transcript, id, updated)}
  end

  defp apply_delta(%Delta{kind: :run_update, body: run}, script),
    do: %{
      script
      | runs: Map.put(script.runs, run.id, run),
        activity: Map.put(script.activity, run.id, preserve_seen(script, activity(run)))
    }

  defp apply_delta(%Delta{kind: :activity_upsert, body: item}, script),
    do: %{script | activity: Map.put(script.activity, item.id, item)}

  defp apply_delta(%Delta{kind: :agent_update, body: agent}, script),
    do: %{script | agents: Map.put(script.agents, agent.id, agent)}

  defp apply_delta(%Delta{kind: :change_upsert, body: change}, script),
    do: %{script | changes: Map.put(script.changes, change.id, change)}

  defp apply_delta(%Delta{kind: :change_remove, entity_id: id}, script),
    do: %{script | changes: Map.delete(script.changes, id)}

  defp apply_delta(%Delta{kind: :verdict_upsert, body: verdict}, script),
    do: %{script | verdicts: Map.put(script.verdicts, verdict.id, verdict)}

  defp apply_delta(%Delta{kind: :interaction_upsert, body: interaction}, script),
    do: %{
      script
      | interactions: Map.put(script.interactions, interaction.id, interaction),
        activity: Map.put(script.activity, interaction.id, interaction_activity(interaction))
    }

  defp apply_delta(%Delta{kind: kind} = delta, script)
       when kind in [
              :toast,
              :rate_limit,
              :background_upsert,
              :background_remove,
              :workspace_metadata
            ],
       do: Session.apply_delta(delta, script)

  defp apply_delta(%Delta{kind: :interaction_remove, entity_id: id}, script) do
    interaction = %{Map.fetch!(script.interactions, id) | state: :resolved, allowed_actions: []}

    %{
      script
      | interactions: Map.put(script.interactions, id, interaction),
        activity: Map.delete(script.activity, id)
    }
  end

  defp sequence(script, deltas) do
    revision = script.revision + if(deltas == [], do: 0, else: 1)

    {deltas, last} =
      Enum.map_reduce(deltas, script.sequence, fn delta, sequence ->
        {%{delta | sequence: sequence + 1, revision: revision}, sequence + 1}
      end)

    {%{script | sequence: last, revision: revision}, deltas}
  end

  defp validate_transition(next, deltas) do
    {next, deltas} = sequence(next, deltas)

    if match?({:ok, _}, validate(next)) and
         Enum.all?(deltas, &match?({:ok, _}, Delta.validate(&1))),
       do: {:ok, next, deltas},
       else: {:error, AdmissionError.new(:capacity_exceeded)}
  end

  @spec command(t(), Request.t()) ::
          {:ok, t(), DTO.Outcome.t(), [Delta.t()]} | {:error, AdmissionError.t()}
  def command(script, request) do
    with {:ok, _} <- Request.validate(request) do
      fingerprint =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(
            {request.kind, request.scope.kind, request.scope.id, request.origin}
          )
        )

      case Map.get(script.commands, request.request_id) do
        %{fingerprint: ^fingerprint, outcome: outcome} -> {:ok, script, outcome, []}
        nil -> command_new(script, request, fingerprint)
        _ -> {:error, AdmissionError.new(:request_conflict)}
      end
    else
      _ -> {:error, AdmissionError.new(:invalid_request)}
    end
  end

  defp command_new(script, request, fingerprint) do
    # pass70 C7: a slash command may answer with feedback (a report, a
    # navigation) beside its identifiers.
    prepared =
      case prepare_command(script, request) do
        {:ok, prepared, deltas, identifiers} -> {:ok, prepared, deltas, identifiers, nil}
        other -> other
      end

    with {:ok, prepared, deltas, identifiers, feedback} <- prepared do
      case apply_deltas(prepared, deltas) do
        {:error, _} = error ->
          error

        {next, deltas} ->
          outcome = %DTO.Outcome{
            status: :accepted,
            request_id: request.request_id,
            identifiers: identifiers,
            feedback: feedback
          }

          next = %{
            next
            | commands:
                Map.put(next.commands, request.request_id, %{
                  fingerprint: fingerprint,
                  outcome: outcome
                })
          }

          with {:ok, next, deltas} <- validate_transition(next, deltas),
               do: {:ok, next, outcome, deltas}
      end
    else
      {:error, %AdmissionError{}} = error -> error
      {:error, code} -> {:error, AdmissionError.new(code)}
    end
  end

  defp prepare_command(script, %{kind: kind} = request)
       when elem(kind, 0) in [:dispatch, :steer, :mark_seen],
       do: Compose.prepare(script, request)

  defp prepare_command(script, %{kind: kind} = request)
       when elem(kind, 0) in [:conversation_new, :conversation_open, :project_update],
       do: Session.prepare(script, request)

  defp prepare_command(script, request) do
    with :ok <- scope_allows(script, request),
         {:ok, deltas, identifiers} <- command_deltas(script, request.kind),
         do: {:ok, script, deltas, identifiers}
  end

  defp scope_allows(_, %{scope: %{kind: :global}}), do: :ok

  defp scope_allows(script, %{scope: scope, kind: kind}) do
    run_id =
      case kind do
        {:run_control, _, id} -> id
        {:retry_run, id, _} -> id
        {:stop_agent, id, _, _} -> id
        {:answer_question, id, _, _, _, _} -> id
        {:resolve_approval, id, _, _, _, _} -> id
        _ -> nil
      end

    case Map.get(script.runs, run_id) do
      nil ->
        {:error, :invalid_origin}

      run ->
        if(
          (scope.kind == :run and scope.id == run.id) or
            (scope.kind == :conversation and scope.id == run.conversation_id),
          do: :ok,
          else: {:error, :invalid_origin}
        )
    end
  end

  defp command_deltas(script, {:retry_run, id, revision}) do
    with {:ok, run} <- lookup(script.runs, id),
         :ok <- permission(run, :retry),
         :ok <- condition(run.state == :failed, :not_allowed),
         :ok <- cas(run.revision, revision) do
      {:ok,
       [
         fact(:run_update, %{
           run
           | state: :retrying,
             revision: run.revision + 1,
             allowed_actions: [:stop]
         })
       ], [id]}
    end
  end

  defp command_deltas(script, {:stop_agent, run_id, agent_id, revision}) do
    with {:ok, agent} <- lookup(script.agents, agent_id),
         :ok <- condition(agent.run_id == run_id, :invalid_origin),
         :ok <- permission(agent, :stop_agent),
         :ok <- condition(agent.state in [:running, :streaming, :paused, :queued], :not_allowed),
         :ok <- cas(agent.revision, revision) do
      {:ok,
       [
         fact(:agent_update, %{
           agent
           | state: :stopped,
             revision: agent.revision + 1,
             allowed_actions: []
         })
       ], [run_id, agent_id]}
    end
  end

  defp command_deltas(script, {:run_control, operation, id}) do
    with {:ok, run} <- lookup(script.runs, id), :ok <- permission(run, operation) do
      {state, actions} =
        case operation do
          :stop ->
            {:stopped, []}

          :pause ->
            {:paused, [:continue, :stop]}

          operation when operation in [:continue, :resume] ->
            {:running, [:pause, :stop, :steer, :mark_seen]}
        end

      run_delta =
        fact(:run_update, %{
          run
          | state: state,
            revision: run.revision + 1,
            allowed_actions: actions,
            needs: if(operation == :stop, do: 0, else: run.needs)
        })

      settled =
        if operation == :stop do
          script.interactions
          |> Map.values()
          |> Enum.filter(&(&1.run_id == id and &1.state == :pending))
          |> Enum.sort_by(& &1.id)
          |> Enum.map(fn q ->
            %Delta{
              kind: :interaction_remove,
              entity_id: q.id,
              run_id: q.run_id,
              conversation_id: q.conversation_id
            }
          end)
        else
          []
        end

      {:ok, [run_delta | settled], [id]}
    end
  end

  defp command_deltas(script, {:answer_question, run_id, node_id, id, revision, options}) do
    with {:ok, q} <-
           interaction(script, :question, run_id, node_id, id, revision, :answer_question),
         :ok <-
           condition(
             options != [] and (q.question.multiple or length(options) == 1) and
               Enum.all?(options, fn option ->
                 Enum.any?(q.question.options, &(&1.id == option))
               end),
             :invalid_intent
           ) do
      resolve_interaction(script, q)
    end
  end

  defp command_deltas(script, {:resolve_approval, run_id, node_id, id, revision, decision}) do
    with {:ok, q} <- interaction(script, :approval, run_id, node_id, id, revision, decision),
         {:ok, deltas, identifiers} <- resolve_interaction(script, q) do
      {:ok, deltas ++ Session.decision_facts(script, q, decision), identifiers}
    end
  end

  defp command_deltas(_, _), do: {:error, :not_allowed}

  defp interaction(script, kind, run_id, node_id, id, revision, action) do
    with {:ok, q} <- lookup(script.interactions, id),
         :ok <-
           condition(
             q.kind == kind and q.run_id == run_id and q.node_id == node_id,
             :invalid_origin
           ),
         :ok <- permission(q, action),
         :ok <- condition(q.state == :pending, :not_allowed),
         {:ok, run} <- lookup(script.runs, q.run_id),
         :ok <-
           condition(
             run.state not in [:stopped, :done, :failed, :interrupted, :superseded],
             :not_allowed
           ),
         :ok <- cas(q.expected_revision, revision) do
      {:ok, q}
    end
  end

  defp resolve_interaction(script, q) do
    still_pending =
      Enum.count(script.interactions, fn {_, other} ->
        other.run_id == q.run_id and other.state == :pending and other.id != q.id
      end)

    run = %{
      Map.fetch!(script.runs, q.run_id)
      | state: :running,
        revision: script.runs[q.run_id].revision + 1,
        allowed_actions: [:pause, :stop, :steer, :mark_seen],
        needs: still_pending
    }

    {:ok,
     [
       %Delta{
         kind: :interaction_remove,
         entity_id: q.id,
         run_id: q.run_id,
         conversation_id: q.conversation_id
       },
       fact(:run_update, run)
     ], [q.id, q.run_id]}
  end

  defp lookup(map, id) do
    case Map.fetch(map, id) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_origin}
    end
  end

  # pass70 C1: the widened approval decisions are offered by the approval's own
  # `allowed_decisions`; the legacy three by `allowed_actions`.
  defp permission(%DTO.PendingInteraction{approval: %DTO.Approval{} = approval}, action)
       when action in [:approve_run, :always_prefix, :deny_stop],
       do: condition(action in approval.allowed_decisions, :not_allowed)

  defp permission(item, action), do: condition(action in item.allowed_actions, :not_allowed)
  defp cas(actual, expected), do: condition(actual == expected, :stale_revision)
  defp condition(true, _), do: :ok
  defp condition(false, code), do: {:error, code}

  def counts(script) do
    runs = Map.values(script.runs)

    %DTO.Counts{
      running: Enum.count(runs, &(&1.state in [:running, :streaming, :retrying])),
      waiting: Enum.count(runs, &(&1.state in [:waiting_question, :waiting_approval])),
      paused: Enum.count(runs, &(&1.state == :paused)),
      failed: Enum.count(runs, &(&1.state == :failed)),
      done: Enum.count(runs, &(&1.state == :done))
    }
  end

  defp item(run, node, message, text, extra \\ []),
    do:
      struct!(
        %DTO.TranscriptItem{
          id: message,
          run_id: id(run),
          node_id: id(node),
          conversation_id: id(if(run == :b1, do: :b, else: :a)),
          revision: 1,
          text: text,
          attempt_id: "attempt-1",
          allowed_actions: [:inspect, :copy, :fork]
        },
        extra
      )

  # -- hive: named agents, tool calls, changes and a verdict on the swarm run --

  defp hive_run(%DTO.RunSummary{id: run_id} = run) do
    extra =
      cond do
        run_id == id(:a1) ->
          [tokens_in: 3_420, tokens_out: 612, cost_usd: 0.021, model: "deepseek-v4-pro"]

        run_id == id(:a2) ->
          [
            tokens_in: 18_640,
            tokens_out: 4_210,
            cost_usd: 0.184,
            model: "kimi-k2-thinking",
            agents_total: 5,
            agents_running: 3,
            changes: 3,
            consensus: true
          ]

        true ->
          [tokens_in: 7_880, tokens_out: 1_030, cost_usd: 0.062, model: "deepseek-v4-pro"]
      end

    struct!(run, [started_at: @clock_ms - 120_000] ++ extra)
  end

  defp hive_agents do
    base = [
      run_id: id(:a2),
      revision: 1,
      state: :running,
      allowed_actions: [:stop_agent],
      started_at: @clock_ms - 110_000
    ]

    [
      agent(:lead, base,
        name: "lead",
        role: :lead,
        model: "kimi-k2-thinking",
        provider_name: "llmotions",
        title: "Coordinate the authentication review",
        step: "planning",
        progress: 35,
        tokens_in: 6_120,
        tokens_out: 1_480,
        cost_usd: 0.061
      ),
      agent(:scout_1, base,
        name: "scout-1",
        role: :sub,
        title: "Map the auth call sites",
        step: "grep \"Repo\\.\"",
        progress: 70,
        tokens_in: 3_210,
        tokens_out: 640,
        cost_usd: 0.028,
        parent_id: id(:lead),
        depth: 1
      ),
      agent(:scout_2, base,
        name: "scout-2",
        role: :sub,
        title: "Read the session tests",
        step: "read test/session_test.exs",
        progress: 55,
        tokens_in: 2_980,
        tokens_out: 512,
        cost_usd: 0.024,
        parent_id: id(:lead),
        depth: 1
      ),
      agent(:builder_4, base,
        name: "builder-4",
        role: :worker,
        model: "deepseek-v4-flash",
        provider_name: "llmotions",
        title: "Harden the token refresh path",
        step: "edit lib/swarm_code/repo.ex",
        progress: 40,
        tokens_in: 5_340,
        tokens_out: 1_320,
        cost_usd: 0.058,
        parent_id: id(:lead),
        depth: 1,
        changes_stat: "+42 −7"
      ),
      agent(:judge, base,
        name: "judge",
        role: :judge,
        title: "Judge · round 1",
        step: "queued",
        state: :queued,
        allowed_actions: [],
        progress: 0,
        tokens_in: 990,
        tokens_out: 258,
        cost_usd: 0.013,
        parent_id: id(:lead),
        depth: 1,
        started_at: nil
      )
    ]
  end

  defp agent(key, base, extra),
    do: struct!(%DTO.AgentSummary{id: id(key)}, Keyword.merge(base, extra))

  defp hive_changes do
    [
      change(:change_1, id(:builder_4), "lib/swarm_code/repo.ex", true, @clock_ms - 40_000, 1),
      change(
        :change_2,
        id(:builder_4),
        "test/swarm_code/repo_test.exs",
        true,
        @clock_ms - 30_000,
        1
      ),
      change(:change_3, id(:lead), "docs/architecture.md", false, @clock_ms - 20_000, 1)
    ]
  end

  defp change(key, agent_id, path, restorable, at, revision),
    do:
      struct!(
        %DTO.Change{
          id: id(key),
          run_id: id(:a2),
          agent_id: agent_id,
          path: path,
          restorable: restorable,
          at: at,
          revision: revision
        },
        Session.change_facts(id(key), path)
      )

  defp hive_verdict do
    %DTO.Verdict{
      id: id(:judge),
      run_id: id(:a2),
      round: 1,
      status: :done,
      checks: [
        %DTO.VerdictCheck{key: "tests_pass", ok: true, note: "142 tests, 0 failures"},
        %DTO.VerdictCheck{key: "no_regressions", ok: true, note: "auth paths unchanged"},
        %DTO.VerdictCheck{key: "docs_updated", ok: false, note: "architecture.md still draft"},
        %DTO.VerdictCheck{key: "style", ok: nil, note: "not evaluated"}
      ],
      summary: "Two of three proposals meet the bar; the docs change needs another pass.",
      revision: 1
    }
  end

  # First-barrier facts for the swarm run: tool one-liners, a thought, an
  # error, two agent steps, and a change and verdict revision.
  defp hive_facts(script) do
    tool = fn key, node, agent, tool, text, extra ->
      item(
        :a2,
        node,
        key,
        text,
        [kind: :tool, role: :tool, state: :done, agent_id: id(agent), tool: tool] ++ extra
      )
    end

    items = [
      tool.(
        "tool-A-2-1",
        :node_tool_1,
        :scout_1,
        %DTO.ToolCall{
          name: "grep",
          title: "grep \"Repo\\.\"",
          detail: "lib/ test/ · 41 hits",
          status: :done,
          started_at: @clock_ms - 70_000,
          finished_at: @clock_ms - 69_600,
          duration_ms: 400,
          result_bytes: 3_812,
          files: []
        },
        "lib/swarm_code/repo.ex:12\nlib/swarm_code/repo.ex:48\ntest/swarm_code/repo_test.exs:9",
        at: @clock_ms - 70_000,
        tokens_in: 812,
        tokens_out: 64
      ),
      tool.(
        "tool-A-2-2",
        :node_tool_2,
        :scout_2,
        %DTO.ToolCall{
          name: "read_file",
          title: "read test/session_test.exs",
          detail: "218 lines",
          status: :done,
          started_at: @clock_ms - 66_000,
          finished_at: @clock_ms - 65_880,
          duration_ms: 120,
          result_bytes: 7_144,
          files: ["test/session_test.exs"]
        },
        "defmodule SwarmCode.SessionTest do\n  use ExUnit.Case, async: true",
        at: @clock_ms - 66_000,
        tokens_in: 1_790,
        tokens_out: 51
      ),
      item(:a2, :node_thinking, "thinking-A-2", "",
        kind: :thinking,
        state: :done,
        agent_id: id(:lead),
        reasoning:
          "The refresh path and the session tests disagree about expiry; builder-4 should change the repository before the tests.",
        at: @clock_ms - 62_000,
        tokens_in: 2_240,
        tokens_out: 210
      ),
      tool.(
        "tool-A-2-3",
        :node_tool_3,
        :builder_4,
        %DTO.ToolCall{
          name: "edit_file",
          title: "edit lib/swarm_code/repo.ex",
          detail: "+42 −7",
          status: :done,
          started_at: @clock_ms - 45_000,
          finished_at: @clock_ms - 44_100,
          duration_ms: 900,
          result_bytes: 512,
          files: ["lib/swarm_code/repo.ex"],
          added: 42,
          removed: 7,
          diff_ref: Session.diff_ref(id(:node_tool_3))
        },
        "Replaced the refresh guard with an expiry check.",
        at: @clock_ms - 45_000,
        tokens_in: 3_020,
        tokens_out: 388
      ),
      item(
        :a2,
        :node_error,
        "error-A-2",
        "run_command failed: mix test exited with status 1 (2 failures).",
        kind: :error,
        role: :system,
        state: :failed,
        agent_id: id(:builder_4),
        at: @clock_ms - 41_000
      )
    ]

    scout_1 = %{
      script.agents[id(:scout_1)]
      | revision: 2,
        state: :done,
        allowed_actions: [],
        step: "done",
        progress: 100,
        tokens_in: 3_640,
        tokens_out: 702,
        finished_at: @clock_ms - 55_000
    }

    builder_4 = %{
      script.agents[id(:builder_4)]
      | revision: 2,
        step: "run mix test",
        progress: 65,
        tokens_in: 6_110,
        tokens_out: 1_540
    }

    change_3 = %{script.changes[id(:change_3)] | revision: 2, restorable: true}

    verdict = %{
      script.verdicts[id(:judge)]
      | revision: 2,
        summary: "Two of three proposals meet the bar; docs pass scheduled after the test fix."
    }

    if script.runs[id(:a2)].state in [:running, :streaming, :retrying] and
         Map.has_key?(script.agents, id(:scout_1)) and
         Map.has_key?(script.agents, id(:builder_4)) and
         Map.has_key?(script.changes, id(:change_3)) and
         Map.has_key?(script.verdicts, id(:judge)) and
         not Map.has_key?(script.transcript, "tool-A-2-1") do
      Enum.map(items, &fact(:node_upsert, &1)) ++
        [
          fact(:agent_update, scout_1),
          fact(:agent_update, builder_4),
          run_fact(script, :change_upsert, change_3),
          run_fact(script, :verdict_upsert, verdict)
        ]
    else
      []
    end
  end

  defp run_fact(script, kind, item),
    do: %Delta{
      kind: kind,
      entity_id: item.id,
      run_id: item.run_id,
      conversation_id: script.runs[item.run_id].conversation_id,
      body: item
    }

  defp question(key, run, node, revision, urgency, deadline),
    do: %DTO.PendingInteraction{
      id: id(key),
      run_id: id(run),
      node_id: id(node),
      conversation_id: id(if(run == :b1, do: :b, else: :a)),
      expected_revision: revision,
      question: %DTO.Question{
        prompt: "Which review should proceed?",
        options: [
          %DTO.QuestionOption{id: "option-1", label: "Authentication"},
          %DTO.QuestionOption{id: "option-2", label: "Authentication and tests"}
        ]
      },
      allowed_actions: [:answer_question],
      urgency: urgency,
      deadline: deadline,
      created_at: @clock_ms
    }

  defp catalogue_run(key, state, actions, revision),
    do: %DTO.RunSummary{
      id: id(key),
      conversation_id: id(:a),
      title: "Synthetic failed run",
      state: state,
      allowed_actions: actions,
      revision: revision
    }

  defp preserve_seen(script, item) do
    case Map.get(script.activity, item.id) do
      nil -> item
      previous -> %{item | seen_revision: max(item.seen_revision, previous.seen_revision)}
    end
  end

  defp activity(run) do
    kind =
      case run.state do
        :paused -> :paused
        :failed -> :failure
        :done -> :completion
        _ -> :running
      end

    %DTO.ActivityItem{
      id: run.id,
      run_id: run.id,
      conversation_id: run.conversation_id,
      kind: kind,
      state: run.state,
      title: run.title,
      revision: run.revision,
      seen_revision: run.seen_revision,
      allowed_actions: run.allowed_actions,
      created_at: @clock_ms
    }
  end

  defp interaction_activity(q),
    do: %DTO.ActivityItem{
      id: q.id,
      run_id: q.run_id,
      conversation_id: q.conversation_id,
      kind: q.kind,
      state: if(q.kind == :question, do: :waiting_question, else: :waiting_approval),
      title: "Synthetic pending interaction",
      revision: q.expected_revision,
      interaction: q,
      allowed_actions: q.allowed_actions,
      deadline: q.deadline,
      created_at: q.created_at
    }

  defp fact(kind, item),
    do: %Delta{
      kind: kind,
      entity_id: item.id,
      run_id: Map.get(item, :run_id, item.id),
      conversation_id: Map.get(item, :conversation_id),
      body: item
    }

  defp stream(item, channel, text),
    do: %Delta{
      kind: :stream_append,
      entity_id: item.id,
      run_id: item.run_id,
      conversation_id: item.conversation_id,
      channel: channel,
      attempt_id: item.attempt_id,
      text: text
    }
end
