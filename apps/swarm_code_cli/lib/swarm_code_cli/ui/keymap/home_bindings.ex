defmodule SwarmCodeCLI.UI.Keymap.HomeBindings do
  @moduledoc """
  orbit U8: Home's rows of the binding table, group `:home`. `UI.Keymap.Bindings`
  appends them to its table; they live here, like the settings layer's, so the
  shell's grammar stays readable.

  Home has three key contexts, by its focus (`Keymap.Context`): the composer
  (`:home_composer`), the resume list with its search (`:home_list`) and the
  project map (`:home_map`). The composer and the list type: a bare printable
  key is data there, never a binding (`typing_contexts/0`), so `y`, `?` and the
  digits type. The map is not a typing context, so its letters are bindings.

  Like Settings, the three contexts are never reached by `:global` bindings:
  only the chords listed here and the `passthrough/0` rows (help, the palette,
  the runs dashboard, Settings and the composer's own editing keys) work on
  Home. Ctrl-B, Ctrl-F and the rest of the shell do nothing there.

  `hints/1` is the status row's list for a context, by binding id, so a
  rebound key shows as rebound and `docs/keybindings.md` and the row agree.
  """

  alias SwarmCodeCLI.UI.Keymap.Binding

  @contexts [:home_composer, :home_list, :home_map]
  @typing_contexts [:home_composer, :home_list]

  @doc "The three Home contexts, in the order the docs list them."
  @spec contexts() :: [atom()]
  def contexts, do: @contexts

  @doc "The Home contexts where a bare printable key is data, never a binding."
  @spec typing_contexts() :: [atom()]
  def typing_contexts, do: @typing_contexts

  # {id, keys, action, contexts, label, help, hint, repeat?}
  @rows [
    {:home_enter, [{:enter, []}], {:home, :enter}, @contexts, "Open / start",
     "Composer: start work with the text, or open the selected conversation when it is empty; list: open; map: open, or copy the command for another project",
     8, false},
    {:home_escape, [{:escape, []}], {:home, :escape}, @contexts, "Back",
     "Composer: leave Home for the conversation underneath; list and map: back to the composer",
     9, false},
    {:home_focus_next, [{:tab, []}], {:home, :focus_next}, @contexts, "Next",
     "Composer, then the list, then the map, then the composer (the map only where it is drawn)",
     7, true},
    {:home_focus_previous, [{:tab, [:shift]}, {:back_tab, []}], {:home, :focus_previous},
     @contexts, "Previous", "The same walk backwards", 1, true},
    {:home_up, [{:up, []}], {:home, :up}, @contexts, "Up",
     "The conversation above (the project map: the bead above; a draft of several lines keeps it for the caret)",
     5, true},
    {:home_down, [{:down, []}], {:home, :down}, @contexts, "Down",
     "The conversation below (the project map: the bead below; a draft of several lines keeps it for the caret)",
     5, true},
    {:home_left, [{:left, []}], {:home, :left}, [:home_map], "Orbit left",
     "The orbit (project) to the left", 6, true},
    {:home_right, [{:right, []}], {:home, :right}, [:home_map], "Orbit right",
     "The orbit (project) to the right", 6, true}
  ]

  @open_ids Enum.map(1..9, &String.to_atom("home_open_#{&1}"))

  @open_rows (for n <- 1..9 do
                {Enum.at(@open_ids, n - 1), [{Integer.to_string(n), [:alt]}],
                 {:home, {:open_row, n}}, @contexts, "Open #{n}",
                 "Open conversation #{n} of the list (another project's: copy the command to open it there)",
                 if(n == 1, do: 6, else: 0), false}
              end)

  @more_rows [
    {:home_copy, [{"y", []}], {:home, :copy}, [:home_map], "Copy command",
     "Copy the command that opens the conversation under the cursor in a new terminal tab", 4,
     false},
    {:home_next_need, [{"n", [:control]}], {:home, :next_need}, @contexts, "Waiting",
     "Go to the approval or question that waits for you (another project's: copy the command)", 3,
     false},
    {:home_interrupt, [{"c", [:control]}], {:home, :interrupt}, @contexts, "Ctrl-C",
     "Clear the search, then the draft; with nothing to clear a second press quits as in the shell",
     0, false}
  ]

  @bindings Enum.map(@rows ++ @open_rows ++ @more_rows, fn {id, keys, action, contexts, label,
                                                            help, hint, repeat} ->
              %Binding{
                id: id,
                keys: keys,
                action: action,
                contexts: contexts,
                group: :home,
                label: label,
                help: help,
                hint: hint,
                repeat: repeat
              }
            end)

  @doc "Home's rows of the binding table."
  @spec all() :: [Binding.t()]
  def all, do: @bindings

  @doc """
  The binding that opens Home from the shell: Alt-O in the transcript, the
  composer (and vim NORMAL) and the inspector. `/home` is the key-free way
  (Alt is unreliable on some macOS terminals).
  """
  @spec open_binding() :: Binding.t()
  def open_binding do
    %Binding{
      id: :open_home,
      keys: [{"o", [:alt]}],
      action: :open_home,
      contexts: [:main, :composer, :inspector, :composer_normal],
      group: :layers,
      label: "Home",
      help: "Home: recent work, live runs and resume (also /home)",
      hint: 0
    }
  end

  @editor_rows [
    :composer_line_start,
    :composer_line_end,
    :composer_delete_word_backward,
    :composer_word_left,
    :composer_word_right,
    :composer_delete_word_forward,
    :composer_undo,
    :composer_redo,
    :composer_newline,
    :redraw
  ]

  @doc """
  Existing rows that also work on Home, by id, with the Home contexts they are
  added to: the composer's editing keys and the chords that open a layer.
  """
  @spec passthrough() :: [{atom(), [atom()]}]
  def passthrough do
    Enum.map(@editor_rows, &{&1, [:home_composer]}) ++
      [
        {:help, @contexts},
        {:command_palette, @contexts},
        {:runs_dashboard, @contexts},
        {:settings_open, @contexts}
      ]
  end

  @doc """
  The status row's hints for a Home context, `[{ids, words}]`, strongest first.
  `ids` are binding ids: one id prints its first key, several print their keys
  side by side (`↑↓`), and the digit rows print as `Alt-1…9`.
  """
  @spec hints(atom()) :: [{[atom()], binary()}]
  def hints(:home_composer),
    do: [{[:home_focus_next], "map"}, {:digits, "open"}, {[:help], "keys"}]

  def hints(:home_list),
    do: [
      {[:home_up, :home_down], "move"},
      {[:home_enter], "open"},
      {[:home_escape], "back"}
    ]

  def hints(:home_map),
    do: [
      {[:home_left, :home_right], "orbit"},
      {[:home_up, :home_down], "star"},
      {[:home_enter], "open"},
      {[:home_copy], "copy"},
      {[:home_escape], "back"}
    ]

  def hints(_context), do: []

  @doc "The binding ids of the nine row-opening keys, in order."
  @spec open_row_ids() :: [atom()]
  def open_row_ids, do: @open_ids
end
