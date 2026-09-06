defmodule SwarmCodeCLI.UI.DataSource.Fake.Script do
  @moduledoc """
  Pure synthetic canonical facts and explicit virtual-clock barriers. Decoding
  accepts a bounded committed fixture, never a filename or arbitrary operation.
  """
  alias SwarmCode.Protocol.JsonLimits
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delta, DTO, Request}
  alias DTO.Schema

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
    request: "00000000-0000-4000-8000-000000000001"
  }
  defstruct clock: @clock,
            runs: %{},
            agents: %{},
            transcript: %{},
            interactions: %{},
            activity: %{},
            statuses: [],
            sequence: 0,
            revision: 0,
            barriers: @barriers,
            completed: []

  @type t :: %__MODULE__{
          clock: binary(),
          runs: %{binary() => DTO.RunSummary.t()},
          agents: %{binary() => DTO.AgentSummary.t()},
          transcript: %{binary() => DTO.TranscriptItem.t()},
          interactions: %{binary() => DTO.PendingInteraction.t()},
          activity: %{binary() => DTO.ActivityItem.t()},
          statuses: [DTO.StatusEntry.t()],
          sequence: non_neg_integer(),
          revision: non_neg_integer(),
          barriers: [binary()],
          completed: [binary()]
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
      script = %__MODULE__{runs: Map.new(decoded, &{&1.id, &1})}

      transcript = [
        item(:a1, :node_a1, "message-A-1", "Authentication review started."),
        item(:a2, :node_a2, "message-A-2", "Swarm plan\nReview authentication\nand its tests"),
        item(:b1, :node_b1, "message-B-1", "Research started.")
      ]

      validate(%{
        script
        | transcript: Map.new(transcript, &{&1.id, &1}),
          activity: Map.new(decoded, fn run -> {run.id, activity(run)} end)
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
      map_size(script) == 12 and Enum.all?(Map.keys(%__MODULE__{}), &Map.has_key?(script, &1)) and
        script.clock == @clock and script.barriers == @barriers and
        Schema.valid?(:revision, script.sequence) and Schema.valid?(:revision, script.revision) and
        Enum.all?(
          [
            {script.runs, DTO.RunSummary},
            {script.agents, DTO.AgentSummary},
            {script.transcript, DTO.TranscriptItem},
            {script.interactions, DTO.PendingInteraction},
            {script.activity, DTO.ActivityItem}
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
        supported_permissions?(script)

    if valid, do: {:ok, script}, else: {:error, AdmissionError.new(:invalid_fixture)}
  end

  def validate(_), do: {:error, AdmissionError.new(:invalid_fixture)}

  defp supported_permissions?(script) do
    Enum.all?(
      [script.runs, script.agents, script.transcript, script.interactions, script.activity],
      fn items ->
        Enum.all?(items, fn {_, item} ->
          Enum.all?(item.allowed_actions, &(&1 not in [:send, :queue, :steer, :mark_seen]))
        end)
      end
    )
  end

  defp canonical_references?(script) do
    Enum.all?([:a1, :a2, :b1], &Map.has_key?(script.runs, id(&1))) and
      Enum.all?(
        ["message-A-1", "message-A-2", "message-B-1"],
        &Map.has_key?(script.transcript, &1)
      ) and
      Enum.all?(script.agents, fn {_, item} -> Map.has_key?(script.runs, item.run_id) end) and
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
        allowed_actions: [:stop]
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

  defp do_apply_deltas(script, deltas) do
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
        activity: Map.put(script.activity, run.id, activity(run))
    }

  defp apply_delta(%Delta{kind: :agent_update, body: agent}, script),
    do: %{script | agents: Map.put(script.agents, agent.id, agent)}

  defp apply_delta(%Delta{kind: :interaction_upsert, body: interaction}, script),
    do: %{
      script
      | interactions: Map.put(script.interactions, interaction.id, interaction),
        activity: Map.put(script.activity, interaction.id, interaction_activity(interaction))
    }

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
    with :ok <- scope_allows(script, request),
         {:ok, deltas, identifiers} <- command_deltas(script, request.kind) do
      case apply_deltas(script, deltas) do
        {:error, _} = error ->
          error

        {next, deltas} ->
          with {:ok, next, deltas} <- validate_transition(next, deltas) do
            {:ok, next,
             %DTO.Outcome{
               status: :accepted,
               request_id: request.request_id,
               identifiers: identifiers
             }, deltas}
          end
      end
    else
      {:error, code} -> {:error, AdmissionError.new(code)}
    end
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
          :stop -> {:stopped, []}
          :pause -> {:paused, [:continue, :stop]}
          operation when operation in [:continue, :resume] -> {:running, [:pause, :stop]}
        end

      run_delta =
        fact(:run_update, %{
          run
          | state: state,
            revision: run.revision + 1,
            allowed_actions: actions
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
         do: resolve_interaction(script, q)
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
    run = %{
      Map.fetch!(script.runs, q.run_id)
      | state: :running,
        revision: script.runs[q.run_id].revision + 1,
        allowed_actions: [:pause, :stop]
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

  defp item(run, node, message, text),
    do: %DTO.TranscriptItem{
      id: message,
      run_id: id(run),
      node_id: id(node),
      conversation_id: id(if(run == :b1, do: :b, else: :a)),
      revision: 1,
      text: text,
      attempt_id: "attempt-1",
      allowed_actions: [:inspect, :copy, :fork]
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
