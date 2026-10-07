defmodule SwarmCodeCLI.UI.Reducer.Attention do
  @moduledoc """
  cli020 D3 (tui-code-5, decision 4a): the needs-you signal and the window
  title, derived after every transition from what changed.

    * `{:bell, :needs_you}` when an approval or question of the conversation in
      view first appears, and `{:bell, :turn_done}` when a run this session
      started reaches done, failed or stopped; only while the terminal
      reported focus lost (`state.terminal_focus == :lost`, so a terminal
      without focus reports never bells) and at most once per 2 s (the
      owner's clock, `state.last_bell_at`). Each bell is followed by
      `{:notify_os, text}`, the words a notification shows ("ncode: <project>
      needs you (approval)", "… finished"); the session runtime picks one of
      the two by `terminal.notify` (bell, OSC 9, the OS notification centre).
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
    done = finished_runs(previous, next)

    cond do
      next.terminal_focus != :lost or next.notify == :off ->
        {next, []}

      needs == [] and done == [] ->
        {next, []}

      not bell_allowed?(next) ->
        {next, []}

      needs != [] ->
        kind = if Enum.any?(needs, &(&1 == :approval)), do: "approval", else: "question"
        ring(next, :needs_you, "#{prefix(next)} needs you (#{kind})")

      true ->
        ring(next, :turn_done, "#{prefix(next)} #{outcome_word(done)}")
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
