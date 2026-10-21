defmodule SwarmCodeCLI.UI.Keymap.Context do
  @moduledoc """
  Which row of the binding table a keystroke is read against.

  One context is computed per key, before any lookup, so the grammar is a
  function of the state rather than of the order of a `cond`.

  | context | when |
  |---|---|
  | `:composer` | composer focused, no layer, keymap `:default` or vim INSERT |
  | `:composer_normal` | vim keymap, composer focused, NORMAL |
  | `:composer_visual` | vim keymap, composer focused, VISUAL |
  | `:main` | `focus == "main"`, no layer |
  | `:inspector` | `focus == "inspector"`, no layer |
  | `:picker` | the top layer searches or lists: switcher, run palette, runs dashboard, go-to, action menu, region filter, model picker |
  | `:field` | any other layer whose focus is a text field |
  | `:dialog` | any other layer |
  | `:hint` | hint mode (Ctrl-F), no layer |
  | `:overlay` | the agent overlay is open, no layer |
  | `:settings…` | the settings layer is open, no shell layer over it: one of seven by its mode and popover (`UI.Settings.context/1`, cli74) |
  | `:home_composer`, `:home_list`, `:home_map` | Home is open (orbit), no layer and no settings over it: by its focus |

  A picker is a picker before it is a field: its query *is* the layer, and its
  keys (Ctrl-N, Home, the opening chord) have to beat the field editor's.
  """

  alias SwarmCodeCLI.UI.{Keymap, Settings, State}

  @picker_layers [
    :switcher,
    :run_palette,
    :runs_dashboard,
    :jump,
    :action_menu,
    :region_filter,
    :model_picker
  ]

  @doc "The layer kinds that make the `:picker` context."
  @spec picker_layers() :: [atom()]
  def picker_layers, do: @picker_layers

  @doc "True when `layer` is one of the searching or listing layers."
  @spec picker?(term()) :: boolean()
  def picker?({kind, _id}) when kind in @picker_layers, do: true
  def picker?({:model_picker, _target, _id}), do: true
  def picker?(_layer), do: false

  @spec of(map()) :: atom()
  # C-ARCH-8: `State.surface/1` holds the precedence (hint, layers, settings,
  # Home, overlay, else the shell); this maps the owner to its context.
  def of(state) do
    case State.surface(state) do
      # pass72 F: hint mode opens over a request card (the approval card and
      # the question dialog, the layers a needs-you agent raises), so its
      # badge keys are read before the layer under it.
      :hint ->
        :hint

      {:layer, layer} ->
        cond do
          picker?(layer) -> :picker
          match?({:field_editor, _}, Keymap.editor_context(state)) -> :field
          true -> :dialog
        end

      # cli74 U1-2: the settings layer covers the shell (and the agent
      # overlay) until it closes; its mode and popover pick one of its seven
      # contexts.
      :settings ->
        Settings.context(state.settings)

      # orbit D8: Home covers the shell (and the agent overlay) until it
      # closes; layers and Settings, which open over it, are read before it.
      :home ->
        Map.fetch!(
          %{composer: :home_composer, list: :home_list, map: :home_map},
          state.home.focus
        )

      # pass72: the agent overlay covers the chat until Esc.
      :overlay ->
        :overlay

      :shell ->
        shell(state)
    end
  end

  defp shell(%{focus: "composer"} = state), do: composer(state)
  defp shell(%{focus: "inspector"}), do: :inspector
  defp shell(_state), do: :main

  # The vim modes only exist while the vim keymap is on; with `:default` the
  # composer is always the plain composer however `state.vim` happens to read.
  defp composer(%{keymap: :vim, vim: %{mode: :normal}}), do: :composer_normal
  defp composer(%{keymap: :vim, vim: %{mode: :visual}}), do: :composer_visual
  defp composer(_state), do: :composer
end
