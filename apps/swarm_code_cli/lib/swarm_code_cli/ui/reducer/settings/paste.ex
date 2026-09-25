defmodule SwarmCodeCLI.UI.Reducer.Settings.Paste do
  @moduledoc """
  The paste target of a secret (spec §3.7.7). While it is open (mode
  `:paste`, context `settings_paste`):

    * a bracketed paste replaces what was pasted; typed keys are ignored with
      words, unless the terminal cannot mark pastes or Ctrl-T asked to type
      instead (then they are appended, never echoed);
    * Ctrl-U clears; Esc drops the paste (and keeps the stored key);
    * Enter checks it (one line, no inner space, 8–8 192 bytes) and sends the
      target's command with the secret in `secrets` — never in attributes —
      or, for a draft (MCP import variables, a new record), keeps it in the
      draft's `secrets` (Inspect-hidden) for the later command.

  Replacing a stored key sends `test_first: true`; the paste is kept until
  that check ends (`pending_task`): a refusal offers `s save it anyway` (the
  second and last time the bytes travel) or Esc (keep the old key).

  Pasted bytes never reach rows, the scene, undo, the changelog, toasts,
  the search index or logs; the request kept in `state.requests` for
  matching its answer has its secrets stripped (`Settings.Wire`).
  """

  alias SwarmCodeCLI.UI.Reducer.Settings.{Commit, Ops}
  alias SwarmCodeCLI.UI.Settings.Layer
  alias SwarmCodeCLI.UI.Settings.Paste, as: Target

  @typing_ignored "typing is ignored here · paste with Cmd-V · Ctrl-T types instead"

  @doc "One event while the paste target is open."
  @spec event(map(), term()) :: {map(), list()}
  def event(%{settings: %Layer{paste: %Target{} = paste}} = state, event),
    do: handle(state, paste, event)

  def event(state, _event), do: {state, []}

  defp handle(state, paste, {:paste, bytes}), do: {put(state, Target.put(paste, bytes)), []}

  # `s` after a refused replacement saves the key without the check.
  defp handle(state, %Target{refused: {:replacement, _words}} = paste, {:text, "s"}),
    do: send(state, paste, false)

  defp handle(state, paste, {:text, text}) do
    if paste.typing? or state.capabilities.paste == :unavailable,
      do: {put(state, Target.type(paste, text)), []},
      else: {Commit.status(state, @typing_ignored, :text_muted), []}
  end

  defp handle(state, paste, {:verb, :paste_type}), do: {put(state, %{paste | typing?: true}), []}
  defp handle(state, paste, {:verb, :paste_clear}), do: {put(state, Target.clear(paste)), []}

  defp handle(state, paste, {:verb, :backspace}) do
    if paste.typing? do
      bytes = String.slice(paste.bytes, 0, max(String.length(paste.bytes) - 1, 0))
      {put(state, %{Target.put(paste, bytes) | typing?: true}), []}
    else
      {state, []}
    end
  end

  defp handle(state, _paste, {:verb, verb}) when verb in [:escape, :back, :interrupt, :close],
    do: {drop(state), []}

  # After a refused replacement only `s` sends the key again.
  defp handle(state, %Target{refused: {:replacement, _}}, {:verb, verb})
       when verb in [:paste_commit, :enter, :commit],
       do: {Commit.status(state, "s saves it anyway · Esc keeps the old key", :text_muted), []}

  defp handle(state, paste, {:verb, verb}) when verb in [:paste_commit, :enter, :commit] do
    case paste.pending_task do
      nil ->
        case Target.check(paste) do
          {:ok, _value} -> commit(state, paste)
          {:error, words} -> {put(state, %{paste | refused: words}), []}
        end

      _task ->
        {Commit.status(state, "Still checking the new key · Esc keeps the old one", :text_muted),
         []}
    end
  end

  defp handle(state, _paste, _event), do: {state, []}

  # A draft keeps the secret for its later command.
  defp commit(%{settings: layer} = state, %Target{target: target} = paste) do
    case field(target, :draft) do
      draft when not is_nil(draft) ->
        slot = field(target, :slot) || "value"
        {:ok, value} = Target.check(paste)

        drafts =
          Map.update(layer.drafts, draft, %{secrets: %{slot => value}}, fn current ->
            Map.update(current, :secrets, %{slot => value}, &Map.put(&1, slot, value))
          end)

        state = %{state | settings: %{layer | drafts: drafts, paste: nil, mode: :browse}}
        label = field(target, :label) || "The value"
        {state, effects} = Ops.run(state, List.wrap(field(target, :then)))
        {Commit.status(state, "#{label} kept for the import · not shown", :success), effects}

      nil ->
        send(state, paste, field(target, :set?) == true)
    end
  end

  # The command carries the bytes once; a first key drops the paste as it
  # leaves, a replacement keeps it until its check ends.
  defp send(state, %Target{target: target} = paste, test_first?) do
    attributes =
      Map.merge(
        field(target, :attributes) || %{},
        if(test_first?, do: %{"test_first" => true}, else: %{})
      )

    op =
      {:command, field(target, :action), field(target, :target), attributes,
       %{
         secrets_from: :paste,
         expected: field(target, :expected),
         undo: false,
         toast: toast(target, test_first?),
         after: field(target, :then),
         paste: if(test_first?, do: :keep, else: :drop)
       }}

    state = put(state, %{paste | refused: nil})
    {state, effects} = Ops.run(state, [op])

    # A command refused before it left (its status line says why) keeps the
    # paste, so Enter can try again and Esc keeps the stored key.
    state =
      cond do
        not Enum.any?(effects, &match?({:command, _}, &1)) -> state
        test_first? -> put(state, %{state.settings.paste | pending_task: :sent})
        true -> drop(state)
      end

    {state, effects}
  end

  defp toast(_target, true), do: nil
  defp toast(target, false), do: "#{field(target, :label) || "The key"} saved"

  @doc """
  A replacement's check answered: the task that tests the new key started
  (`task_id`), or the command failed.
  """
  @spec replacement_started(map(), String.t() | nil) :: map()
  def replacement_started(
        %{settings: %Layer{paste: %Target{pending_task: :sent} = paste}} = state,
        task_id
      )
      when is_binary(task_id),
      do: put(state, %{paste | pending_task: task_id})

  # No check started (the service already had that key): nothing waits.
  def replacement_started(%{settings: %Layer{paste: %Target{pending_task: :sent}}} = state, nil),
    do: drop(state)

  def replacement_started(state, _task_id), do: state

  @doc """
  A replacement's command was refused, conflicted or failed (the status
  line says why): the paste is kept and no longer waits for a check.
  """
  @spec replacement_failed(map()) :: map()
  def replacement_failed(%{settings: %Layer{paste: %Target{pending_task: :sent} = paste}} = state),
    do: put(state, %{paste | pending_task: nil})

  def replacement_failed(state), do: state

  @doc "A settings task ended: a replacement check it was waiting for settles here."
  @spec task_ended(map(), String.t(), atom(), term()) :: map()
  def task_ended(
        %{settings: %Layer{paste: %Target{pending_task: task_id} = paste}} = state,
        task_id,
        :done,
        summary
      ) do
    label = field(paste.target, :label) || "The key"
    count = if field(paste.target, :action) == "provider.set_key", do: models(summary)

    words =
      if is_integer(count),
        do: "#{label} replaced · the new key listed #{count} models",
        else: "#{label} replaced"

    state |> drop() |> Commit.status(words, :success)
  end

  def task_ended(
        %{settings: %Layer{paste: %Target{pending_task: task_id} = paste}} = state,
        task_id,
        _failed,
        summary
      ) do
    # The service's own sentence already says it (`The new key was refused (401).`).
    reason = refusal(summary)

    words =
      if String.starts_with?(reason, "The new key was refused"),
        do: reason <> " s save it anyway · Esc keep the old key",
        else: "The new key was refused (#{reason}). s save it anyway · Esc keep the old key"

    put(state, %{paste | pending_task: nil, refused: {:replacement, words}})
  end

  def task_ended(state, _task_id, _state, _summary), do: state

  # The service's summary names it `count`; the fake's `models`.
  defp models(%{} = summary),
    do:
      Map.get(summary, "models") || Map.get(summary, :models) || Map.get(summary, "count") ||
        Map.get(summary, :count)
  defp models(_summary), do: nil

  defp refusal(%{} = summary),
    do: Map.get(summary, "message") || Map.get(summary, :message) || "no answer"

  defp refusal(words) when is_binary(words), do: words
  defp refusal(_summary), do: "no answer"

  @doc "The words the row shows for the paste (never the bytes)."
  @spec words(Target.t(), atom()) :: [{String.t(), atom()}]
  def words(%Target{} = paste, tier) do
    marks = if tier == :ascii, do: "********", else: "●●●●●●●●"

    cond do
      match?({:replacement, _}, paste.refused) ->
        [{marks <> " ", :text_primary}, {"✗ the new key was refused", :warning}]

      paste.pending_task != nil ->
        [{"◷ checking the new key…", :text_muted}]

      is_binary(paste.refused) ->
        [{marks <> " ", :text_primary}, {"✗ " <> paste.refused, :error}]

      paste.typing? and Target.filled?(paste) ->
        [{"typing · not shown", :text_muted}, {"  not saved", :warning}]

      paste.typing? ->
        [{"typing · not shown", :text_muted}]

      Target.filled?(paste) ->
        [{marks <> " pasted · not shown", :text_primary}, {"  not saved", :warning}]

      true ->
        [{"paste the key · Cmd-V", :text_ghost}]
    end
  end

  @doc """
  The continuation lines under the pasting row (a refused replacement's
  choice), unless the target's section draws them itself (`own_lines: true`,
  a provider's or search engine's key: cli74 F16, it was said three times).
  """
  @spec lines(Target.t()) :: [[{String.t(), atom()}]]
  def lines(%Target{refused: {:replacement, words}, target: target}) do
    if field(target, :own_lines) == true, do: [], else: [[{words, :warning}]]
  end

  def lines(%Target{}), do: []

  defp drop(%{settings: %Layer{} = layer} = state),
    do: %{state | settings: %{layer | paste: nil, mode: :browse}}

  defp put(%{settings: %Layer{} = layer} = state, paste),
    do: %{state | settings: %{layer | paste: paste}}

  defp field(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp field(_map, _key), do: nil
end
