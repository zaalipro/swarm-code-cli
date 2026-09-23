defmodule SwarmCodeCLI.UI.Projector.CodeCardTest do
  @moduledoc "pass71 V2 (R4): a fenced code block is a card with a one-row header."
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Projector, SafeText, Size, Theme}

  defp spans(state) do
    {scene, _table} = Projector.project(state)
    main = Enum.find(scene.regions, &(&1.role == :main))
    collect(main.blocks)
  end

  defp collect(%{spans: spans}) when is_list(spans), do: spans

  defp collect(%{__struct__: _} = block),
    do: block |> Map.from_struct() |> Map.values() |> Enum.flat_map(&collect/1)

  defp collect(list) when is_list(list), do: Enum.flat_map(list, &collect/1)
  defp collect(_), do: []

  defp state(focus) do
    size = %Size{columns: 160, rows: 45}
    caps = %Capabilities{size: size, color_mode: :truecolor}
    %{Conversation.state(:first_reply, size, caps) | focus: focus}
  end

  test "the language is a chip on the card, not faint text" do
    state = state("composer")
    chip = Enum.find(spans(state), &(SafeText.value(&1.text) == " elixir "))
    assert chip, "no language chip"
    assert chip.style.background == Theme.style(:hover, state.capabilities).background
    refute Enum.any?(spans(state), &(SafeText.value(&1.text) =~ "copy"))
  end

  test "select mode puts the copy hint at the right of the header" do
    texts = state("main") |> spans() |> Enum.map(&SafeText.value(&1.text))
    index = Enum.find_index(texts, &(&1 == " elixir "))
    assert index
    row = Enum.drop(texts, index) |> Enum.take_while(&(&1 != "\n")) |> Enum.join()
    assert row =~ ~r/ elixir +y copy $/
  end
end
