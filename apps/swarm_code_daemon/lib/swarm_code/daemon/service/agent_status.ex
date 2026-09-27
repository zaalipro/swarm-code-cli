defmodule SwarmCode.Daemon.Service.AgentStatus do
  @moduledoc "pass75: the per-agent AI status lines (the Summarizer): decisions, prompt, honesty check and the state PersistedBackend owns."

  require Logger

  alias SwarmCode.Daemon.Service.PanelFacts
  alias SwarmCode.Domain.LLM
  alias SwarmCode.Domain.LLM.Request

  # calls/call_runs: calls started per run in this session, newest run first
  # (at most @max_runs). The rest is per agent: the last call's time, fact key
  # and number, the call in flight (and its task ref), the held summary, the
  # one timer (debounce wait or quiet crossing), the agents whose final call
  # was made and those whose failure was logged.
  defstruct calls: %{},
            call_runs: [],
            last_call_ms: %{},
            keys: %{},
            seq: %{},
            pending: %{},
            refs: %{},
            summaries: %{},
            timers: %{},
            frozen: MapSet.new(),
            logged: MapSet.new()

  @type t :: %__MODULE__{}

  @debounce_ms 45_000
  @quiet_ms 60_000
  @max_calls_per_run 120
  @max_runs 64
  @deadline_ms 10_000
  @max_words 7
  @max_bytes 80
  @task_chars 300
  @events 8
  @event_chars 120
  @result_chars 400

  @system "You write one status line for a coding agent's panel row. Answer with 3 to 5 words, present tense, lower case, no punctuation, no numbers or file names that are not in the notes. Answer with the words only."

  @live_runs ["running", "waiting_user"]
  @quotes ["\"", "'"]
  @token ~r/[^\p{L}\p{N}\/._-]+/u
  @checked ~r/\d|\/|\w\.\w|_/

  ## ------------------------------------------------------------------ notes

  @doc """
  What the model reads about one agent: its display name, the head of its
  task, its last #{@events} operations (oldest first, then its result's head
  when it has one) and the vocabulary `accept/2` checks names against.
  """
  @spec notes(map(), [map()]) :: map()
  def notes(node, ops) do
    title = present(Map.get(node, :title)) || Map.get(node, :name) || ""
    task = String.slice(Map.get(node, :prompt_head) || "", 0, @task_chars)

    events =
      ops
      |> Enum.sort_by(
        &{PanelFacts.ms(Map.get(&1, :started_at) || Map.get(&1, :inserted_at)) || 0, &1.id}
      )
      |> Enum.take(-@events)
      |> Enum.map(fn op ->
        detail = Map.get(op, :detail)

        (Map.get(op, :title) || "") <>
          if(present(detail), do: " — " <> String.slice(detail, 0, @event_chars), else: "")
      end)

    events =
      case present(Map.get(node, :result_head)) do
        nil -> events
        head -> events ++ ["result: " <> String.slice(head, 0, @result_chars)]
      end

    vocabulary =
      [title, task | events]
      |> Enum.flat_map(&String.split(String.downcase(&1), @token, trim: true))
      |> MapSet.new()

    %{title: title, task: task, events: events, vocabulary: vocabulary}
  end

  @doc """
  The facts a call is made for: the agent's panel state, its newest finished
  operation and whether it has gone quiet. Tokens, cost and the turn are not
  in it, so a tick of those alone never causes a call.
  """
  @spec fact_key(map(), [map()], non_neg_integer()) :: integer()
  def fact_key(node, ops, now_ms) do
    newest_finished =
      ops
      |> Enum.filter(&(Map.get(&1, :finished_at) != nil))
      |> Enum.max_by(&PanelFacts.ms(&1.finished_at), fn -> nil end)
      |> case do
        nil -> nil
        op -> op.id
      end

    anchor = PanelFacts.anchor(ops)
    quiet? = is_integer(anchor) and now_ms - anchor >= @quiet_ms

    :erlang.phash2({PanelFacts.state(node, ops, []), newest_finished, quiet?})
  end

  ## --------------------------------------------------------------- decisions

  @doc """
  Whether to call the model for `agent` now: `{:call, status, seq}` (the call
  is counted), `{:wait, status, ms}` (the debounce holds it) or
  `{:skip, status}`. `now_ms` is the caller's clock (unix ms).
  """
  @spec decide(t(), map(), map(), non_neg_integer()) ::
          {:call, t(), pos_integer()} | {:wait, t(), pos_integer()} | {:skip, t()}
  def decide(%__MODULE__{} = status, agent, run, now_ms) do
    last = Map.get(status.last_call_ms, agent.id)

    cond do
      skip?(status, agent, run) ->
        {:skip, status}

      Map.get(status.keys, agent.id) == agent.key ->
        {:skip, status}

      is_integer(last) and now_ms - last < @debounce_ms ->
        {:wait, status, @debounce_ms - (now_ms - last)}

      true ->
        seq = Map.get(status.seq, agent.id, 0) + 1

        status = %{
          bump_run(status, run.id)
          | keys: Map.put(status.keys, agent.id, agent.key),
            last_call_ms: Map.put(status.last_call_ms, agent.id, now_ms),
            seq: Map.put(status.seq, agent.id, seq)
        }

        status =
          if agent.stopped?,
            do: %{
              status
              | frozen: MapSet.put(status.frozen, agent.id),
                summaries: Map.delete(status.summaries, agent.id)
            },
            else: status

        {:call, status, seq}
    end
  end

  @doc """
  Whether `agent` of `run` can get a line at all: not a lead or a plain
  chat's assistant, a live run, not frozen, the run's calls not spent. A call
  in flight or unchanged facts do not make it ineligible.
  """
  @spec eligible?(t(), map(), map()) :: boolean()
  def eligible?(%__MODULE__{} = status, agent, run) do
    not (agent.role == "lead" or (agent.role == "assistant" and run.kind == "chat") or
           run.status not in @live_runs or MapSet.member?(status.frozen, agent.id) or
           Map.get(status.calls, run.id, 0) >= @max_calls_per_run)
  end

  defp skip?(status, agent, run),
    do: not eligible?(status, agent, run) or Map.has_key?(status.pending, agent.id)

  defp bump_run(status, run_id) do
    calls = Map.update(status.calls, run_id, 1, &(&1 + 1))
    call_runs = [run_id | List.delete(status.call_runs, run_id)]

    if length(call_runs) > @max_runs do
      {kept, [dropped]} = Enum.split(call_runs, @max_runs)
      %{status | calls: Map.delete(calls, dropped), call_runs: kept}
    else
      %{status | calls: calls, call_runs: call_runs}
    end
  end

  @doc "Records the call in flight for `agent_id`."
  @spec started(t(), String.t(), pos_integer(), reference(), pid()) :: t()
  def started(%__MODULE__{} = status, agent_id, seq, ref, pid) do
    %{
      status
      | pending: Map.put(status.pending, agent_id, {seq, ref, pid}),
        refs: Map.put(status.refs, ref, agent_id)
    }
  end

  ## ------------------------------------------------------------------- call

  @doc "The model request for one status line."
  @spec request(map(), %{provider: struct(), model: String.t()}) :: Request.t()
  def request(notes, %{provider: provider, model: model}) do
    %Request{
      provider: provider,
      model: model,
      system: @system,
      messages: [%{role: "user", content: user_text(notes)}],
      max_tokens: 2048,
      temperature: 0.0,
      effort: if(provider.kind == "anthropic", do: "low"),
      deadline_ms: @deadline_ms
    }
  end

  defp user_text(notes) do
    "agent: " <>
      notes.title <>
      "\ntask: " <>
      notes.task <> "\nrecent:\n" <> Enum.map_join(notes.events, "\n", &("- " <> &1))
  end

  @doc "The default `work.summarize`: one model call, the text it answered."
  @spec summarize(map(), %{provider: struct(), model: String.t()}) ::
          {:ok, String.t()} | {:error, term()}
  def summarize(notes, model) do
    case LLM.stream(request(notes, model), fn _ -> :ok end) do
      {:ok, %{text: text}} when is_binary(text) -> {:ok, text}
      {:error, reason} -> {:error, reason}
      # A classified provider error; its message stays out of the log line.
      {:error, kind, _message} -> {:error, kind}
      other -> {:error, {:unexpected, other}}
    end
  end

  @doc """
  The honesty check: the answer's first line, unquoted, without its final
  full stop, lower case, 1-#{@max_words} words and at most #{@max_bytes} bytes,
  every word with a digit, a slash, a dot inside it or an underscore taken
  from the notes. Anything else is `:reject`.
  """
  @spec accept(String.t(), map()) :: {:ok, String.t()} | :reject
  def accept(text, notes) when is_binary(text) do
    t =
      text
      |> String.split(~r/\r?\n/, parts: 2)
      |> hd()
      |> String.trim()
      |> unquote_once()
      |> drop_full_stop()
      |> String.downcase()

    words = String.split(t, ~r/\s+/u, trim: true)

    cond do
      words == [] -> :reject
      length(words) > @max_words -> :reject
      byte_size(t) > @max_bytes -> :reject
      Enum.any?(words, &unknown_name?(&1, notes.vocabulary)) -> :reject
      true -> {:ok, Enum.join(words, " ")}
    end
  end

  def accept(_text, _notes), do: :reject

  defp unquote_once(text) do
    text =
      case String.next_grapheme(text) do
        {first, rest} when first in @quotes -> rest
        _ -> text
      end

    case String.last(text) do
      last when last in @quotes -> String.slice(text, 0..-2//1)
      _ -> text
    end
  end

  defp drop_full_stop(text) do
    if String.ends_with?(text, "."), do: String.slice(text, 0..-2//1), else: text
  end

  defp unknown_name?(word, vocabulary) do
    word =
      word
      |> String.trim_trailing(",")
      |> String.trim_trailing(";")
      |> String.trim_trailing(":")

    Regex.match?(@checked, word) and not MapSet.member?(vocabulary, word)
  end

  ## ---------------------------------------------------------------- results

  @doc """
  A call's outcome arrived: the call is no longer pending; a new text is kept
  unless a newer call's text is already held. The outcome of a call that was
  ended (its ref is no longer held) changes nothing.
  """
  @spec settle(
          t(),
          reference(),
          String.t(),
          pos_integer(),
          {:ok, String.t()} | :reject | {:error, term()}
        ) :: {:changed | :unchanged, t()}
  def settle(%__MODULE__{refs: refs} = status, ref, _agent_id, _seq, _outcome)
      when not is_map_key(refs, ref),
      do: {:unchanged, status}

  def settle(%__MODULE__{} = status, ref, agent_id, seq, outcome) do
    status = %{
      status
      | refs: Map.delete(status.refs, ref),
        pending: drop_pending(status, agent_id, ref)
    }

    case outcome do
      {:ok, text} when is_binary(text) ->
        case Map.get(status.summaries, agent_id) do
          {held, _text} when held >= seq ->
            {:unchanged, status}

          _none_or_older ->
            {:changed, %{status | summaries: Map.put(status.summaries, agent_id, {seq, text})}}
        end

      {:error, reason} ->
        if MapSet.member?(status.logged, agent_id) do
          {:unchanged, status}
        else
          Logger.debug("agent status: #{inspect(reason)}")
          {:unchanged, %{status | logged: MapSet.put(status.logged, agent_id)}}
        end

      _reject ->
        {:unchanged, status}
    end
  end

  defp drop_pending(status, agent_id, ref) do
    case Map.get(status.pending, agent_id) do
      {_seq, ^ref, _pid} -> Map.delete(status.pending, agent_id)
      _ -> status.pending
    end
  end

  @doc "The task behind `ref` died without answering: its agent is free again."
  @spec down(t(), reference()) :: {String.t() | nil, t()}
  def down(%__MODULE__{} = status, ref) do
    case Map.pop(status.refs, ref) do
      {nil, _refs} ->
        {nil, status}

      {agent_id, refs} ->
        {agent_id, %{status | refs: refs, pending: drop_pending(status, agent_id, ref)}}
    end
  end

  @doc "The held `{text, seq}` of an agent, whatever its facts now; `{nil, nil}` when none."
  @spec summary(t(), String.t()) :: {String.t() | nil, pos_integer() | nil}
  def summary(%__MODULE__{} = status, agent_id) do
    case Map.get(status.summaries, agent_id) do
      {seq, text} -> {text, seq}
      nil -> {nil, nil}
    end
  end

  ## ----------------------------------------------------------------- timers

  @doc "Stores the agent's timer and returns the one it replaced (the caller cancels it)."
  @spec put_timer(t(), String.t(), reference()) :: {reference() | nil, t()}
  def put_timer(%__MODULE__{} = status, agent_id, ref) do
    {Map.get(status.timers, agent_id), %{status | timers: Map.put(status.timers, agent_id, ref)}}
  end

  @doc "Forgets the agent's timer (it fired)."
  @spec clear_timer(t(), String.t()) :: t()
  def clear_timer(%__MODULE__{} = status, agent_id),
    do: %{status | timers: Map.delete(status.timers, agent_id)}

  ## -------------------------------------------------------------- ownership

  @doc """
  Keeps the per-agent entries of the listed agents only; a dropped agent's
  call in flight and timer are ended. `calls` and `call_runs` are kept.
  """
  @spec retain(t(), [String.t()], pid() | atom()) :: t()
  def retain(%__MODULE__{} = status, agent_ids, supervisor) do
    keep = MapSet.new(agent_ids)

    dropped =
      (Map.keys(status.pending) ++ Map.keys(status.timers))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(keep, &1))

    status = cancel(status, dropped, supervisor)

    %{
      status
      | last_call_ms: Map.take(status.last_call_ms, agent_ids),
        keys: Map.take(status.keys, agent_ids),
        seq: Map.take(status.seq, agent_ids),
        pending: Map.take(status.pending, agent_ids),
        refs: Map.filter(status.refs, fn {_ref, id} -> MapSet.member?(keep, id) end),
        summaries: Map.take(status.summaries, agent_ids),
        timers: Map.take(status.timers, agent_ids),
        frozen: MapSet.intersection(status.frozen, keep),
        logged: MapSet.intersection(status.logged, keep)
    }
  end

  @doc """
  Ends the listed agents' calls in flight and timers; their summaries stay
  (the last line stays while the run is in the window).
  """
  @spec cancel(t(), [String.t()], pid() | atom()) :: t()
  def cancel(%__MODULE__{} = status, agent_ids, supervisor) do
    Enum.reduce(agent_ids, status, fn agent_id, acc ->
      acc =
        case Map.pop(acc.pending, agent_id) do
          {{_seq, ref, pid}, pending} ->
            Process.demonitor(ref, [:flush])
            _ = Task.Supervisor.terminate_child(supervisor, pid)
            %{acc | pending: pending, refs: Map.delete(acc.refs, ref)}

          {nil, _pending} ->
            acc
        end

      case Map.pop(acc.timers, agent_id) do
        {nil, _timers} ->
          acc

        {timer, timers} ->
          Process.cancel_timer(timer)
          %{acc | timers: timers}
      end
    end)
  end

  @doc "Ends every call in flight and every timer; `calls` and `summaries` stay."
  @spec cancel_all(t(), pid() | atom()) :: t()
  def cancel_all(%__MODULE__{} = status, supervisor),
    do: cancel(status, Enum.uniq(Map.keys(status.pending) ++ Map.keys(status.timers)), supervisor)

  defp present(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp present(_value), do: nil
end
