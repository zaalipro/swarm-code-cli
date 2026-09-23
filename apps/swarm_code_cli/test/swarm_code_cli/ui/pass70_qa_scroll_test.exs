defmodule SwarmCodeCLI.UI.Pass70QaScrollTest do
  @moduledoc """
  pass70 Q1, found driving the release: PgDn past the end left one line on
  top of a blank page, and a prompt sent while scrolled up was drawn below the
  bottom edge, so the person never saw their own turn start.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Input, Keymap, Reducer, Size, State}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns

  @key {"c", :main}

  defp item(n) do
    %DTO.TranscriptItem{
      id: "i#{n}",
      node_id: "i#{n}",
      run_id: "r",
      conversation_id: "c",
      attempt_id: "attempt",
      role: :user,
      text: "prompt number #{n}\nsecond line of #{n}"
    }
  end

  defp ready(count \\ 30) do
    size = %Size{columns: 100, rows: 24}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"},
        focus: "composer"
      })

    watch = state.watches.workspace

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send],
      runs: [
        %DTO.RunSummary{id: "r", conversation_id: "c", state: :done, revision: 1, kind: :chat}
      ],
      transcript: %DTO.TranscriptWindow{items: Enum.map(1..count, &item/1)},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: body
    }

    {state, _} = Reducer.update(state, {:data, delivery})
    state
  end

  defp press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> elem(Reducer.update(state, action), 0)
      :ignore -> state
    end
  end

  defp page_up(state), do: press(state, Input.key(:page_up))
  defp page_down(state), do: press(state, Input.key(:page_down))

  test "PgDn back onto the last screen follows the stream again" do
    state = ready()
    assert state.scrolls.main.follow?

    up = state |> page_up() |> page_up()
    refute up.scrolls.main.follow?

    down = up |> page_down() |> page_down() |> page_down()
    assert down.scrolls.main.follow?
  end

  test "a view scrolled into the last screen is drawn from the end, never over a blank page" do
    state = ready()
    following = Turns.viewport(state, 100, 18)

    # Anchored on the last item's last row, as three PgDn presses left it.
    last = List.last(Turns.view_order(state))
    height = Turns.height(state, 100, last)

    detached = %{
      state
      | scrolls: %{
          state.scrolls
          | main: %{state.scrolls.main | follow?: false, anchor: {last, height - 1, :top}}
        }
    }

    assert Turns.viewport(detached, 100, 18) == following
  end

  test "sending a prompt while scrolled up puts the view back on the stream" do
    state = ready() |> page_up() |> page_up()
    refute state.scrolls.main.follow?

    state =
      "next prompt"
      |> String.graphemes()
      |> Enum.reduce(state, &press(&2, Input.text_fragment(:press, &1, [])))

    assert Editor.text(Drafts.fetch(state.drafts, @key).editor) == "next prompt"

    {id, _} = State.next_id(state, :request)

    {sent, effects} =
      Reducer.update(state, {:invoke, {:dispatch, :send, "next prompt", :main, []}, id})

    assert [{:command, _}] = effects
    assert sent.scrolls.main.follow?
  end
end
