defmodule SwarmCodeCLI.UI.Projector.Panel.Model do
  @moduledoc """
  What the side panel says, derived from the read model (pass72 P1-P5, R1-R7).

  Pure: every fact comes from the run and agent summaries, the pending
  interactions and the transcript the read model already holds. The pass-72
  wire fields (owner S: an agent's `now`, `lane`, `finding`, `finding_refs`,
  `files_changed`, a run's `needs_you`, `reported`/`total`, the kind facts)
  are read through `Map.get/3` with a default, so the panel works before and
  after they arrive; what is not known is left out, never invented (R5).
  """
  alias SwarmCodeCLI.UI.DataSource.Lane
  alias SwarmCodeCLI.UI.Projector.Support
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @p3 [:working, :thinking, :waiting, :needs_you, :done, :failed, :queued, :paused, :stopped]
  @lane_kinds [:think, :tools, :write, :you, :idle, :fail]
  @live [:queued, :running, :streaming, :waiting_question, :waiting_approval, :paused, :retrying]

  # ------------------------------------------------------------------ runs

  @doc "The run the transcript shows (R4), or `nil`."
  def in_chat(state), do: Support.run(state)

  @doc """
  The runs the panel draws, in display order: the run in chat first, then the
  other live runs, newest first. Superseded runs never show.
  """
  def runs(state) do
    chat = in_chat(state)

    others =
      state.read_model.runs
      |> Map.values()
      |> Enum.filter(&(&1.state in @live))
      |> Enum.reject(&(chat && &1.id == chat.id))
      |> Enum.sort_by(&{-&1.created_sequence, &1.id})

    if chat, do: [chat | others], else: others
  end

  @doc "Finished runs of the chat on screen, newest first, not counting the one in chat."
  def earlier(state, limit \\ 3) do
    chat = in_chat(state)
    conversation = chat && chat.conversation_id

    state.read_model.runs
    |> Map.values()
    |> Enum.filter(&(&1.conversation_id == conversation and &1.state not in @live))
    |> Enum.reject(&(&1.state == :superseded or (chat && &1.id == chat.id)))
    |> Enum.sort_by(&{-&1.created_sequence, &1.id})
    |> Enum.take(limit)
  end

  @doc "The run kind the theme knows (`:chat` is the assistant, `:consensus` the judge)."
  def kind(%{kind: :chat}), do: :assistant
  def kind(%{kind: :consensus}), do: :consensus_judge
  def kind(%{kind: kind}), do: kind

  @doc "The theme role of a run kind's mark."
  def kind_role(run) do
    case kind(run) do
      :assistant -> :text_primary
      :goal -> :run_goal
      :swarm -> :run_swarm
      :workflow -> :run_workflow
      :research -> :run_research
      :consensus_judge -> :run_consensus_judge
      :ultra -> :run_ultra
    end
  end

  @doc "Elapsed milliseconds of a run or an agent, up to now while it lives."
  def elapsed(%{started_at: s} = item, state) when is_integer(s) and s > 0 do
    finish = Map.get(item, :finished_at)

    cond do
      is_integer(finish) and finish >= s -> finish - s
      is_integer(state.now) and state.now >= s -> state.now - s
      true -> nil
    end
  end

  def elapsed(item, _state) do
    case Map.get(item, :elapsed_ms) do
      ms when is_integer(ms) and ms >= 0 -> ms
      _ -> nil
    end
  end

  @doc "`02:14` (a run's clock, R4 header)."
  def clock(nil), do: nil

  def clock(ms) do
    s = div(ms, 1000)
    m = div(s, 60)

    if m >= 60,
      do: "#{div(m, 60)}:#{pad2(rem(m, 60))}:#{pad2(rem(s, 60))}",
      else: "#{pad2(m)}:#{pad2(rem(s, 60))}"
  end

  @doc "`1:44` (an agent's elapsed)."
  def short_clock(nil), do: nil

  def short_clock(ms) do
    s = div(ms, 1000)
    m = div(s, 60)
    if m >= 60, do: "#{div(m, 60)}h#{pad2(rem(m, 60))}", else: "#{m}:#{pad2(rem(s, 60))}"
  end

  @doc "Tokens with `k` and no decimals under 100k (R6)."
  def tokens(n) when not is_integer(n) or n <= 0, do: nil
  def tokens(n) when n < 1_000, do: Integer.to_string(n)
  def tokens(n) when n < 1_000_000, do: "#{div(n + 500, 1000)}k"
  def tokens(n), do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "M"

  @doc "`$0.14` (R6); nil when unknown or zero."
  def money(cost) when is_number(cost) and cost > 0 and cost < 0.01,
    do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 3)

  def money(cost) when is_number(cost) and cost > 0,
    do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)

  def money(_), do: nil

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp tokens_of(agent) do
    case Map.get(agent, :tokens) do
      n when is_integer(n) and n > 0 -> n
      _ -> token_count(agent)
    end
  end

  @doc "Tokens in and out of a run or agent."
  def token_count(item), do: (Map.get(item, :tokens_in) || 0) + (Map.get(item, :tokens_out) || 0)

  # ---------------------------------------------------------------- agents

  @doc """
  The run's agents as panel rows, in panel order: the lead (or the one
  assistant of a chat turn) first, then the agents under it by depth and start.
  Each is a map of what R1 allows the panel to say.
  """
  def agents(state, run) do
    lanes = state |> Hive.lanes_for(run) |> Enum.map(&with_run_facts(&1, run))
    pending = pending(state, run)
    subs = Enum.reject(lanes, &lead?/1)
    affixes = affixes(Enum.map(subs, &Hive.name/1))

    {views, _} =
      Enum.map_reduce(lanes, 0, fn agent, index ->
        lead? = lead?(agent)
        view = view(agent, run, lanes, pending, affixes, if(lead?, do: nil, else: index), state)
        {view, if(lead?, do: index, else: index + 1)}
      end)

    views
  end

  defp lead?(%{role: role}), do: role in [:lead, :assistant]

  # A chat turn's one assistant stands for the run: the run summary carries
  # its sentence and lane.
  @run_facts [:lane, :now, :finding, :finding_refs, :files_changed, :activity]

  defp with_run_facts(%{role: :assistant, id: id} = agent, %{id: id} = run) do
    Enum.reduce(@run_facts, agent, fn key, acc ->
      case {Map.get(acc, key), Map.get(run, key)} do
        {nil, value} when not is_nil(value) -> Map.put(acc, key, value)
        _ -> acc
      end
    end)
  end

  defp with_run_facts(agent, _run), do: agent

  defp view(agent, run, lanes, pending, affixes, index, state) do
    asks = Enum.filter(pending, &asks_for?(&1, agent, lanes))
    p3 = p3_state(agent, lanes, asks)
    name = Hive.name(agent)
    trimmed = trim(name, affixes)

    %{
      id: agent.id,
      run_id: run.id,
      name: name,
      display: display_name(agent, trimmed),
      short: short(display_name(agent, trimmed)),
      role: agent.role,
      depth: Map.get(agent, :depth, 0),
      parent_id: Map.get(agent, :parent_id),
      name_role: name_role(agent, run, index),
      lane_role: lane_role(agent, run, index),
      state: p3,
      raw_state: agent.state,
      needs_you?: p3 == :needs_you,
      asks: asks,
      lane: lane(agent, state.now),
      now: now(agent),
      finding: finding(agent, state),
      refs: refs(agent, state),
      files_changed: Map.get(agent, :files_changed),
      error: present(agent.error),
      retry_at: Map.get(agent, :retry_at),
      elapsed: Lane.elapsed_ms(agent, state.now) || elapsed(agent, state),
      tokens: tokens_of(agent),
      cost: Map.get(agent, :cost_usd)
    }
  end

  defp display_name(%{role: :assistant}, _trimmed), do: "Assistant"
  defp display_name(%{role: :lead}, _trimmed), do: "Lead"
  defp display_name(_agent, trimmed), do: trimmed

  # Name colours (R11): lane colours for agents only; the lead and the one
  # assistant in text weight, the judge in its own role.
  defp name_role(%{role: role}, _run, _index) when role in [:lead, :assistant], do: :text_primary
  defp name_role(%{role: :judge}, _run, _index), do: :text_muted
  defp name_role(_agent, %{kind: :goal}, _index), do: :run_goal
  defp name_role(_agent, _run, index), do: lane_colour(index)

  defp lane_role(%{role: role}, _run, _index) when role in [:lead, :assistant], do: :text_primary
  defp lane_role(%{role: :judge}, _run, _index), do: :text_muted
  defp lane_role(_agent, %{kind: :goal}, _index), do: :run_goal
  defp lane_role(_agent, _run, index), do: lane_colour(index)

  defp lane_colour(nil), do: :text_primary
  defp lane_colour(index), do: :"agent_lane_#{rem(index, 5) + 1}"

  @doc """
  The agent's state in the one set (P3, R9). The wire's own P3 value wins;
  otherwise it is read off the domain state: waiting on you is `:needs_you`,
  a lead running while its agents run is `:waiting` (on them), a model call
  in flight is `:thinking`, tools are `:working`.
  """
  def p3_state(agent, lanes, asks \\ []) do
    explicit = Map.get(agent, :activity) || Map.get(agent, :panel_state)

    # The wire's own P3 state wins (owner S); `:working` is also its default,
    # so it is trusted only while the agent really runs.
    trusted? =
      explicit in @p3 and
        (explicit != :working or agent.state in [:running, :retrying])

    cond do
      trusted? -> explicit
      asks != [] -> :needs_you
      Words.waiting?(agent.state) -> :needs_you
      agent.state == :failed -> :failed
      agent.state in [:stopped, :interrupted, :superseded] -> :stopped
      agent.state == :done -> :done
      agent.state == :queued -> :queued
      agent.state == :paused -> :paused
      lead?(agent) and waiting_on_others?(agent, lanes) -> :waiting
      agent.state == :streaming -> :thinking
      true -> :working
    end
  end

  defp waiting_on_others?(lead, lanes) do
    lead.state in [:running, :streaming] and
      Enum.any?(lanes, fn a ->
        a.id != lead.id and
          a.state in [:running, :streaming, :waiting_approval, :waiting_question]
      end) and lead.state != :streaming
  end

  @doc "The state word (R9: every glyph is followed by its word in full mode)."
  def word(:working), do: "working"
  def word(:thinking), do: "thinking"
  def word(:waiting), do: "waiting"
  def word(:needs_you), do: "needs you"
  def word(:done), do: "done"
  def word(:failed), do: "failed"
  def word(:stopped), do: "stopped"
  def word(:queued), do: "queued"
  def word(:paused), do: "paused"

  @doc "The role of a state's glyph (R11)."
  def glyph_role(:needs_you), do: :warning
  def glyph_role(:failed), do: :error
  def glyph_role(:done), do: :success
  def glyph_role(state) when state in [:working, :thinking], do: :text_primary
  def glyph_role(:queued), do: :text_faint
  def glyph_role(_), do: :text_muted

  @doc "The role of a state's word."
  def word_role(:needs_you), do: :warning
  def word_role(:failed), do: :error
  def word_role(:done), do: :success
  def word_role(_), do: :text_muted

  # --------------------------------------------------------- the sentence

  @doc """
  The one sentence an agent row carries (R2): what it asks > its failure and
  retry > its finding once done > what it does now. `compact?` picks the
  action form of the request (`approve: mix test …`) over the short one
  (`wants to run a command`, since the band carries the text in full mode).
  """
  def sentence(view, state, compact? \\ false) do
    cond do
      view.state == :needs_you ->
        {ask_sentence(view, compact?), :warning}

      view.state == :failed ->
        {failure(view, state), :error}

      view.state == :done and view.finding ->
        {view.finding, :text_primary}

      true ->
        {now_sentence(view), :text_primary}
    end
  end

  defp ask_sentence(%{asks: [ask | _]}, true), do: answer_verb("approve: " <> ask.text, ask)
  defp ask_sentence(%{asks: [ask | _]}, false), do: short_ask(ask)
  defp ask_sentence(_view, _compact?), do: "waiting for your answer"

  defp answer_verb("approve: " <> text, %{verb: :question}), do: "answer: " <> text
  defp answer_verb(text, _ask), do: text

  @doc "What a pending interaction asks for, in five words (the full row)."
  def short_ask(%{verb: :question}), do: "waiting for your answer"
  def short_ask(%{verb: :command}), do: "wants to run a command"
  def short_ask(%{verb: :edit}), do: "wants to edit a file"
  def short_ask(%{verb: {:tool, tool}}), do: "wants to use " <> tool
  def short_ask(%{kind: :question}), do: "waiting for your answer"
  def short_ask(%{approval: %{tool: "run_command"}}), do: "wants to run a command"

  def short_ask(%{approval: %{tool: tool}})
      when tool in ["edit_file", "write_file", "edit_files"],
      do: "wants to edit a file"

  def short_ask(%{approval: %{tool: tool}}) when is_binary(tool) and tool != "",
    do: "wants to use " <> tool

  def short_ask(_ask), do: "needs your permission"

  @doc "The literal request (R3): the command, `edit <path>`, or the question."
  def request(%{kind: :question, question: %{prompt: prompt}}) when is_binary(prompt),
    do: first_line(prompt)

  def request(%{approval: %{command: command}}) when is_binary(command) and command != "",
    do: first_line(command)

  def request(%{approval: %{tool: tool, arguments_preview: preview}})
      when tool in ["edit_file", "write_file", "edit_files"],
      do: "edit " <> path_of(preview)

  def request(%{approval: %{tool: "run_command", arguments_preview: preview}})
      when is_binary(preview) do
    case Regex.run(~r/"command"\s*:\s*"((?:[^"\\]|\\.)*)"/, preview) do
      [_, command] -> command |> String.replace(~s(\\"), ~s(")) |> first_line()
      _ -> first_line(preview)
    end
  end

  def request(%{approval: %{arguments_preview: preview, tool: tool}}) when is_binary(preview),
    do: String.trim(tool <> " " <> first_line(preview))

  def request(%{text: text}) when is_binary(text), do: first_line(text)
  def request(_), do: ""

  defp path_of(preview) when is_binary(preview) do
    case Regex.run(~r/"(?:path|file_path|file)"\s*:\s*"([^"]+)"/, preview) do
      [_, path] -> path
      _ -> first_line(preview)
    end
  end

  defp path_of(_), do: ""

  defp failure(view, state) do
    base = view.error || "failed"

    retry =
      case view.retry_at do
        at when is_integer(at) and is_integer(state.now) and at > state.now ->
          " · retry in #{div(at - state.now + 999, 1000)} s"

        _ ->
          ""
      end

    first_line(base) <> retry
  end

  # With no words of its own the row says only what is not already the state
  # word; `""` leaves the sentence out.
  # A stopped agent's last `now` is no longer true, so it is not shown.
  defp now_sentence(%{state: :stopped}), do: "stopped before it finished"

  defp now_sentence(view) do
    view.now ||
      case view.state do
        :waiting -> "waiting on the others"
        :queued -> "not started yet"
        :stopped -> "stopped before it finished"
        :done -> "finished"
        _ -> ""
      end
  end

  # The server's own words, never an internal label: the isolation notice
  # ("isolated in swarm/…") and ids are not sentences (owner bug, P1).
  defp now(agent) do
    superseded =
      if Map.get(agent, :launched_by_superseded, false),
        do: SwarmCodeCLI.UI.SafeText.value(SwarmCodeCLI.UI.SafeText.chrome(:superseded_child))

    [superseded, Map.get(agent, :now), agent.step]
    |> Enum.map(&present/1)
    |> Enum.find(&sentence?/1)
    |> then(&(&1 && first_line(&1)))
  end

  # A step that only names a state is not a sentence ("queued queued").
  @bare_words ~w(queued running done failed waiting thinking working streaming paused stopped)

  @doc "Whether `text` may be shown as an agent's sentence (no isolation or branch text)."
  def sentence?(nil), do: false

  def sentence?(text) do
    String.downcase(text) not in @bare_words and
      not String.starts_with?(text, "isolated in ") and
      not Regex.match?(~r/\bswarm\/[0-9a-f]{6,}/, text)
  end

  # ------------------------------------------------------------- findings

  @doc "The agent's finding: the wire's, else the first sentence of its last report."
  def finding(agent, state) do
    case present(Map.get(agent, :finding)) do
      nil -> report(agent, state) |> first_sentence()
      text -> first_line(text)
    end
  end

  @doc "Up to five `path:line` references (the wire's, else parsed from the report)."
  def refs(agent, state) do
    case Map.get(agent, :finding_refs) do
      [_ | _] = refs -> Enum.take(refs, 5)
      _ -> parse_refs(report(agent, state))
    end
  end

  @ref ~r/(?<![\w\/])((?:[\w.-]+\/)*[\w.-]+\.[a-z]{1,5}:\d+)/

  defp parse_refs(nil), do: []

  defp parse_refs(text) do
    @ref
    |> Regex.scan(text)
    |> Enum.map(fn [_, ref | _] -> Path.basename(ref) end)
    |> Enum.uniq()
    |> Enum.take(5)
  end

  # A chat turn's one assistant stands for the run: its report is the answer.
  defp report(%{state: :done, id: id, role: :assistant}, state) do
    state.read_model.transcript
    |> Map.values()
    |> Enum.filter(&(&1.run_id == id and &1.kind == :text and &1.role == :assistant))
    |> Enum.max_by(&{&1.created_sequence, &1.id}, fn -> nil end)
    |> case do
      %{text: text} when is_binary(text) -> text
      _ -> nil
    end
  end

  defp report(%{state: :done, id: id}, state) do
    state.read_model.transcript
    |> Map.values()
    |> Enum.filter(&(Map.get(&1, :agent_id) == id and &1.kind == :text and &1.role != :user))
    |> Enum.max_by(&{&1.created_sequence, &1.id}, fn -> nil end)
    |> case do
      %{text: text} when is_binary(text) -> text
      _ -> nil
    end
  end

  defp report(_agent, _state), do: nil

  defp first_sentence(text), do: sentences(text, 1)

  @doc """
  The first `n` sentences of `text` as plain words: markdown marks, headings
  and list markers dropped, whitespace folded, at most 160 characters.
  """
  def sentences(nil, _n), do: nil

  def sentences(text, n) do
    text
    |> String.replace(~r/^\s*(#+|[-*+]|\d+\.)\s+/m, "")
    |> String.replace(~r/[#*`>]+/, " ")
    |> String.split(["\n\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != "" and sentence?(&1)))
    |> case do
      nil ->
        nil

      para ->
        para
        |> String.replace(~r/\s+/, " ")
        |> String.split(~r/(?<=[.!?])\s/)
        |> Enum.take(n)
        |> Enum.join(" ")
        |> String.trim()
        |> then(&if(n == 1, do: String.trim_trailing(&1, "."), else: &1))
        |> String.slice(0, 160)
    end
  end

  # ---------------------------------------------------------------- lanes

  @doc """
  The rolling 60-second lane (P4): the wire's cells, newest last, as kinds
  `:think | :tools | :write | :you | :idle | :fail`; `nil` when the wire sent
  none (the row then carries only the sentence: an unknown lane is not drawn).
  """
  def lane(agent, now \\ nil) do
    cells = if is_list(Map.get(agent, :lane)), do: Lane.window(agent, now, 12), else: []

    case cells do
      cells when is_list(cells) and cells != [] -> Enum.map(cells, &lane_kind/1)
      _ -> nil
    end
  end

  defp lane_kind(:wait_you), do: :you
  defp lane_kind(kind) when kind in @lane_kinds, do: kind
  defp lane_kind(kind) when is_binary(kind), do: kind |> known_kind()
  defp lane_kind(_), do: :idle

  for k <- @lane_kinds, do: defp(known_kind(unquote(Atom.to_string(k))), do: unquote(k))
  defp known_kind("thinking"), do: :think
  defp known_kind("tool"), do: :tools
  defp known_kind(_), do: :idle

  @doc "The last `n` cells of a lane, padded with idle on the left."
  def window(nil, _n), do: nil

  def window(cells, n) do
    kept = Enum.take(cells, -n)
    List.duplicate(:idle, n - length(kept)) ++ kept
  end

  # ------------------------------------------------------------ needs you

  @doc """
  What waits on you in `run`, oldest first, as asks `%{id, kind, text, verb,
  agent_id, node_id, at}`: the run summary's `needs_you` (owner S's band
  entries) when it has any, else the run's pending interactions.
  """
  def pending(state, run) do
    case Map.get(run, :needs_you) do
      [_ | _] = wire ->
        wire |> Enum.map(&from_wire/1) |> Enum.sort_by(&{&1.at, &1.id})

      _ ->
        state.read_model.interactions
        |> Map.values()
        |> Enum.filter(&(&1.state == :pending and &1.run_id == run.id))
        |> Enum.map(&from_interaction/1)
        |> Enum.sort_by(&{&1.at, &1.id})
    end
  end

  defp from_wire(entry) do
    text = first_line(Map.get(entry, :text) || "")
    kind = Map.get(entry, :kind, :approval)

    %{
      id: Map.get(entry, :node_id) || Map.get(entry, :agent_id) || text,
      kind: kind,
      text: text,
      verb: wire_verb(kind, text),
      agent_id: Map.get(entry, :agent_id),
      node_id: Map.get(entry, :node_id),
      at: Map.get(entry, :requested_at) || 0
    }
  end

  defp wire_verb(:question, _text), do: :question
  defp wire_verb(:gate, _text), do: :question
  defp wire_verb(_kind, "edit " <> _), do: :edit
  defp wire_verb(_kind, _text), do: :command

  defp from_interaction(interaction) do
    tool = interaction.approval && interaction.approval.tool

    verb =
      cond do
        interaction.kind == :question -> :question
        tool == "run_command" -> :command
        tool in ["edit_file", "write_file", "edit_files"] -> :edit
        is_binary(tool) and tool != "" -> {:tool, tool}
        true -> :command
      end

    %{
      id: interaction.id,
      kind: interaction.kind,
      text: request(interaction),
      verb: verb,
      agent_id: interaction.approval && interaction.approval.agent_id,
      node_id: interaction.node_id,
      at: interaction.created_at
    }
  end

  defp asks_for?(ask, agent, lanes) do
    waiting = Enum.filter(lanes, &Words.waiting?(&1.state))

    cond do
      is_binary(ask.agent_id) -> ask.agent_id == agent.id
      ask.node_id == agent.id -> true
      Enum.any?(lanes, &(&1.id == ask.node_id)) -> false
      # The op node is not an agent: the one agent waiting on you asked.
      length(waiting) == 1 -> hd(waiting).id == agent.id
      # Otherwise the lead (or the one assistant) asked.
      true -> lead?(agent)
    end
  end

  @doc """
  Everything waiting on you across `runs`, oldest first: `{interaction, run,
  agent view}` (the agent may be nil when the read model does not hold it).
  """
  def needs(state, runs, views_by_run) do
    runs
    |> Enum.flat_map(fn run ->
      views = Map.get(views_by_run, run.id, [])

      pending(state, run)
      |> Enum.map(fn ask ->
        view = Enum.find(views, fn v -> Enum.any?(v.asks, &(&1.id == ask.id)) end)
        {ask, run, view}
      end)
    end)
    |> Enum.sort_by(fn {ask, _run, _view} -> {ask.at, ask.id} end)
  end

  # ---------------------------------------------------------------- names

  @doc """
  The prefix and suffix every sibling shares (R14), as `{prefix, suffix}`;
  only a hyphenated affix of two or more siblings counts, and never one that
  would leave a name empty.
  """
  def affixes(names) when length(names) < 3, do: {"", ""}

  # Only the shared suffix is dropped (`*-review`); a shared prefix names the
  # kind of worker ("reader-docs", "reader-code") and stays.
  def affixes(names) do
    suffix = common(Enum.map(names, &(String.split(&1, "-") |> Enum.reverse())))
    prefix = []
    suffix = if suffix == [], do: "", else: "-" <> (suffix |> Enum.reverse() |> Enum.join("-"))
    prefix = if prefix == [], do: "", else: Enum.join(prefix, "-") <> "-"

    if Enum.any?(names, &(byte_size(&1) <= byte_size(prefix) + byte_size(suffix))),
      do: {"", ""},
      else: {prefix, suffix}
  end

  defp common([first | rest]) do
    first
    |> Enum.with_index()
    |> Enum.take_while(fn {part, i} -> Enum.all?(rest, &(Enum.at(&1, i) == part)) end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(max(0, min_len([first | rest]) - 1))
  end

  defp min_len(lists), do: lists |> Enum.map(&length/1) |> Enum.min()

  defp trim(name, {prefix, suffix}) do
    name
    |> then(&if(prefix != "", do: String.replace_prefix(&1, prefix, ""), else: &1))
    |> then(&if(suffix != "", do: String.replace_suffix(&1, suffix, ""), else: &1))
  end

  @doc "A short name of at most 8 cells for the compact row (P6, R14)."
  def short(name) do
    first = name |> String.split(["-", " ", "_"], trim: true) |> List.first() || name

    cond do
      String.length(name) <= 8 -> name
      String.length(first) <= 8 -> first
      true -> String.slice(name, 0, 7) <> "…"
    end
  end

  # ------------------------------------------------------------- helpers

  @doc "The first line of `text`, trimmed."
  def first_line(text) when is_binary(text),
    do: text |> String.split(["\r\n", "\n"], parts: 2) |> hd() |> String.trim()

  def first_line(_), do: ""

  def present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  def present(_), do: nil
end
