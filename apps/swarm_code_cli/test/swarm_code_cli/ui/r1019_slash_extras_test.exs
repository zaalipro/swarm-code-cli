defmodule SwarmCodeCLI.UI.R1019SlashExtrasTest do
  @moduledoc """
  C-FEAT-1 / C-FEAT-8 (CLI part): the `/` popup, the composer's command colour
  and /help list the project's custom commands and workflows the daemon names in
  the workspace metadata, and a listed row completes and runs like a builtin.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Action, Drafts, Editor, Input, Keymap, Reducer, SlashPalette}
  alias SwarmCodeCLI.UI.DataSource.{Daemon.Codec, DTO}
  alias SwarmCodeCLI.UI.Projector.Dialog

  @extras %DTO.SlashExtras{
    custom: [
      %DTO.SlashCommand{name: "deploy", description: "Ship it", args: true},
      %DTO.SlashCommand{name: "tidy", description: "Clean up", args: false}
    ],
    workflows: [%DTO.SlashWorkflow{name: "nightly", description: "Nightly sweep"}]
  }

  defp with_extras(text \\ "/") do
    state = fixture(:chat, {120, 30}, color_mode: :truecolor)
    state = put_workspace(state, slash_extras: @extras)
    key = SwarmCodeCLI.UI.State.current_draft_key(state)
    draft = Drafts.fetch(state.drafts, key)
    {:ok, editor} = Editor.apply(draft.editor, {:paste, text})
    %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor}), focus: "composer"}
  end

  defp key(state), do: SwarmCodeCLI.UI.State.current_draft_key(state)
  defp requests(effects), do: for({:command, request} <- effects, do: request)

  defp names(state), do: Enum.map(SlashPalette.entries(state), & &1.name)

  defp draft(state),
    do:
      Editor.text(
        Drafts.fetch(state.drafts, SwarmCodeCLI.UI.State.current_draft_key(state)).editor
      )

  test "/de lists /deploy and / lists /nightly, with their words" do
    assert "deploy" in names(with_extras("/de"))
    assert "nightly" in names(with_extras("/"))

    deploy = Enum.find(SlashPalette.entries(with_extras("/de")), &(&1.name == "deploy"))
    assert deploy.desc == "Ship it"
    assert deploy.args == "<args>"
    assert deploy.kind == :custom

    tidy = Enum.find(SlashPalette.entries(with_extras("/ti")), &(&1.name == "tidy"))
    assert tidy.args == ""

    nightly = Enum.find(SlashPalette.entries(with_extras("/ni")), &(&1.name == "nightly"))
    assert nightly.kind == :workflow
  end

  test "without extras (an older daemon, no snapshot yet) the list is the builtin one" do
    state = put_workspace(fixture(:chat, {120, 30}), slash_extras: %DTO.SlashExtras{})
    assert SlashPalette.extras(state) == %{custom: [], workflows: []}
    refute "deploy" in Enum.map(SlashPalette.catalogue("/"), & &1.name)

    refute "deploy" in Enum.map(
             SlashPalette.catalogue("/", SlashPalette.extras(state)),
             & &1.name
           )
  end

  test "known? reads the extras: a listed custom command is a command" do
    extras = SlashPalette.extras(with_extras())
    assert SlashPalette.known?("deploy", extras)
    assert SlashPalette.known?("nightly", extras)
    refute SlashPalette.known?("deploy")
    refute SlashPalette.known?("nope", extras)
    assert SlashPalette.known?("swarm", extras)
  end

  test "/help lists them" do
    state = with_extras()

    state = %{
      state
      | focus: "dialog",
        layers: [:help],
        layer_contexts: [%{focus: "main", hidden_focus: nil}]
    }

    text = state |> Dialog.help_lines(164) |> Enum.join("\n")

    assert text =~ ~r/\/deploy <args>\s+Ship it/
    assert text =~ ~r/\/nightly\s+Nightly sweep/
  end

  test "Tab completes a listed custom command and Enter runs a bare one" do
    state = with_extras("/dep")

    assert {:ok, {:complete_command, {:dynamic, "deploy"}}} =
             Keymap.resolve(Input.key(:tab), state, %{})

    {completed, _} = Reducer.update(state, {:complete_command, {:dynamic, "deploy"}})
    assert draft(completed) == "/deploy "

    # A command whose prompt takes arguments waits for them on Enter ...
    assert {:ok, {:complete_command, {:dynamic, "deploy"}}} =
             Keymap.resolve(Input.key(:enter), state, %{})

    # ... one that takes none runs, as a builtin without arguments does.
    tidy = with_extras("/ti")

    assert {:ok, {:run_command, {:dynamic, "tidy"}}} =
             Keymap.resolve(Input.key(:enter), tidy, %{})

    ready =
      SwarmCodeCLI.UI.Pass73Helpers.ready()
      |> put_workspace(slash_extras: @extras)
      |> then(&elem(Reducer.update(&1, {:editor, key(&1), {:insert, "/ti"}}), 0))

    {_run, effects} = Reducer.update(ready, {:run_command, {:dynamic, "tidy"}})
    assert [%{kind: {:dispatch, :send, "/tidy", :main, []}}] = requests(effects)
  end

  test "a workflow never runs from a prefix: Enter completes it" do
    state = with_extras("/ni")

    assert {:ok, {:complete_command, {:dynamic, "nightly"}}} =
             Keymap.resolve(Input.key(:enter), state, %{})
  end

  test "builtin rows keep their plain action names and the registry check" do
    state = with_extras("/sw")
    assert {:ok, {:complete_command, "swarm"}} = Keymap.resolve(Input.key(:tab), state, %{})
    assert {:error, :invalid_action} = Action.validate({:complete_command, "not-a-command"})

    assert {:error, :invalid_action} =
             Action.validate({:complete_command, {:dynamic, "has space"}})

    assert {:error, :invalid_action} = Action.validate({:run_command, {:dynamic, ""}})
    assert {:ok, _} = Action.validate({:run_command, {:dynamic, "deploy"}})

    # A dynamic name that is not a listed row changes nothing.
    {same, []} = Reducer.update(state, {:complete_command, {:dynamic, "deploy"}})
    assert same == state
  end

  test "the workspace metadata decodes the daemon's list, bounded and exact" do
    wire = %{
      "custom" => [%{"name" => "deploy", "description" => "Ship it", "args" => true}],
      "workflows" => [%{"name" => "nightly", "description" => "Nightly sweep"}]
    }

    assert {:ok, %DTO.SlashExtras{custom: [%DTO.SlashCommand{name: "deploy", args: true}]}} =
             DTO.SlashExtras.decode(wire)

    too_long = put_in(wire, ["custom", Access.at(0), "name"], String.duplicate("a", 65))
    assert {:error, :invalid_dto} = DTO.SlashExtras.decode(too_long)
    assert {:error, :invalid_dto} = DTO.SlashExtras.decode(Map.put(wire, "extra", 1))

    # The metadata and the snapshot take an older daemon's body, with no list.
    assert Codec.module_info(:exports) != []
    assert %DTO.SlashExtras{custom: [], workflows: []} = %DTO.WorkspaceMetadata{}.slash_extras
    assert %DTO.SlashExtras{custom: [], workflows: []} = %DTO.WorkspaceSnapshot{}.slash_extras
  end
end
