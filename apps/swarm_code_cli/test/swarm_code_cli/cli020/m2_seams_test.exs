defmodule SwarmCodeCLI.Cli020.M2SeamsTest do
  # cli020 M2: the seams between lanes C, D and E that only meet after the
  # merge: D's requests are the ones C's `Request.validate/1` accepts and C's
  # answers reach D's handlers; C's shell commands are E's `:shell` rows;
  # `/theme <palette>` reaches the renderer's options.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Test.Cli020State, as: S
  alias SwarmCodeCLI.UI.{Effect, Reducer}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Reducer.{HistorySearch, Remote}

  test "history search sends C's {:history_search, conversation, query}" do
    state = S.ready()
    {state, _} = Reducer.update(state, :history_search)
    {state, _} = Reducer.update(state, {:history_query, {:append, "fix"}})
    {_state, effects} = HistorySearch.fire(state)

    assert [{:history_search, conversation, "fix"}] = S.commands(effects)
    assert conversation == S.conversation()
  end

  test "C's CommandResult answers reach D's rewind and history handlers as rows" do
    turn = %DTO.RewindTurn{
      message_id: "m1",
      position: 1,
      turn: 2,
      prompt: "add a flag",
      at: 1,
      run_id: nil,
      files: 1
    }

    outcome = %{
      status: :accepted,
      feedback: nil,
      result: %DTO.CommandResult{kind: :rewind_turns, turns: [turn]}
    }

    assert {:ok, [^turn]} = Remote.outcome_payload(outcome)

    row = %DTO.HistoryRow{text: "fix the tests", conversation_id: S.conversation(), at: 1}
    outcome = %{outcome | result: %DTO.CommandResult{kind: :history, rows: [row]}}
    assert {:ok, [^row]} = Remote.outcome_payload(outcome)

    slot = %DTO.CommandResult{kind: :slot, token: String.duplicate("a", 32), path: "/tmp/x.png"}
    assert {:ok, ^slot} = Remote.outcome_payload(%{outcome | result: slot})
  end

  test "/theme <palette> sets the palette for the terminal and cli.json" do
    state = S.ready() |> S.type("/theme ember")
    {state, effects} = S.send_draft(state)

    assert {:terminal_preferences, %{palette: :ember}} in effects
    assert {:save_preferences, %{palette: :ember}} in effects
    assert {:ok, _} = Effect.validate({:terminal_preferences, %{palette: :ember}})
    assert {:error, _} = Effect.validate({:terminal_preferences, %{palette: :nope}})
    assert {:command_feedback, "Ember palette" <> _} = state.notice
  end

  test "a shell command from C's read model is drawn as E's $ row" do
    h = SwarmCodeCLI.UI.Pass73Helpers
    state = h.ready([%{h.run("s", :done) | created_sequence: 1}], columns: 110, rows: 30)
    conversation = conversation_of(state)

    shell = %DTO.ShellItem{
      id: "11111111-2222-4333-8444-555555555555",
      conversation_id: conversation,
      command: "echo hi",
      output: "hi",
      state: :done,
      exit_code: 0,
      at: 4_102_444_800_000,
      revision: 1
    }

    state = put_in(state.read_model.shells, %{shell.id => shell})
    text = SwarmCodeCLI.Cli020EHelpers.screen_text(state)

    assert text =~ "$ echo hi"
    assert text =~ "exit 0"
  end

  defp conversation_of(%{destination: {:conversation, id}}), do: id
end
