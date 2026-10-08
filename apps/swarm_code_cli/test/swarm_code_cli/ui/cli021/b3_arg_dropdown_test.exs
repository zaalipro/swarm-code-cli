defmodule SwarmCodeCLI.UI.Cli021.B3ArgDropdownTest do
  @moduledoc """
  cli021 B3: `/<command> ` lists the command's choices under the composer,
  filtered by what is typed, the current one marked; Up/Down move, Tab completes,
  Enter completes and runs, Esc closes the list only.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, SlashPalette}
  alias SwarmCodeCLI.UI.DataSource.DTO.ModelOption

  defp workspace(state, fields) do
    workspace = Map.merge(state.read_model.snapshots.workspace, Map.new(fields))

    %{
      state
      | read_model: %{
          state.read_model
          | snapshots: Map.put(state.read_model.snapshots, :workspace, workspace)
        }
    }
  end

  defp base do
    workspace(ready(),
      effort_levels: ~w(low medium high),
      effort: "medium",
      swarm_effort_levels: ~w(low high),
      swarm_effort: nil,
      approval_mode: :auto,
      chat_model: "alpha",
      swarm_model: "beta",
      models: [
        %ModelOption{provider_id: "p1", provider: "Gateway", model: "alpha"},
        %ModelOption{provider_id: "p1", provider: "Gateway", model: "ms/glm-5.2"},
        %ModelOption{provider_id: "p2", provider: "Other", model: "beta"}
      ]
    )
  end

  defp names(state), do: Enum.map(SlashPalette.entries(state), & &1.name)
  defp texts(state), do: Enum.map(SlashPalette.entries(state), & &1.text)

  describe "which commands open a list" do
    test "/panel lists its shapes and the summaries, the current one marked" do
      state = type(base(), "/panel ")

      assert names(state) == [
               "panel auto",
               "panel full",
               "panel compact",
               "panel hidden",
               "panel summaries on",
               "panel summaries off"
             ]

      assert [%{current?: true, name: "panel full"}] =
               Enum.filter(SlashPalette.entries(state), & &1.current?) |> Enum.take(1)

      assert SlashPalette.open?(state)
      assert SlashPalette.args_open?(state)
    end

    test "the typed prefix filters, multi-word choices included" do
      assert names(type(base(), "/panel c")) == ["panel compact"]
      assert names(type(base(), "/panel sum")) == ["panel summaries on", "panel summaries off"]

      assert names(type(base(), "/panel summaries o")) ==
               ["panel summaries on", "panel summaries off"]

      assert names(type(base(), "/panel summaries off")) == ["panel summaries off"]
      assert names(type(base(), "/panel zzz")) == []
    end

    test "/approval marks the project's mode; /diff and /mouse are on or off" do
      state = type(base(), "/approval ")
      assert texts(state) == ["approval read-only", "approval auto", "approval full"]
      assert [%{text: "approval auto"}] = Enum.filter(SlashPalette.entries(state), & &1.current?)
      assert texts(type(base(), "/diff ")) == ["diff on", "diff off"]
      assert texts(type(base(), "/mouse o")) == ["mouse on", "mouse off"]

      assert [%{text: "mouse on"}] =
               Enum.filter(SlashPalette.entries(type(base(), "/mouse ")), & &1.current?)
    end

    test "/theme offers dark, light and the palettes" do
      texts = texts(type(base(), "/theme "))
      assert ["theme dark", "theme light" | palettes] = texts
      assert "theme ember" in palettes and "theme paper" in palettes
      assert texts(type(base(), "/theme e")) == ["theme ember"]
    end

    test "/effort and /worker_effort list the model's own levels, the old name too" do
      # cli022 F2: `default` heads both lists.
      assert texts(type(base(), "/effort ")) ==
               ["effort default", "effort low", "effort medium", "effort high"]

      assert [%{text: "effort medium"}] =
               Enum.filter(SlashPalette.entries(type(base(), "/effort ")), & &1.current?)

      assert texts(type(base(), "/worker_effort ")) ==
               ["worker_effort default", "worker_effort low", "worker_effort high"]

      assert texts(type(base(), "/swarm_effort h")) == ["worker_effort high"]
    end

    test "/model and /worker_model list the snapshot's models as provider|model" do
      assert texts(type(base(), "/model ")) ==
               ["model p1|alpha", "model p1|ms/glm-5.2", "model p2|beta"]

      assert [%{name: "model alpha", text: "model p1|alpha"}] =
               Enum.filter(SlashPalette.entries(type(base(), "/model ")), & &1.current?)

      # a model name is found by a part of it too
      assert texts(type(base(), "/model glm")) == ["model p1|ms/glm-5.2"]
      assert texts(type(base(), "/worker_model b")) == ["worker_model p2|beta"]
      assert texts(type(base(), "/swarm_model b")) == ["worker_model p2|beta"]
    end

    test "commands with free text have no list" do
      for text <- [
            "/goal ",
            "/goal fix",
            "/search x",
            "/rename ",
            "/consensus ",
            "/queue ",
            "/rewind "
          ],
          do: refute(SlashPalette.open?(type(base(), text)), text)
    end

    test "the command names still list while only the name is typed" do
      assert "panel" in names(type(base(), "/pan"))
      refute SlashPalette.args_open?(type(base(), "/pan"))
    end
  end

  describe "keys" do
    test "Down moves the highlight, Tab completes the draft to it" do
      # cli022 F3: the list opens on the current shape (`full`), so two Downs
      # reach `hidden`.
      state = type(base(), "/panel ") |> press!(Input.key(:down)) |> press!(Input.key(:down))
      assert SlashPalette.selected(state).text == "panel hidden"
      state = press!(state, Input.key(:tab))
      assert text(state) == "/panel hidden"
      # the list stays, showing the one row it completed to
      assert texts(state) == ["panel hidden"]
    end

    test "Enter completes the highlighted row and runs the command" do
      state = type(base(), "/panel co") |> press!(Input.key(:enter))
      assert state.panel_mode == :compact
      assert text(state) == ""
    end

    test "Enter on a daemon command sends it complete" do
      {_state, effects} = type(base(), "/effort h") |> press(Input.key(:enter))
      assert [%{kind: {:dispatch, :send, "/effort high", :main, []}}] = requests(effects)
    end

    test "Enter on the model list sends the provider|model pair" do
      {_state, effects} = type(base(), "/worker_model b") |> press(Input.key(:enter))
      assert [%{kind: {:dispatch, :send, "/worker_model p2|beta", :main, []}}] = requests(effects)
    end

    test "Enter sends the draft as typed when it already names a row exactly" do
      state = type(base(), "/panel hidden")
      assert SlashPalette.enter_completion(state) == nil
      # (the drawn Send target is not in this test's table, so `send/1`)
      {state, _effects} = send(state)
      assert state.panel_mode == :hidden
    end

    test "a model typed by its own name is sent as typed, not replaced by the pair" do
      state = type(base(), "/model alpha")
      assert names(state) == ["model alpha"]
      assert SlashPalette.enter_completion(state) == nil
      {_state, effects} = send(state)
      assert [%{kind: {:dispatch, :send, "/model alpha", :main, []}}] = requests(effects)
    end

    test "Esc closes the list only: the draft stays, typing on keeps it closed" do
      state = type(base(), "/panel ")
      assert SlashPalette.open?(state)
      state = press!(state, Input.key(:escape))
      refute SlashPalette.open?(state)
      assert text(state) == "/panel "
      state = type(state, "c")
      assert text(state) == "/panel c"
      refute SlashPalette.open?(state)
    end

    test "after Esc, clearing the draft and typing the command again reopens the list" do
      state = type(base(), "/diff ") |> press!(Input.key(:escape))
      refute SlashPalette.open?(state)
      state = press!(state, ctrl("u")) |> type("/mouse ")
      assert SlashPalette.open?(state)
    end
  end
end
