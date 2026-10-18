defmodule SwarmCodeCLI.UI.Reducer.Attention do
  @moduledoc """
  cli020 D3 (tui-code-5, decision 4a): the needs-you signal and the window
  title, derived after every transition from what changed.

    * `{:bell, :needs_you}` when an approval or question of the conversation in
      view first appears, or of any other conversation of the session (the
      daemon's `elsewhere` fact; the words name that conversation), and
      `{:bell, :turn_done}` when a run this session started reaches done,
      failed or stopped; only while the terminal reported focus lost
      (`state.terminal_focus == :lost`, so a terminal without focus reports
      never bells) and at most once per 2 s (the owner's clock,
      `state.last_bell_at`). Each bell is followed by `{:notify_os, text}`, the
      words a notification shows ("ncode: <project> needs you (approval)",
      "… needs you (approval in <conversation>)", "… finished"); the session
      runtime picks one of the two by `terminal.notify` (bell, OSC 9, the OS
      notification centre). A burst of requests in several conversations is
      one bell whose words name the first two conversations and count the rest
      ("approval in A and B", "approval in A, B +2 more").
    * `{:terminal_title, text}` whenever the title changes: `ncode · <project>`
      idle, `… · working` while a run of the conversation is live, `… · needs
      you` while an interaction waits, `… · done` after an unfocused finish
      until focus returns. Off with `terminal.title off` (`state.title?`).
  """

  alias SwarmCodeCLI.UI.{SafeText, Width}

  @bell_ms 2_000
  @project_cells 40
  @live [:queued, :running, :streaming, :waiting_question, :waiting_approval, :paused, :retrying]
  @finished [:done, :failed, :stopped]

  @doc "The effects and state the change from `previous` to `next` calls for."
  @spec after_update(map(), map(), list()) :: {map(), list()}
  # Only a full-screen terminal (the port's) has a bell and a title; the
  # plain presenter, the demos and the pure tests draw none.
  def after_update(_previous, %{capabilities: %{full_screen?: false}} = next, effects),
    do: {next, effects}

  def after_update(previous, next, effects) do
    {next, bells} = bells(previous, next)
    next = done_mark(previous, next, bells)
    {next, title} = title(next)
    {next, effects ++ bells ++ title}
  end

  # ------------------------------------------------------------------ bells

  defp bells(previous, next) do
    needs = new_needs(previous, next)
    {next, elsewhere} = new_elsewhere(previous, next)
    done = finished_runs(previous, next)

    cond do
      next.terminal_focus != :lost or next.notify == :off ->
        {next, []}

      needs == [] and elsewhere == [] and done == [] ->
        {next, []}

      not bell_allowed?(next) ->
        {next, []}

      needs != [] or elsewhere != [] ->
        ring(next, :needs_you, "#{prefix(next)} needs you (#{needs_words(needs, elsewhere)})")

      true ->
        ring(next, :turn_done, "#{prefix(next)} #{outcome_word(done)}")
    end
  end

  # "approval" for the conversation in view; "approval in <title>" when the
  # only new request waits in one other conversation; "approval in A and B"
  # for two, "approval in A, B +N more" for more (the one in view reads "this
  # conversation"). The text stays short however many conversations wait.
  defp needs_words(needs, elsewhere) do
    kinds = needs ++ Enum.map(elsewhere, & &1.kind)
    kind = if Enum.any?(kinds, &(&1 == :approval)), do: "approval", else: "question"

    conversations =
      elsewhere
      |> Enum.uniq_by(& &1.conversation_id)
      |> Enum.map(&conversation_name(&1.title))

    cond do
      conversations == [] -> kind
      needs == [] -> kind <> " in " <> name_list(conversations)
      true -> kind <> " in " <> name_list(["this conversation" | conversations])
    end
  end

  defp name_list([name]), do: name
  defp name_list([first, second]), do: first <> " and " <> second
  defp name_list([first, second | rest]), do: "#{first}, #{second} +#{length(rest)} more"

  defp conversation_name(title) do
    with {:ok, safe} <- SafeText.external(title, SafeText.Limits.content()),
         name when name != "" <- safe |> SafeText.value() |> String.trim() do
      Width.elide(name, @project_cells, :end, :narrow)
    else
      _ -> "another conversation"
    end
  end

  defp ring(state, kind, words) do
    {:ok, text} = SafeText.external(words, SafeText.Limits.content())
    {%{state | last_bell_at: state.now}, [{:bell, kind}, {:notify_os, text}]}
  end

  defp bell_allowed?(%{last_bell_at: nil}), do: true
  defp bell_allowed?(%{last_bell_at: at, now: now}), do: now - at >= @bell_ms

  defp prefix(state) do
    case project(state) do
      nil -> "ncode:"
      name -> "ncode: " <> name
    end
  end

  defp outcome_word(states) do
    cond do
      :failed in states -> "failed"
      :stopped in states -> "stopped"
      true -> "finished"
    end
  end

  # The kinds of the pending interactions of the conversation in view that
  # were not pending before this transition.
  defp new_needs(previous, next) do
    before = pending(previous)

    for {id, kind} <- pending(next), not Map.has_key?(before, id), do: kind
  end

  # The approvals and questions of the session's other conversations (the
  # daemon's `elsewhere` fact) that were not known before this transition.
  # The fact lists the newest 32 waits only, so being absent from the fact
  # before proves nothing: a wait that left the 32 and came back is not news.
  # A wait is news when it is newer than `state.elsewhere_mark`, the newest
  # `{since, run_id, id}` told or taken as known so far, which moves ahead with
  # every fact. Without a fact held before there is no baseline: what already
  # waited when the first one arrived rings nothing. A conversation in view
  # before or now belongs to the in-view rule: switching away from one that
  # waits is not news, because that wait moves into this list as the shell
  # watch re-snapshots.
  defp new_elsewhere(previous, next) do
    case {previous.read_model.elsewhere, next.read_model.elsewhere} do
      {same, same} ->
        {next, []}

      {%{}, %{waiting: now}} ->
        seen = [viewed(previous), viewed(next)]

        news =
          for wait <- now,
              newer?(wait_key(wait), next.elsewhere_mark),
              wait.conversation_id not in seen,
              do: wait

        {mark(next, now), news}

      {_none, %{waiting: now}} ->
        {mark(next, now), []}

      _no_fact ->
        {next, []}
    end
  end

  # No wait left outside: the next one is news whatever its clock says.
  defp mark(state, []), do: %{state | elsewhere_mark: nil}

  defp mark(state, waits),
    do: %{state | elsewhere_mark: Enum.reduce(waits, state.elsewhere_mark, &max_key/2)}

  defp max_key(wait, mark) do
    key = wait_key(wait)
    if newer?(key, mark), do: key, else: mark
  end

  defp wait_key(wait), do: {wait.since, wait.run_id, wait.id}

  defp newer?(_key, nil), do: true
  defp newer?(key, mark), do: key > mark

  defp viewed(%{destination: {:conversation, id}}), do: id
  defp viewed(_state), do: nil

  defp pending(state) do
    case state.destination do
      {:conversation, conversation} ->
        for {id, %{state: :pending, kind: kind, conversation_id: ^conversation}} <-
              state.read_model.interactions,
            into: %{},
            do: {id, kind}

      _ ->
        %{}
    end
  end

  # The states of the runs this session started that left a live state for a
  # finished one in this transition.
  defp finished_runs(previous, next) do
    mine = started_here(next)

    for id <- mine,
        %{state: before} <- [Map.get(previous.read_model.runs, id)],
        before in @live,
        %{state: now} <- [Map.get(next.read_model.runs, id)],
        now in @finished,
        do: now
  end

  defp started_here(state) do
    sent =
      case state.sent_turn do
        {_conversation, {:run, id}} -> [id]
        _ -> []
      end

    delivered =
      for %{run_id: id, status: status} <- state.deliveries,
          is_binary(id) and status == :started,
          do: id

    Enum.uniq(sent ++ delivered)
  end

  # ------------------------------------------------------------------ title

  # "done" holds from an unfocused finish until focus comes back.
  defp done_mark(_previous, %{terminal_focus: :gained} = next, _bells),
    do: %{next | title_done?: false}

  defp done_mark(previous, next, _bells) do
    if finished_runs(previous, next) != [], do: %{next | title_done?: true}, else: next
  end

  defp title(%{title?: false} = state), do: {state, []}

  defp title(state) do
    words =
      cond do
        pending(state) != %{} -> base(state) <> " · needs you"
        live?(state) -> base(state) <> " · working"
        state.title_done? -> base(state) <> " · done"
        true -> base(state)
      end

    if words == state.terminal_title do
      {state, []}
    else
      {:ok, text} = SafeText.external(words, SafeText.Limits.content())
      {%{state | terminal_title: words}, [{:terminal_title, text}]}
    end
  end

  defp base(state) do
    case project(state) do
      nil -> "ncode"
      name -> "ncode · " <> name
    end
  end

  defp live?(state) do
    case state.destination do
      {:conversation, conversation} ->
        Enum.any?(state.read_model.runs, fn {_id, run} ->
          run.conversation_id == conversation and run.state in @live
        end)

      _ ->
        false
    end
  end

  @doc """
  The project's name for the title and the notifications: the root's
  basename, else the workspace's project; at most 40 cells, made safe.
  """
  @spec project(map()) :: binary() | nil
  def project(state) do
    root = Map.get(state.launch_facts || %{}, :project_root)

    name =
      cond do
        is_binary(root) and root != "" -> Path.basename(root)
        true -> workspace_project(state)
      end

    with name when is_binary(name) and name != "" <- name,
         {:ok, safe} <- SafeText.external(name, SafeText.Limits.content()) do
      safe |> SafeText.value() |> Width.elide(@project_cells, :end, :narrow)
    else
      _ -> nil
    end
  end

  defp workspace_project(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{project: project} when is_binary(project) -> project
      _ -> nil
    end
  end
end
