defmodule SwarmCodeCLI.UI.Composer do
  @moduledoc """
  pass73: what the composer's keys do now, derived from the state alone.

  `enter_action/1` is the one answer the footer hint (T6), the transcript's
  pending marks (T3/T8) and the keymap agree on:

    * `:none`: Enter does nothing to the composer (no draft text, a layer or
      select mode owns Enter).
    * `:complete`: the slash palette is open on a command that takes an
      argument; Enter writes `/<name> ` and the caret waits (T4).
    * `:run_command`: Enter runs a command: an exact slash command, the
      palette's highlighted command that takes no argument (T4), or a
      message that names "workflow" and goes as `/create-workflow` (T5).
    * `:steer`: a plain message goes to this conversation's running chat turn
      (T3), or the agent overlay's composer steers its agent.
    * `:queue`: the message (or `/compact`) waits for the running chat
      turn to end.
    * `:send`: a plain message starts a turn.

  The daemon has the last word: it may still queue a message the client
  expected to steer, and the transcript shows what actually happened.
  """

  alias SwarmCodeCLI.UI.{Drafts, Editor, Keymap, SlashPalette, State, WorkflowKeyword}

  @type enter_action :: :send | :steer | :queue | :run_command | :complete | :none
  @type esc_action ::
          {:stop, map()} | :close_layer | :close_overlay | :dismiss_completion | :none

  # The chat turn takes a steer while it is working; before it starts, or
  # while it is paused, the message waits its turn instead.
  @steerable [:running, :streaming, :waiting_question, :waiting_approval, :retrying]
  @waiting [:queued, :paused]

  # A command that changes the conversation itself waits for its chat turn
  # (T3; pass73 S queues `/compact` then), where every other command,
  # run-launching ones included, starts at once beside the live runs.
  @after_turn ~w(compact)

  @doc "What Enter does with the composer now (see the moduledoc)."
  @spec enter_action(map()) :: enter_action()
  def enter_action(state) do
    text = draft_text(state)

    cond do
      String.trim(text) == "" -> :none
      Map.get(state, :overlay) != nil -> :steer
      Map.get(state, :layers, []) != [] -> :none
      Map.get(state, :focus) != "composer" -> :none
      true -> composer_action(state, text)
    end
  end

  @doc """
  What Esc does now: `{:stop, run}` stops the turn in view (the run summary,
  so a surface can name it), `:close_layer`/`:close_overlay` closes what is
  on top, `:dismiss_completion` closes the `@path` list, `:none` nothing.
  """
  @spec esc_action(map()) :: esc_action()
  def esc_action(state) do
    cond do
      Map.get(state, :layers, []) != [] ->
        :close_layer

      Map.get(state, :overlay) != nil ->
        :close_overlay

      SwarmCodeCLI.UI.Reducer.PathCompletion.open?(state) ->
        :dismiss_completion

      Map.get(state, :focus) in ["main", "inspector"] ->
        :none

      true ->
        case Keymap.live_turn(state) do
          %{allowed_actions: actions} = run -> if :stop in actions, do: {:stop, run}, else: :none
          nil -> :none
        end
    end
  end

  @doc """
  This conversation's chat turn that is live now, or nil: the newest
  top-level `:chat` run of the conversation in view whose state is live.
  A swarm or a workflow running beside it is not the turn.
  """
  @spec chat_turn(map()) :: map() | nil
  def chat_turn(state) do
    case State.current_draft_key(state) do
      {conversation, _} ->
        state.read_model.runs
        |> Map.values()
        |> Enum.filter(
          &(&1.conversation_id == conversation and is_nil(&1.parent_run_id) and
              &1.kind == :chat and &1.state in (@steerable ++ @waiting))
        )
        |> Enum.max_by(&{&1.started_at || 0, &1.created_sequence}, fn -> nil end)

      _ ->
        nil
    end
  end

  @doc "Whether a slash command waits for the running chat turn (T3)."
  @spec after_turn_command?(binary()) :: boolean()
  def after_turn_command?(text) when is_binary(text) do
    case command_name(text) do
      nil -> false
      name -> name in @after_turn
    end
  end

  def after_turn_command?(_text), do: false

  @doc "The command name of a slash command's text (`\"/compact x\"` → `\"compact\"`), or nil."
  @spec command_name(binary()) :: binary() | nil
  def command_name(text) when is_binary(text) do
    case Regex.run(~r/^\/([A-Za-z0-9_.-]+)(?:\s|\z)/, String.trim_leading(text)) do
      [_, name] -> String.downcase(name)
      _ -> nil
    end
  end

  def command_name(_text), do: nil

  defp composer_action(state, text) do
    trimmed = String.trim_leading(text)

    cond do
      String.starts_with?(trimmed, "/") -> slash_action(state, text)
      WorkflowKeyword.routes?(text) -> :run_command
      true -> message_action(state)
    end
  end

  defp slash_action(state, text) do
    case SlashPalette.enter_completion(state) do
      {:complete, _name} ->
        :complete

      {:run, _name} ->
        :run_command

      nil ->
        if after_turn_command?(text) and chat_turn(state) != nil,
          do: :queue,
          else: :run_command
    end
  end

  defp message_action(state) do
    case chat_turn(state) do
      nil -> :send
      %{state: run_state} when run_state in @steerable -> :steer
      _waiting -> :queue
    end
  end

  defp draft_text(state) do
    case State.current_draft_key(state) do
      nil ->
        ""

      key ->
        case Map.get(state, :drafts) do
          %Drafts{} = drafts -> Editor.text(Drafts.fetch(drafts, key).editor)
          _ -> ""
        end
    end
  end
end
