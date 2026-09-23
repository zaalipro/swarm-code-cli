defmodule SwarmCodeCLI.UI.PathCompletionTest do
  @moduledoc """
  Pass 70 E5: `@path` completion. An `@` token at the caret asks the project
  for matching paths (C8's `files` feature query), the rows show above the
  composer, Tab puts the picked path in the draft, Up/Down move, Esc steps
  the list aside, and a newer token supersedes an older query.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Input, Keymap, Reducer, Size}
  alias SwarmCodeCLI.UI.Reducer.PathCompletion
  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO}

  @a "11111111-1111-4111-8111-111111111111"
  @key {@a, :main}

  defp watch_ready(state, slot, body) do
    watch = Map.fetch!(state.watches, slot)

    {state, _} =
      Reducer.update(
        state,
        {:data,
         %Delivery{
           kind: :watch_ready,
           watch_ref: watch.watch_ref,
           request_id: nil,
           scope: watch.scope,
           generation: watch.generation,
           revision: 0,
           sequence: nil,
           body: body
         }}
      )

    state
  end

  defp ready do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, @a},
        focus: "composer"
      })

    state
    |> watch_ready(:shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: "e"}
    })
    |> watch_ready(:workspace, %DTO.WorkspaceSnapshot{
      conversation_id: @a,
      allowed_actions: [:send, :queue],
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    })
  end

  defp type(state, text) do
    Enum.reduce(String.graphemes(text), {state, []}, fn grapheme, {state, effects} ->
      {state, more} = Reducer.update(state, {:editor, @key, {:insert, grapheme}})
      {state, effects ++ more}
    end)
  end

  defp queries(effects), do: for({:query, request} <- effects, do: request)

  defp respond(state, request, paths) do
    items =
      for path <- paths,
          do: %DTO.LibraryItem{id: path, title: path, matches: [0, 1]}

    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :response,
         request_id: request.request_id,
         watch_ref: nil,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: %DTO.LibrarySnapshot{
           feature: :files,
           items: items,
           request_id: request.request_id
         }
       }}
    )
  end

  defp text(state), do: Editor.text(Drafts.fetch(state.drafts, @key).editor)

  defp open(text, paths) do
    {state, effects} = type(ready(), text)
    request = List.last(queries(effects))
    {state, []} = respond(state, request, paths)
    {state, request}
  end

  test "the caret's @ token asks the project for its paths" do
    {state, effects} = type(ready(), "look at @li")
    requests = queries(effects)

    assert [
             {:feature_query, :files, nil, nil, 20, 65_536},
             {:feature_query, :files, "l", nil, 20, 65_536},
             {:feature_query, :files, "li", nil, 20, 65_536}
           ] = Enum.map(requests, & &1.kind)

    assert Enum.all?(requests, &(&1.origin == {:feature, :files}))
    # A newer token cancels the older query, and only the newest is awaited.
    cancelled = for {:cancel_request, id} <- effects, do: id
    assert cancelled == Enum.map(Enum.drop(requests, -1), & &1.request_id)
    assert Map.keys(state.requests) == [List.last(requests).request_id]
  end

  test "no list without an @ token at the caret" do
    for text <- ["hello", "mail me at a@b", "/model x"] do
      {state, effects} = type(ready(), text)
      assert queries(effects) == [], text
      refute PathCompletion.open?(state)
    end
  end

  test "rows show, Down moves, Tab puts the path in place of the token" do
    {state, _} = open("see @lib/sw", ["lib/swarm.ex", "lib/switch.ex"])
    assert PathCompletion.open?(state)

    assert [%{id: "lib/swarm.ex", selected?: true}, %{id: "lib/switch.ex", selected?: false}] =
             PathCompletion.visible(state, 8)

    assert {:ok, {:move, :next}} = Keymap.resolve(Input.key(:down), state, %{})
    {state, []} = Reducer.update(state, {:move, :next})
    assert PathCompletion.selected(state).id == "lib/switch.ex"

    assert {:ok, {:complete_path, "lib/switch.ex"} = action} =
             Keymap.resolve(Input.key(:tab), state, %{})

    {state, _} = Reducer.update(state, action)
    assert text(state) == "see @lib/switch.ex "
    assert state.path_completion == nil
    refute PathCompletion.open?(state)

    # One undo takes the whole completion back.
    {state, _} = Reducer.update(state, {:editor, @key, :undo})
    assert text(state) == "see @lib/sw"
  end

  test "Esc steps the list aside without stopping anything; a new key brings it back" do
    {state, _} = open("@ma", ["mix.exs"])
    assert {:ok, :dismiss_completion} = Keymap.resolve(Input.key(:escape), state, %{})
    {state, _} = Reducer.update(state, :dismiss_completion)
    refute PathCompletion.open?(state)
    assert text(state) == "@ma"

    {state, effects} = type(state, "i")
    [request] = queries(effects)
    {state, []} = respond(state, request, ["main.ex"])
    assert PathCompletion.open?(state)
  end

  test "a stale answer is ignored and a space ends the token" do
    {state, effects} = type(ready(), "@a")
    [first, second] = queries(effects)
    {state, []} = respond(state, first, ["old.ex"])
    refute PathCompletion.open?(state)

    {state, []} = respond(state, second, ["app.ex"])
    assert PathCompletion.open?(state)

    {state, _} = type(state, " ")
    assert state.path_completion == nil
    refute PathCompletion.open?(state)
  end

  test "a path that is not a row completes nothing" do
    {state, _} = open("@x", ["x.ex"])
    assert {^state, []} = Reducer.update(state, {:complete_path, "elsewhere.ex"})
  end
end
