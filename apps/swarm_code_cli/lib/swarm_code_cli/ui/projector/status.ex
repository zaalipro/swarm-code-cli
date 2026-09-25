defmodule SwarmCodeCLI.UI.Projector.Status do
  @moduledoc """
  The one line of chrome at the bottom (ux M5): what the session is set to and
  what it has cost, then, against the right edge, either a toast or the two
  keys worth a reminder in this context.

      Build · auto · deepseek-v4.1-flash · ctx 19k · $0.04 · 1 waiting     Esc interrupt  ? keys

  The left side is mode, approval mode and trust (when the daemon says them),
  the chat model, the context the last step used, the conversation's cost, and
  anything waiting on the user. Feedback that used to be pinned under the
  headline (`REJECTED`, `PENDING`, a command's report) is a toast here in
  words. The hints are read off `UI.Keymap.Bindings` for the current context,
  so a rebind can never leave the row advertising a key that does something
  else. Nothing on this row is an id, a focus name or a cue prefix.
  """
  alias SwarmCodeCLI.UI.{SafeText, SlashPalette, Width}
  alias SwarmCodeCLI.UI.Keymap.{Bindings, Context}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Composer, Density, KeyLabel, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns

  @composer_contexts [:composer, :composer_normal, :composer_visual]

  def project(state, class, width) do
    policy = state.capabilities.ambiguous_width
    context = Context.of(state)
    budget = if class in [:xl, :wide, :medium], do: 2, else: 1

    lead = [gap(" ", state)] ++ vim_spans(state, context) ++ select_spans(state)
    lead_cells = cells(lead, policy)
    parts = facts(state, class)
    toast = toast(state)

    right =
      toast ||
        if(select_mode?(state), do: select_hints(state), else: hints(state, context, budget))

    right = if right == [], do: [], else: right ++ [gap(" ", state)]

    # The hints give way before the facts that matter most (mode, waiting,
    # a rate limit, the connection); the other facts give way to the hints,
    # least useful first, rather than being cut mid-word at the edge.
    right =
      if toast == nil and right != [] and
           lead_cells + cells(render(essential(parts), state), policy) + cells(right, policy) + 2 >
             width,
         do: [],
         else: right

    right_cells = cells(right, policy)
    room = if right == [], do: width - lead_cells, else: width - lead_cells - right_cells - 2
    left = lead ++ render(fit(parts, room, policy, state), state)
    left_cells = cells(left, policy)

    spans =
      cond do
        right != [] and left_cells + right_cells + 2 <= width ->
          left ++ [gap(String.duplicate(" ", width - left_cells - right_cells), state)] ++ right

        # Feedback outranks the facts: they give up their tail so it is read.
        toast != nil ->
          kept = clip(left, max(0, width - right_cells - 2), policy, state)
          pad = max(0, width - cells(kept, policy) - right_cells)
          clip(kept ++ [gap(String.duplicate(" ", pad), state)] ++ right, width, policy, state)

        true ->
          clip(left, width, policy, state)
      end

    [%Block.RichText{spans: spans}]
  end

  @doc "How many approvals and questions are waiting on the user, across every run."
  def waiting_count(state) do
    runs = state.read_model.runs

    state.read_model.interactions
    |> Map.values()
    |> Enum.count(
      &(&1.state == :pending and not match?(%{state: :superseded}, Map.get(runs, &1.run_id)))
    )
  end

  # With vim on and the composer focused the row leads with the mode.
  defp vim_spans(%{keymap: :vim} = state, context) when context in @composer_contexts do
    {word, role} =
      case state.vim.mode do
        :insert -> {"INSERT", :success}
        :normal -> {"NORMAL", :accent}
        :visual -> {"VISUAL", :warning}
      end

    showcmd =
      case state.vim do
        %{count: nil, pending: nil} ->
          ""

        %{count: count, pending: pending} ->
          " " <> if(count, do: Integer.to_string(count), else: "") <> (pending || "")
      end

    [span(word <> showcmd, tint(:plain, state, role, [:bold]), state), gap("  ", state)]
  end

  defp vim_spans(_state, _context), do: []

  # Select mode (E1: Ctrl-T; focus on the transcript or the inspector with no
  # layer open) says so at the lead, and its keys replace the composer's.
  defp select_mode?(state), do: state.focus in ["main", "inspector"] and state.layers == []

  defp select_spans(state) do
    if select_mode?(state),
      do: [span("SELECT", tint(:plain, state, :accent, [:bold]), state), gap("  ", state)],
      else: []
  end

  defp select_hints(state) do
    ascii? = state.capabilities.ascii?
    overrides = SwarmCodeCLI.UI.Keymap.overrides(state)
    first = fn id -> id |> Bindings.keys_for(overrides) |> List.first() end

    move =
      case {first.(:move_next), first.(:move_previous)} do
        {nil, _} ->
          []

        {down, nil} ->
          [{KeyLabel.label(down, ascii?), "move"}]

        {down, up} ->
          [{KeyLabel.label(down, ascii?) <> "/" <> KeyLabel.label(up, ascii?), "move"}]
      end

    rest =
      for {id, words} <- [activate: "open", copy_selection: "copy", escape: "back"],
          key = first.(id),
          key != nil,
          do: {KeyLabel.label(key, ascii?), words}

    (move ++ rest)
    |> Enum.map(fn {key, words} ->
      [
        span(key, tint(:plain, state, :key, [:bold]), state),
        span(" " <> words, tint(:plain, state, :text_faint, []), state)
      ]
    end)
    |> Enum.intersperse([gap("   ", state)])
    |> List.flatten()
  end

  # mode · approval · trust · model · ctx · cost · waiting · connection
  defp facts(state, class) do
    workspace = Map.get(state.read_model.snapshots, :workspace)
    run = Support.run(state)

    mode = {Composer.mode_label(state), tint(:plain, state, :text_primary, [:bold])}

    approval =
      case workspace && Map.get(workspace, :approval_mode) do
        nil -> nil
        mode -> approval_words(mode, state)
      end

    trust =
      case workspace && Map.get(workspace, :trusted) do
        false -> {"untrusted", tint(:plain, state, :warning, [])}
        _ -> nil
      end

    chat_model = workspace && Map.get(workspace, :chat_model)
    swarm_model = workspace && Map.get(workspace, :swarm_model)

    model =
      case chat_model do
        model when is_binary(model) and model != "" ->
          {model, tint(:plain, state, :text_muted, [])}

        _ ->
          nil
      end

    # The sub agents' model, only when it is not the chat model.
    agents =
      if is_binary(swarm_model) and swarm_model != "" and swarm_model != chat_model,
        do: {"agents " <> swarm_model, tint(:plain, state, :text_faint, [])}

    context = context_words(state, run, workspace)
    cost = cost_words(state, workspace)

    waiting =
      case waiting_count(state) do
        0 -> nil
        n -> {"#{n} waiting", tint(:plain, state, :warning, [:bold])}
      end

    connection = connection(state)
    limit = rate_limit(state)
    background = background(state)

    # {rank, fact}: the higher the rank, the longer a fact holds its place
    # when the row is short.
    parts =
      if class in [:narrow, :small, :compressed_small],
        do: [
          {100, mode},
          {70, approval},
          {60, model},
          {90, waiting},
          {85, limit},
          {95, connection}
        ],
        else: [
          {100, mode},
          {70, approval},
          {65, trust},
          {60, model},
          {20, agents},
          {50, context},
          {40, cost},
          {45, background},
          {90, waiting},
          {85, limit},
          {95, connection}
        ]

    Enum.reject(parts, &is_nil(elem(&1, 1)))
  end

  defp essential(parts), do: Enum.filter(parts, &(elem(&1, 0) >= 85))

  # Drop the lowest-ranked fact (the rightmost of equals) until the row fits.
  defp fit(parts, room, policy, state) do
    if length(parts) <= 1 or cells(render(parts, state), policy) <= room do
      parts
    else
      {rank, _} = Enum.min_by(parts, &elem(&1, 0))

      index =
        parts
        |> Enum.with_index()
        |> Enum.filter(&(elem(elem(&1, 0), 0) == rank))
        |> List.last()
        |> elem(1)

      parts |> List.delete_at(index) |> fit(room, policy, state)
    end
  end

  defp render(parts, state) do
    parts
    |> Enum.map(fn {_rank, {text, style}} -> span(text, style, state) end)
    |> Enum.intersperse(span(" · ", tint(:plain, state, :text_ghost, []), state))
  end

  defp approval_words(mode, state) do
    case to_string(mode) do
      "read_only" ->
        {"read-only", tint(:plain, state, :info, [])}

      "read-only" ->
        {"read-only", tint(:plain, state, :info, [])}

      "auto" ->
        {"auto", tint(:plain, state, :text_muted, [])}

      full when full in ["full", "full_access", "full-access"] ->
        {"full access", tint(:plain, state, :warning, [])}

      other ->
        {String.replace(other, "_", " "), tint(:plain, state, :text_muted, [])}
    end
  end

  # The context the last model step used: the newest item of the run in view
  # that reports input tokens, against the model's window when it is known.
  defp context_words(state, run, workspace) do
    used = workspace && Map.get(workspace, :context_used)

    tokens =
      if is_integer(used) and used > 0 do
        used
      else
        run_context(state, run)
      end

    context_gauge(tokens, workspace && Map.get(workspace, :context_window), state)
  end

  defp run_context(state, run) do
    if run do
      state.read_model.transcript
      |> Map.values()
      |> Enum.filter(&(&1.run_id == run.id and is_integer(&1.tokens_in) and &1.tokens_in > 0))
      |> Enum.max_by(&{&1.at || 0, &1.created_sequence}, fn -> nil end)
      |> then(&(&1 && &1.tokens_in))
    end
  end

  defp context_gauge(tokens, window, state) do
    cond do
      is_nil(tokens) ->
        nil

      is_integer(window) and window > 0 ->
        filled = min(6, div(tokens * 6 + window - 1, window))
        on = SafeText.value(Support.glyph(:gauge_on, state))
        off = SafeText.value(Support.glyph(:gauge_off, state))

        {"ctx " <>
           String.duplicate(on, filled) <>
           String.duplicate(off, 6 - filled) <>
           " " <>
           Turns.compact(tokens) <> "/" <> Turns.compact(window),
         tint(:plain, state, :text_muted, [])}

      true ->
        {"ctx " <> Turns.compact(tokens), tint(:plain, state, :text_muted, [])}
    end
  end

  # What the conversation in view has cost so far: the daemon's total when it
  # says one, else the sum of the runs in view.
  defp cost_words(state, workspace) do
    case workspace && Map.get(workspace, :cost_usd) do
      cost when is_number(cost) and cost > 0 ->
        {money(cost), tint(:plain, state, :text_muted, [])}

      _ ->
        runs_cost(state)
    end
  end

  defp runs_cost(state) do
    runs =
      case state.destination do
        {:conversation, id} ->
          state.read_model.runs |> Map.values() |> Enum.filter(&(&1.conversation_id == id))

        {:run, id} ->
          state.read_model.runs |> Map.get(id) |> List.wrap()

        _ ->
          []
      end

    total = runs |> Enum.map(&(&1.cost_usd || 0)) |> Enum.sum()

    if total > 0, do: {money(total), tint(:plain, state, :text_muted, [])}
  end

  defp money(cost) when cost < 0.01, do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 3)
  defp money(cost), do: "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)

  defp connection(state) do
    worst =
      state.watches
      |> Map.values()
      |> Enum.reduce(nil, fn watch, worst ->
        case watch.status do
          :disconnected -> :disconnected
          :resyncing -> if worst == :disconnected, do: worst, else: :resyncing
          :stale -> if worst in [:disconnected, :resyncing], do: worst, else: :stale
          _ -> worst
        end
      end)

    failed_page =
      state
      |> Support.recovering_pages()
      |> Enum.find(fn {_slot, page} -> page.status == :error end)

    case {worst, failed_page} do
      {:disconnected, _} -> {"disconnected", tint(:plain, state, :error, [:bold])}
      {:resyncing, _} -> {"reconnecting", tint(:plain, state, :warning, [])}
      {:stale, _} -> {"stale", tint(:plain, state, :warning, [])}
      {nil, {_slot, %{direction: :before}}} -> {"older messages did not load", error(state)}
      {nil, {_slot, _page}} -> {"new messages did not load", error(state)}
      {nil, nil} -> nil
    end
  end

  defp error(state), do: tint(:plain, state, :error, [])

  # A provider that limited us: its countdown while the daemon waits, else a
  # warning once a window is nearly spent (C1 rate limits, kept by E's read
  # model under `rate_limits`).
  defp rate_limit(state) do
    now = Map.get(state, :now)
    limits = rate_limits(state)

    waiting =
      Enum.find(limits, fn limit ->
        is_integer(Map.get(limit, :retry_at)) and is_integer(now) and limit.retry_at > now
      end)

    busy =
      limits
      |> Enum.filter(&(is_number(Map.get(&1, :used_percent)) and &1.used_percent >= 80))
      |> Enum.max_by(& &1.used_percent, fn -> nil end)

    cond do
      waiting ->
        {provider_name(waiting) <> " limited · " <> Turns.duration_text(waiting.retry_at - now),
         tint(:plain, state, :warning, [:bold])}

      busy ->
        {provider_name(busy) <> " " <> Integer.to_string(round(busy.used_percent)) <> "%",
         tint(:plain, state, :warning, [])}

      true ->
        nil
    end
  end

  # E's live map by provider wins over the shell snapshot's list.
  defp rate_limits(state) do
    live = Map.get(state.read_model, :rate_limits, %{})
    shell = Map.get(state.read_model.snapshots, :shell)
    listed = if shell, do: Map.get(shell, :rate_limits, []), else: []

    listed
    |> Enum.reject(&Map.has_key?(live, Map.get(&1, :provider_id)))
    |> Enum.concat(Map.values(live))
  end

  defp provider_name(limit) do
    case Map.get(limit, :provider) do
      name when is_binary(name) and name != "" -> name
      _ -> "provider"
    end
  end

  # Commands an agent handed to the background and that still run.
  defp background(state) do
    live = Map.get(state.read_model, :background, %{})
    workspace = Map.get(state.read_model.snapshots, :workspace)

    commands =
      if map_size(live) > 0 or is_nil(workspace),
        do: Map.values(live),
        else: Map.get(workspace, :background, [])

    running = Enum.filter(commands, &(Map.get(&1, :state) == :running))

    case running do
      [] ->
        nil

      [one] ->
        command = one |> Map.get(:command, "") |> to_string() |> String.split("\n") |> hd()
        {"bg " <> command, tint(:plain, state, :info, [])}

      many ->
        {"#{length(many)} in background", tint(:plain, state, :info, [])}
    end
  end

  # Feedback in words, on the right of the row, instead of the key hints.
  defp toast(state) do
    text_role =
      case SwarmCodeCLI.UI.State.shown_notice(state) do
        {:command_feedback, text} when is_binary(text) -> {first_line(text), :info}
        nil -> mutation_toast(state) || daemon_toast(state)
        other -> {notice_words(other), :error}
      end

    case text_role do
      nil -> nil
      {text, role} -> [span(text, tint(:plain, state, role, []), state)]
    end
  end

  defp first_line(text), do: text |> String.split(["\r\n", "\n"], parts: 2) |> hd()

  # The daemon's newest toast (C1, kept by E's read model), for a few seconds.
  @toast_ms 8_000

  defp daemon_toast(state) do
    now = Map.get(state, :now)

    case Map.get(state.read_model, :toasts, []) do
      [%{at: at} = toast | _] when is_integer(at) and is_integer(now) and now - at < @toast_ms ->
        title = Map.get(toast, :title) || ""
        text = Map.get(toast, :text) || ""
        words = if text == "", do: title, else: title <> " · " <> first_line(text)

        role =
          case Map.get(toast, :level) do
            :success -> :success
            :waiting -> :warning
            :warning -> :warning
            :error -> :error
            _ -> :info
          end

        if words == "", do: nil, else: {words, role}

      _ ->
        nil
    end
  end

  defp notice_words({kind, reason}) when is_atom(kind) and is_atom(reason),
    do: sentence(Atom.to_string(kind) <> ": " <> Atom.to_string(reason))

  defp notice_words(kind) when is_atom(kind), do: sentence(Atom.to_string(kind))
  defp notice_words(_), do: "Something went wrong"

  defp sentence(text) do
    text = String.replace(text, "_", " ")
    String.upcase(String.first(text)) <> String.slice(text, 1..-1//1)
  end

  defp mutation_toast(state) do
    reasons = Map.get(state, :mutation_reasons) || %{}

    state.mutations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reverse()
    |> Enum.find_value(fn {origin, mutation} ->
      case mutation do
        {:pending, _, _} ->
          {"Sending…", :info}

        {:settled, _, :rejected} ->
          {refusal_words(origin, Map.get(reasons, origin) || delivery_reason(state, origin)),
           :error}

        {:settled, _, :deadline_exceeded} ->
          {refusal_words(origin, :deadline_expired), :error}

        {:settled, _, :revision_conflict} ->
          {refusal_words(origin, :stale_revision), :warning}

        {:settled, _, :outcome_unknown} ->
          {"Not sure that went through · check the transcript before sending again", :warning}

        {:settled, _, :needs_input} ->
          {"That needs your answer first · Ctrl-N opens what waits", :warning}

        {:settled, _, :interrupted} ->
          {"Interrupted · nothing more was done", :warning}

        _ ->
          nil
      end
    end)
  end

  # K's `State.deliveries` (pass73 T3/T8): the newest refused send of this
  # draft's conversation carries the words why.
  defp delivery_reason(state, {:draft, {conversation, _}}) do
    state
    |> Map.get(:deliveries, [])
    |> Enum.find_value(fn
      %{conversation_id: ^conversation, status: :refused, reason: reason}
      when is_binary(reason) and reason != "" ->
        reason

      _ ->
        nil
    end)
  end

  defp delivery_reason(_state, _origin), do: nil

  @doc """
  pass73 T7: the words of an approval-policy change, for the transcript
  notice and the toast alike: `"Approvals: auto → full access"`, with what
  the new mode means after a middle dot when `detail?`. `from` may be nil
  (the first mode seen). The modes read as on the status row.
  """
  @spec policy_words(atom() | binary() | nil, atom() | binary(), boolean()) :: binary()
  def policy_words(from, to, detail? \\ false) do
    head =
      case mode_word(from) do
        nil -> "Approvals: " <> mode_word(to)
        word -> "Approvals: " <> word <> " → " <> mode_word(to)
      end

    if detail?, do: head <> " · " <> mode_detail(to), else: head
  end

  defp mode_word(nil), do: nil

  defp mode_word(mode) do
    case to_string(mode) do
      m when m in ["read_only", "read-only", "readonly"] -> "read-only"
      "auto" -> "auto"
      m when m in ["full", "full_access", "full-access"] -> "full access"
      other -> String.replace(other, "_", " ")
    end
  end

  defp mode_detail(mode) do
    case mode_word(mode) do
      "read-only" -> "nothing is written or run without you"
      "auto" -> "edits go ahead, commands ask first"
      "full access" -> "nothing asks first"
      _ -> "/approval shows the modes"
    end
  end

  @doc """
  pass73 T3/T8: a request SwarmCode did not carry out, in words that say why
  and what to do, never "The daemon refused that request". `origin` names
  what was asked (a draft is "Not sent", an approval or question answer "Not
  answered", anything else "Not done"); `reason` is the typed refusal the
  daemon gave (an `AdmissionError` code, a `%{code: …}` or `%{reason: …}`
  map, or the words themselves), nil when it gave none.
  """
  @spec refusal_words(term(), term()) :: binary()
  def refusal_words(origin, reason) do
    lead =
      case origin do
        {:draft, _} -> "Not sent"
        {:interaction, _, _} -> "Not answered"
        _ -> "Not done"
      end

    case refusal_reason(reason) do
      {why, todo} -> lead <> ": " <> why <> " · " <> todo
      words when is_binary(words) -> lead <> ": " <> words
    end
  end

  defp refusal_reason(%{words: words}) when is_binary(words) and words != "",
    do: refusal_reason(words)

  defp refusal_reason(%{reason: reason}) when reason != nil, do: refusal_reason(reason)
  defp refusal_reason(%{code: code}) when code != nil, do: refusal_reason(code)

  defp refusal_reason(code) when code in [:not_allowed, "not_allowed"],
    do: {"that is not allowed right now", "Ctrl-G shows what runs; try again when it ends"}

  defp refusal_reason(code) when code in [:stale_revision, "stale_revision", :revision_conflict],
    do: {"it changed meanwhile", "look at it again and retry"}

  defp refusal_reason(code) when code in [:capacity_exceeded, "capacity_exceeded"],
    do: {"too much is in flight at once", "wait a moment and send it again"}

  defp refusal_reason(code) when code in [:deadline_expired, "deadline_expired"],
    do: {"SwarmCode took too long to answer", "send it again"}

  defp refusal_reason(code)
       when code in [:source_unavailable, :closed, :not_bound, "source_unavailable", "closed"],
       do: {"the connection to SwarmCode is down", "it reconnects by itself; send it again then"}

  defp refusal_reason(code)
       when code in [:request_conflict, :duplicate_watch, "request_conflict", "duplicate_watch"],
       do: {"the same request is already on its way", "wait for its answer"}

  defp refusal_reason(code)
       when code in [:invalid_request, :invalid_intent, :invalid_origin, "invalid_request"],
       do: {"SwarmCode could not read the request", "nothing changed; edit it and try again"}

  # pass73 S (typed refusal reasons on the wire), as far as the words go.
  defp refusal_reason(code) when code in [:untrusted, "untrusted", :project_untrusted],
    do: {"the project is not trusted", "/trust trusts it"}

  defp refusal_reason(code) when code in [:read_only, "read_only"],
    do: {"approvals are read-only", "/approval auto lets edits go ahead"}

  defp refusal_reason(code) when code in [:no_provider, "no_provider"],
    do: {"no model provider is set up", "add one in the desktop app's settings"}

  defp refusal_reason(code) when code in [:not_found, "not_found", :gone, "gone"],
    do: {"it no longer exists", "Ctrl-G shows the runs that do"}

  # Words the daemon (or K's delivery) already put together.
  defp refusal_reason(words) when is_binary(words) and words != "" do
    if Regex.match?(~r/^[a-z]+(_[a-z]+)+$/, words),
      # A code this client does not know yet: its words, and the way to more.
      do: {String.replace(words, "_", " "), "try again, or see cli.log for why"},
      else: words |> String.split(["\r\n", "\n"], parts: 2) |> hd() |> String.trim()
  end

  defp refusal_reason(_unknown),
    do: {"SwarmCode turned it down", "try again, or see cli.log for why"}

  # The strongest `budget` hints for the context, key then word.
  #
  # pass73 T6: the composer's hints are true at this moment. Enter is hinted
  # only when the composer has text, and names what Enter does now (send,
  # steer, queue, run, complete: `Composer.enter_action/1`); Esc only when it
  # does something now, and names it ("Esc stop Workflow author"). The other
  # keys follow only where they work: Tab while the slash palette is open,
  # Ctrl-F while the panel has something to open, Ctrl-C "clear" over a draft.
  defp hints(state, :composer, budget) do
    state
    |> composer_hints()
    |> Enum.take(budget)
    |> hint_spans(state)
  end

  # An approval or a question card: its own keys are on the card; the row
  # says what Esc does to it (sets it aside until ^N brings it back).
  # pass73 finisher: Enter first when it does something here: it sends the
  # draft typed under a card that opened by itself ("Enter steer"), or shows
  # the whole command the card cut ("Enter show all").
  defp hints(%{layers: [{kind, _} | _]} = state, :dialog, budget)
       when kind in [:approval, :question] do
    ascii? = state.capabilities.ascii?

    action = enter_action(state)

    enter =
      case enter_words(action) do
        nil -> []
        words -> [{:activate, words, :dialog}]
      end

    # pass73 G1 (QA Q1-02): over a draft typed under the card, `n` and `?`
    # type; Ctrl-C clears the draft and Tab completes its `/` command.
    rest =
      if SwarmCodeCLI.UI.Keymap.typing_under_card?(state) do
        complete? = SlashPalette.open?(state) and action != :complete

        [{:escape, "later", :dialog}, {:interrupt, "clear", :dialog}] ++
          if(complete?, do: [{:complete, "complete", :composer}], else: [])
      else
        [{:escape, "later", :dialog}, {:next_need, "next", :dialog}, {:help, "keys", :dialog}]
      end

    (enter ++ rest)
    |> Enum.flat_map(fn {id, words, context} ->
      with %{} = binding <- Bindings.fetch(id),
           key when key != nil <-
             Bindings.key_in_context(binding, context, SwarmCodeCLI.UI.Keymap.overrides(state)) do
        [{KeyLabel.label(key, ascii?), words}]
      else
        _ -> []
      end
    end)
    |> Enum.take(budget)
    |> hint_spans(state)
  end

  defp hints(state, context, budget) do
    live? = SwarmCodeCLI.UI.Keymap.live_turn(state) != nil

    context
    |> Bindings.hinted()
    # pass70 Q7: "Esc interrupt" only while there is a turn to interrupt.
    |> Enum.reject(&(&1.id == :interrupt_turn and not live?))
    # Q16: and then first, so the one-hint row of an 80-column terminal says
    # how to stop the turn rather than "Enter send".
    |> Enum.sort_by(&if(&1.id == :interrupt_turn, do: 0, else: 1))
    |> Enum.flat_map(fn binding ->
      case Bindings.key_in_context(binding, context, SwarmCodeCLI.UI.Keymap.overrides(state)) do
        nil -> []
        key -> [{KeyLabel.label(key, state.capabilities.ascii?), String.downcase(binding.label)}]
      end
    end)
    |> Enum.take(budget)
    |> hint_spans(state)
  end

  defp hint_spans(pairs, state) do
    pairs
    |> Enum.map(fn {key, label} ->
      [
        span(key, tint(:plain, state, :key, [:bold]), state),
        span(" " <> label, tint(:plain, state, :text_faint, []), state)
      ]
    end)
    |> Enum.intersperse([gap("   ", state)])
    |> List.flatten()
  end

  @doc """
  pass73 T6: the composer's key hints, strongest first, as `{key, words}`:
  what Esc does now, what Enter does now, then the keys that work in this
  state. Pure; the status row takes as many as fit.
  """
  def composer_hints(state) do
    ascii? = state.capabilities.ascii?
    text = SwarmCodeCLI.UI.Keymap.draft_text(state)
    key = fn id -> composer_key(id, ascii?, SwarmCodeCLI.UI.Keymap.overrides(state)) end

    esc =
      case esc_words(state) do
        nil -> []
        words -> with(k when k != nil <- key.(:interrupt_turn), do: [{k, words}], else: (_ -> []))
      end

    enter =
      case enter_words(enter_action(state)) do
        nil -> []
        _ when text == "" -> []
        words -> with(k when k != nil <- key.(:send), do: [{k, words}], else: (_ -> []))
      end

    palette? = SlashPalette.open?(state)

    rest =
      [
        {:next_need_chord, if(waiting_count(state) > 0, do: "waiting")},
        {:complete, if(palette? and enter_action(state) != :complete, do: "complete")},
        {:command_palette, "palette"},
        {:hint_mode, if(SwarmCodeCLI.UI.Reducer.Hint.open(state) != nil, do: "hints")},
        {:interrupt, if(text != "", do: "clear")},
        {:select_mode, "select"}
      ]
      |> Enum.flat_map(fn
        {_id, nil} ->
          []

        {id, words} ->
          case key.(id) do
            nil -> []
            k -> [{k, words}]
          end
      end)

    esc ++ enter ++ rest
  end

  defp composer_key(id, ascii?, overrides) do
    with %{} = binding <- Bindings.fetch(id),
         key when key != nil <- Bindings.key_in_context(binding, :composer, overrides) do
      KeyLabel.label(key, ascii?)
    else
      _ -> nil
    end
  end

  @doc """
  pass73 T6: what Enter does with the draft now, from K's
  `SwarmCodeCLI.UI.Composer.enter_action/1`
  (`:send | :steer | :queue | :run_command | :complete | :none`).
  """
  def enter_action(state), do: SwarmCodeCLI.UI.Composer.enter_action(state)

  @doc "The word the status row gives each Enter action; nil hides the hint."
  def enter_words(:send), do: "send"
  def enter_words(:steer), do: "steer"
  def enter_words(:queue), do: "queue"
  def enter_words(:run_command), do: "run"
  def enter_words(:complete), do: "complete"
  def enter_words(:show_all), do: "show all"
  def enter_words(:fold), do: "fold"
  def enter_words(_), do: nil

  @doc """
  pass73 T6: what Esc does in the composer now, in words, or nil when it does
  nothing (K's `Composer.esc_action/1`): an open `@path` list closes; else the
  live turn of this conversation stops when the daemon allows it, named by
  its agent ("stop Workflow author").
  """
  def esc_words(state) do
    case SwarmCodeCLI.UI.Composer.esc_action(state) do
      {:stop, turn} -> "stop " <> turn_agent_name(state, turn)
      :dismiss_completion -> "close"
      :close_layer -> "close"
      :close_overlay -> "back"
      :none -> nil
    end
  end

  @agent_name_cells 24

  # The live turn's own agent (its root node): "Workflow author", "Planner",
  # "Assistant"; the run's kind when no agent row has arrived yet.
  defp turn_agent_name(state, turn) do
    policy = state.capabilities.ambiguous_width

    root =
      state.read_model.agents
      |> Map.values()
      |> Enum.filter(&(Map.get(&1, :run_id) == turn.id))
      |> Enum.sort_by(&{Map.get(&1, :depth) || 0, if(Map.get(&1, :parent_id), do: 1, else: 0)})
      |> List.first()
      |> case do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> nil
      end

    # A chat turn is its agent ("Workflow author", "Planner"); a swarm or a
    # workflow started from this conversation is the run, not its Lead.
    name =
      case turn.kind do
        :chat -> root || "the turn"
        :swarm -> "the swarm"
        :workflow -> "the workflow"
        :research -> "the research"
        :consensus -> "the consensus"
        :goal -> "the goal run"
        _ -> root || "the run"
      end

    name = name |> String.split(["\r\n", "\n"], parts: 2) |> hd() |> String.trim()

    if Width.cells(name, policy) > @agent_name_cells do
      {taken, _, _} = Width.take_cells(name, @agent_name_cells - 1, policy)
      taken = String.trim_trailing(taken)
      taken <> if(state.capabilities.ascii?, do: "~", else: "…")
    else
      name
    end
  end

  defp span(text, style, state), do: %Span{text: Density.safe(text, state, 200), style: style}
  defp gap(text, state), do: span(text, tint(:plain, state, :text_primary, []), state)

  defp tint(:plain, state, role, modifiers),
    do: %{RunRow.tinted(role, state) | background: nil, modifiers: modifiers}

  defp cells(spans, policy),
    do: Enum.reduce(spans, 0, &(Width.cells(SafeText.value(&1.text), policy) + &2))

  defp clip(spans, width, policy, state) do
    {kept, _} =
      Enum.reduce_while(spans, {[], 0}, fn span, {acc, used} ->
        text = SafeText.value(span.text)
        c = Width.cells(text, policy)

        cond do
          used + c <= width ->
            {:cont, {[span | acc], used + c}}

          used >= width ->
            {:halt, {acc, used}}

          true ->
            {taken, _, taken_cells} = Width.take_cells(text, width - used, policy)

            {:halt,
             {[%{span | text: Density.safe(taken, state, width)} | acc], used + taken_cells}}
        end
      end)

    Enum.reverse(kept)
  end

  def notice(%{notice: nil}, _width), do: []

  def notice(%{notice: {:command_feedback, text}} = state, width) when is_binary(text),
    do: [%Block.Notice{text: Density.safe(text, state, width), severity: :info}]

  def notice(state, width) do
    label =
      case state.notice do
        {kind, reason} when is_atom(kind) and is_atom(reason) ->
          Atom.to_string(kind) <> " · " <> Atom.to_string(reason)

        kind when is_atom(kind) ->
          Atom.to_string(kind)

        _ ->
          "error"
      end

    # pass71 V5: sentence case, like every other status fact.
    label = label |> String.replace("_", " ") |> sentence()
    [%Block.Notice{text: Density.safe(label, state, width), severity: :error}]
  end

  # A request that went through says nothing: its effect is on screen already
  # (the message in the transcript, the dialog gone). Only a request still in
  # flight or one that failed is worth a row.
  def mutations(state, width) do
    state.mutations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reject(fn {_origin, mutation} -> match?({:settled, _, :accepted}, mutation) end)
    |> Enum.map(fn {_origin, mutation} ->
      key =
        case mutation do
          {:pending, _, _} ->
            :status_mutation_pending

          {:settled, _, :interrupted} ->
            :status_interrupted

          {:settled, _, outcome}
          when outcome in [
                 :accepted,
                 :needs_input,
                 :rejected,
                 :deadline_exceeded,
                 :revision_conflict,
                 :outcome_unknown
               ] ->
            outcome

          _ ->
            :empty
        end

      %Block.Notice{
        text: Density.safe(SafeText.chrome(key), state, width),
        severity: severity(key)
      }
    end)
  end

  defp severity(key)
       when key in [:rejected, :deadline_exceeded, :revision_conflict, :outcome_unknown],
       do: :error

  defp severity(:accepted), do: :success
  defp severity(_), do: :info
end
