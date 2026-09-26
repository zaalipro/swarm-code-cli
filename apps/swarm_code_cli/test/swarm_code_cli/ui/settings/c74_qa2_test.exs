defmodule SwarmCodeCLI.UI.Settings.C74Qa2Test do
  @moduledoc """
  cli74 G2 (QA #2 of pass 74, `/Users/zaali/.cache/c74/Q2/qa.md`): each finding the
  polisher fixed, driven through the reducer against `Fake.Settings` and read from the
  rows or the projected screen. Where the fake answered what the service refuses (a
  record decoded with atom keys, an undo without `expected`), the test builds the
  service's shape itself; `c74_qa2_e2e_test` in the daemon runs them for real.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0, press!: 2, letter: 1]
  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.{Projector, SafeText, Size}
  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.{ModelPicker, Nav}

  defp sized(columns, rows),
    do: act!(ready(), {:resize, %Size{columns: columns, rows: rows}})

  defp lines(state) do
    {scene, _actions} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map(fn block -> Enum.map_join(block.spans, "", &SafeText.value(&1.text)) end)
  end

  defp cells(line), do: SwarmCodeCLI.UI.Width.cells(line, :narrow)
  defp typed(state, text), do: Enum.reduce(String.graphemes(text), state, &press!(&2, letter(&1)))

  defp queries(effects, kind) do
    for request <- sent(effects),
        match?({:settings_query, _}, request.kind),
        params(request)["view"] == "records",
        params(request)["kind"] == kind,
        do: request
  end

  # ------------------------------------------------------------------ P0-1

  describe "P0-1: the model picker is drawn" do
    for {columns, rows} <- [{160, 45}, {80, 24}] do
      test "Enter on Chat model floats the F4 box at #{columns}×#{rows}" do
        {state, fake} = opened(:models_effort, state: sized(unquote(columns), unquote(rows)))
        state = Nav.put_cursor(state, "key:models.chat")
        {state, _fake} = state |> verb(:enter) |> serve(fake)
        assert state.settings.mode == :editing
        assert state.settings.editing.module == ModelPicker

        lines = lines(state)

        if out = System.get_env("C74_QA2_OUT"),
          do: File.write!(Path.join(out, "picker#{unquote(columns)}.txt"), Enum.join(lines, "\n"))

        assert length(lines) == unquote(rows)

        assert Enum.all?(lines, &(cells(&1) == unquote(columns))),
               inspect(Enum.map(lines, &cells/1))

        top = Enum.find_index(lines, &(&1 =~ "┌─ Chat model"))
        assert top, Enum.join(lines, "\n")
        assert Enum.at(lines, top) =~ ~r/providers · \d+ models ─┐/
        assert Enum.at(lines, top + 1) =~ "/ type to filter · provider/model works too"
        text = Enum.join(lines, "\n")
        assert text =~ "DeepSeek"
        assert text =~ ~r/✓ deepseek-v4-pro/
        assert text =~ ~r/Enter choose .* \d+ of \d+/
        assert Enum.any?(lines, &(&1 =~ "└"))
      end
    end

    test "the filter is drawn as it is typed, and Enter chooses what is seen" do
      {state, fake} = opened(:models_effort, state: sized(160, 45))
      state = Nav.put_cursor(state, "key:models.chat")
      {state, fake} = state |> verb(:enter) |> serve(fake)
      state = typed(state, "opus")

      text = state |> lines() |> Enum.join("\n")
      assert text =~ "/ opus"
      assert text =~ "claude-opus-5"
      refute text =~ "deepseek-v4-flash "

      {_state, effects} = act(state, {:settings, {:verb, :commit}})
      _ = fake
      assert [%{"value" => %{"model" => "claude-opus-5"}}] = patches(effects)
    end
  end

  defp patches(effects) do
    for patch <- commands(effects, "values.patch"),
        change <- patch["attributes"]["changes"],
        do: change
  end

  # ------------------------------------------------------------------ P0-2

  describe "P0-2: the picker has its options before Enter can choose" do
    test "opening the picker asks for the options again, even when the page holds them" do
      {state, _fake} = opened(:models_effort)
      assert state.settings.data.records |> Map.has_key?({"model_options", %{}})

      state = Nav.put_cursor(state, "key:models.sub_agent")
      {_state, effects} = verb(state, :enter)
      assert [_] = queries(effects, "model_options")
    end

    test "Enter while the options are on their way writes nothing (it erased the model)" do
      {state, fake} = opened(:models_effort)
      layer = state.settings
      state = %{state | settings: %{layer | data: %{layer.data | records: %{}}}}
      state = Nav.put_cursor(state, "key:models.sub_agent")
      {state, loads} = verb(state, :enter)
      assert state.settings.editing.module == ModelPicker
      assert [_] = queries(loads, "model_options")

      {state, effects} = act(state, {:settings, {:verb, :commit}})
      assert sent(effects) == []
      assert state.settings.mode == :editing
      text = state |> lines() |> Enum.join("\n")
      assert text =~ "┌─ Sub-agent model"

      # the options arrive: the cursor is on the current value, not the null choice
      {state, _fake} = serve(state, loads, fake)
      display = ModelPicker.display(state.settings.editing.state, Nav.ctx(state))
      assert [{"deepseek-v4-flash", _} | _] = display.value
    end

    test "a sub-agent model row names its provider, never the id (P1-1)" do
      {state, _fake} = opened(:models_effort)
      row = key_row(state, "models.sub_agent")
      refute words(row) =~ I.ids().deepseek
      assert words(row) =~ "· DeepSeek"
    end
  end
end
