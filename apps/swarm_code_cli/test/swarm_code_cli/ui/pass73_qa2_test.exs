defmodule SwarmCodeCLI.UI.Pass73Qa2Test do
  @moduledoc """
  pass73 G2: the findings of QA #2's live check of the pass 73 release, each
  as a regression. Keys go through `Keymap.resolve/3` and `Reducer.update/2`,
  as in the session; the drawn ones are painted like the golden scenes.

    * Q2-01 a card the user focused (Ctrl-N, `n`) takes typed text the way a
      card that opened by itself does: "hey" types, it approves nothing. `?`
      opens the keys on an empty draft, as the status row says.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Composer, Input, Keymap, Layout, SafeText}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Projector.Status

  # ---------------------------------------------------------------- fixtures

  defp approval(id, opts \\ []) do
    %DTO.PendingInteraction{
      id: id,
      kind: :approval,
      run_id: Keyword.get(opts, :run, "r"),
      node_id: "op-" <> id,
      conversation_id: "c",
      expected_revision: 5,
      created_at: Keyword.get(opts, :created_at, 1),
      allowed_actions: [:approve, :deny, :always_allow],
      approval: %DTO.Approval{
        tool: Keyword.get(opts, :tool, "run_command"),
        permission: :execute,
        arguments_preview: Keyword.get(opts, :preview, "ls -la notes")
      }
    }
  end

  # A chat turn waiting on two approvals; the first opened by itself over
  # the composer, past its grace window.
  defp under_card(interactions \\ [approval("a1"), approval("a2", created_at: 2)]) do
    state = ready([run("r", :waiting_approval)], snapshot: %{interactions: interactions})
    assert [{:approval, "a1"} | _] = state.layers
    assert state.auto_opened == "a1"
    %{state | interaction_grace: nil}
  end

  # The cards put aside with Esc (the second opens by itself when the first
  # is put aside), and one brought back with Ctrl-N: the user focused it.
  defp focused_card do
    state = press!(under_card(), key(:escape))
    assert [{:approval, "a2"} | _] = state.layers
    state = press!(state, key(:escape))
    assert state.layers == []
    state = press!(state, ctrl("n"))
    assert [{:approval, id} | _] = state.layers
    assert state.auto_opened == nil
    {state, id}
  end

  defp commands(effects), do: for({:command, request} <- effects, do: request.kind)

  defp key(code, mods \\ []), do: Input.key(code, mods)

  defp status_words(state) do
    state
    |> Status.project(Layout.classify(state.size), state.size.columns)
    |> List.wrap()
    |> Enum.flat_map(fn
      %{spans: spans} -> spans
      _ -> []
    end)
    |> Enum.map_join(&SafeText.value(&1.text))
  end

  defp type_all(state, typed) do
    Enum.reduce(String.graphemes(typed), {state, []}, fn grapheme, {st, acc} ->
      {next, more} = press(st, letter(grapheme))
      {next, acc ++ more}
    end)
  end

  # ------------------------------------------------------------------ Q2-01

  describe "Q2-01 a card the user focused is typed at like one that opened by itself" do
    test "Ctrl-N, then hey: hey is the draft and nothing is decided" do
      {state, id} = focused_card()
      {state, effects} = type_all(state, "hey")

      assert commands(effects) == []
      assert text(state) == "hey"
      assert [{:approval, ^id} | _] = state.layers
    end

    test "n walks to the next card, and /consens then types, it does not walk" do
      state = press!(under_card(), letter("n"))
      assert [{:approval, "a2"} | _] = state.layers

      {state, effects} = type_all(state, "/consens")
      assert commands(effects) == []
      assert text(state) == "/consens"
      assert [{:approval, "a2"} | _] = state.layers

      # Enter completes it, the way it does under a card that opened by
      # itself, and the card stays.
      assert Composer.enter_action(state) == :complete
      {state, effects} = press(state, key(:enter))
      assert commands(effects) == []
      assert text(state) == "/consensus "
      assert [{:approval, "a2"} | _] = state.layers
    end

    test "on a focused card with an empty draft the card's own letters still decide" do
      {state, id} = focused_card()
      {_, effects} = press(state, letter("y"))
      assert [{:resolve_approval, "r", "op-" <> _, ^id, 5, :approve}] = commands(effects)

      # `n` is the next one, and a letter the card does not offer types.
      assert [{:approval, other} | _] = press!(state, letter("n")).layers
      refute other == id
      {typed, effects} = press(state, letter("a"))
      assert commands(effects) == []
      assert text(typed) == "a"
    end

    # The status row on a card with an empty draft says "? keys": `?` is one
    # of the card's own keys there, on either card, and types once the
    # draft has text.
    test "? opens the keys on an empty draft, on either card, and types after text" do
      {focused, _} = focused_card()

      for state <- [under_card(), focused] do
        assert status_words(state) =~ "? keys"
        {opened, _} = press(state, letter("?"))
        assert [:help | _] = opened.layers
        assert text(opened) == ""

        typed = state |> type("why") |> press!(letter("?"))
        assert text(typed) == "why?"
        assert [{:approval, _} | _] = typed.layers
      end
    end

    test "Enter sends a draft typed at a focused card; the card stays" do
      {state, id} = focused_card()
      state = type(state, "use the staging db")
      assert Keymap.typing_under_card?(state)
      assert Composer.enter_action(state) == :steer

      {sent, effects} = press(state, key(:enter))
      assert [{:dispatch, :send, "use the staging db", :main, []}] = commands(effects)
      assert [{:approval, ^id} | _] = sent.layers
    end
  end
end
