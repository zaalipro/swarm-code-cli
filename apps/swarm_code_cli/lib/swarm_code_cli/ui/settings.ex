defmodule SwarmCodeCLI.UI.Settings do
  @moduledoc """
  The settings layer (spec §3.7): a full-screen TUI over the shell that lets
  the user read and change every setting of SwarmCode — this terminal's
  cli.json, the shared settings row, the session and the project — plus the
  integrations (providers, search, MCP, language servers) and their checks.

  This module answers the questions the keymap and the projector ask of the
  layer; `Reducer.Settings` owns every change and `Projector.Settings` draws it.
  """

  alias SwarmCodeCLI.UI.Settings.Layer

  @contexts [
    :settings,
    :settings_search,
    :settings_edit,
    :settings_paste,
    :settings_capture,
    :settings_picker,
    :settings_popover
  ]

  @doc "The seven keymap contexts of the layer."
  def contexts, do: @contexts

  @doc "Whether the settings layer is open in `state` (a `UI.State` or any map)."
  @spec open?(map()) :: boolean()
  def open?(%{settings: %Layer{}}), do: true
  def open?(_state), do: false

  @doc """
  The keymap context the layer needs now: a popover first (a picker filters
  as the user types; a confirmation, the help or the pending-leave dialog
  takes letters), then the mode.
  """
  @spec context(Layer.t()) :: atom()
  def context(%Layer{popover: {:picker, _}}), do: :settings_picker
  def context(%Layer{popover: {:project_picker, _}}), do: :settings_picker
  def context(%Layer{popover: {_kind, _}}), do: :settings_popover
  def context(%Layer{mode: :search}), do: :settings_search
  def context(%Layer{mode: :command_line}), do: :settings_search
  def context(%Layer{mode: :paste}), do: :settings_paste
  def context(%Layer{mode: :capture}), do: :settings_capture

  def context(%Layer{mode: :editing, editing: %{context: context}}) when context in @contexts,
    do: context

  def context(%Layer{mode: :editing}), do: :settings_edit
  def context(%Layer{}), do: :settings
end
