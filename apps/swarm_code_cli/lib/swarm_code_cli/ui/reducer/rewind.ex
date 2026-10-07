defmodule SwarmCodeCLI.UI.Reducer.Rewind do
  @moduledoc """
  cli020 D10 (competitors-8, decision 4h): the conversation rewind client.

  Bare `/rewind` and Esc Esc (two bare Esc within 600 ms, draft empty, no
  turn streaming, no layer open) ask `rewind.turns` (C16) and open the layer
  `{:rewind, %{turns: [...], selected: 0}}`; ↑/↓ move, Enter opens
  `{:rewind_confirm, turn}`: Enter/`b` "Conversation and files", `c`
  "Conversation only", `f` "Files only", Esc cancels. The choice sends
  `rewind.apply`; its answer puts the turn's prompt into the draft through
  the undoable `replace_draft` (both/conversation) and says what came back.
  `/undo` asks the same confirm for the newest turn.

  The layers open only once the client can draw them (`LayerSpec.validate/1`
  knows them; lane E adds the drawing).
  """

  alias SwarmCodeCLI.UI.{LayerSpec, State}
  alias SwarmCodeCLI.UI.Reducer.Remote

  @escape_ms 600

  @doc "Bare `/rewind` (`:pick`) or `/undo` (`:undo`): asks for the turns."
  def request(state, mode) do
    case Remote.conversation(state) do
      nil ->
        {state, []}

      conversation ->
        {next, effects} = Remote.send(state, {:rewind_turns, conversation}, :rewind)
        if effects == [], do: {next, []}, else: {%{next | rewind: %{mode: mode}}, effects}
    end
  end

  @doc """
  A bare Esc that stopped nothing: the second within 600 ms opens the
  rewind list. Returns `{:open, state}` or `{:armed, state}`.
  """
  def escape(state) do
    idle? =
      state.layers == [] and draft_empty?(state) and
        is_nil(SwarmCodeCLI.UI.Keymap.live_turn(state))

    cond do
      not idle? ->
        {:armed, %{state | last_escape_at: nil}}

      is_integer(state.last_escape_at) and state.now - state.last_escape_at <= @escape_ms ->
        {:open, %{state | last_escape_at: nil}}

      true ->
        {:armed, %{state | last_escape_at: state.now}}
    end
  end

  defp draft_empty?(state), do: String.trim(SwarmCodeCLI.UI.Keymap.draft_text(state)) == ""

  @doc "The turns' answer (newest first)."
  def turns_answer(state, _request, payload) do
    turns = payload |> List.wrap() |> Enum.flat_map(&turn/1) |> Enum.take(200)
    mode = get_in(state.rewind || %{}, [:mode]) || :pick

    cond do
      turns == [] ->
        {%{state | rewind: nil, notice: {:command_feedback, "Nothing to rewind yet."}}, []}

      mode == :undo ->
        open(%{state | rewind: nil}, {:rewind_confirm, hd(turns)})

      true ->
        open(%{state | rewind: nil}, {:rewind, %{turns: turns, selected: 0}})
    end
  end

  defp turn(row) when is_map(row) do
    message = Remote.field(row, :message_id)
    number = Remote.field(row, :turn) || Remote.field(row, :position)

    if is_binary(message) and is_integer(number) do
      [
        %{
          message_id: message,
          turn: number,
          prompt: to_string(Remote.field(row, :prompt) || ""),
          at: Remote.field(row, :at),
          run_id: Remote.field(row, :run_id),
          files: Remote.field(row, :files) || 0
        }
      ]
    else
      []
    end
  end

  defp turn(_row), do: []

  defp open(state, layer) do
    case LayerSpec.validate(layer) do
      {:ok, _} ->
        {%{state | layers: [layer | state.layers]}, []}

      _ ->
        {%{state | notice: {:command_feedback, "Rewind is not drawn in this build yet."}}, []}
    end
  end

  @doc "↑/↓ in the list."
  def move(%{layers: [{:rewind, %{turns: turns, selected: at} = list} | rest]} = state, delta) do
    at = min(max(at + delta, 0), length(turns) - 1)
    {%{state | layers: [{:rewind, %{list | selected: at}} | rest]}, []}
  end

  def move(state, _delta), do: {state, []}

  @doc "Enter in the list: the confirm for the selected turn."
  def choose_turn(%{layers: [{:rewind, %{turns: turns, selected: at}} | _]} = state),
    do: open(state, {:rewind_confirm, Enum.at(turns, at)})

  def choose_turn(state), do: {state, []}

  @doc "The confirm's choice: sends `rewind.apply` and closes both layers."
  def apply(%{layers: [{:rewind_confirm, turn} | rest]} = state, scope)
      when scope in [:both, :conversation, :files] do
    rest = Enum.reject(rest, &match?({:rewind, _}, &1))
    conversation = Remote.conversation(state)
    state = %{state | layers: rest}

    {next, effects} =
      Remote.send(state, {:rewind_apply, conversation, turn.message_id, scope}, :rewind)

    if effects == [],
      do: {next, []},
      else: {%{next | rewind: %{mode: :apply, turn: turn, scope: scope}}, effects}
  end

  def apply(state, _scope), do: {state, []}

  @doc "The answer of `rewind.apply`."
  def apply_answer(state, %{kind: {:rewind_apply, _, _, scope}}, payload) do
    turn = get_in(state.rewind || %{}, [:turn]) || %{turn: "?"}
    restored = count(Remote.field(payload, :restored))
    skipped = count(Remote.field(payload, :skipped))
    text = Remote.field(payload, :text)
    skipped_words = if skipped > 0, do: " · #{skipped} skipped (see the transcript)", else: ""
    state = %{state | rewind: nil}

    case scope do
      :files ->
        words = "Files back to before turn #{turn.turn} · #{restored} restored" <> skipped_words
        {%{state | notice: {:command_feedback, words}}, []}

      _ ->
        {state, effects} =
          case {State.current_draft_key(state), text} do
            {key, text} when key != nil and is_binary(text) ->
              SwarmCodeCLI.UI.Reducer.replace_text(state, key, text)

            _ ->
              {state, []}
          end

        words =
          "Rewound to turn #{turn.turn} · #{files(restored)} restored · " <>
            "edit and press Enter to resend" <> skipped_words

        {%{state | notice: {:command_feedback, words}}, effects}
    end
  end

  defp count(n) when is_integer(n), do: n
  defp count(list) when is_list(list), do: length(list)
  defp count(_), do: 0

  defp files(1), do: "1 file"
  defp files(n), do: "#{n} files"
end
