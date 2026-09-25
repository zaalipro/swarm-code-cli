defmodule SwarmCodeCLI.UI.Keymap.SettingsBindings do
  @moduledoc """
  The settings layer's rows of the binding table (spec §3.9.2), group
  `:settings`. `UI.Keymap.Bindings` appends them to its table; they live here
  so the shell's grammar stays readable.

  Every action is `{:settings, {:verb, verb}}` (two are `{:special, name}`:
  Esc goes back while `q` closes, Tab and Shift-Tab walk the regions in
  opposite directions). The layer reads the verb against its mode and the
  focused row (`Section.act/3` for the row letters).

  The seven contexts are never reached by `:global` bindings: the layer has
  its own grammar. A bare printable key is only ever bound in `:settings`
  (browsing); everywhere else it types, filters or is a button's letter.
  """

  alias SwarmCodeCLI.UI.Keymap.Binding

  @contexts [
    :settings,
    :settings_search,
    :settings_edit,
    :settings_paste,
    :settings_capture,
    :settings_picker,
    :settings_popover
  ]

  @doc "The seven settings contexts, in the order the docs list them."
  def contexts, do: @contexts

  @doc "The settings contexts where a bare printable key is data, never a binding."
  def letterless_contexts, do: @contexts -- [:settings]

  # {id, keys, verb | {:special, name}, contexts, label, help, hint, repeat?}
  @rows [
    # -------------------------------------------------------------- moving
    {:settings_up, [{:up, []}], :up,
     [:settings, :settings_search, :settings_picker, :settings_popover], "Up",
     "The row above (the result above, the option above)", 0, true},
    {:settings_down, [{:down, []}], :down,
     [:settings, :settings_search, :settings_picker, :settings_popover], "Down",
     "The row below (the result below, the option below)", 0, true},
    {:settings_page_up, [{:page_up, []}], :page_up,
     [:settings, :settings_edit, :settings_search, :settings_picker], "Page up",
     "One page up; in a number editor one big step up", 0, true},
    {:settings_page_down, [{:page_down, []}], :page_down,
     [:settings, :settings_edit, :settings_search, :settings_picker], "Page down",
     "One page down; in a number editor one big step down", 0, true},
    {:settings_first, [{:home, []}], :first,
     [:settings, :settings_edit, :settings_search, :settings_picker], "First",
     "The first row; in a text editor the start of the line", 0, false},
    {:settings_last, [{:end, []}], :last,
     [:settings, :settings_edit, :settings_search, :settings_picker], "Last",
     "The last row; in a text editor the end of the line", 0, false},
    {:settings_left, [{:left, []}], :left,
     [:settings, :settings_edit, :settings_search, :settings_popover], "Left",
     "Back to the rail; on an enum or number one step down; in text the caret left", 0, true},
    {:settings_right, [{:right, []}], :right,
     [:settings, :settings_edit, :settings_search, :settings_popover], "Right",
     "Open the section from the rail; on an enum or number one step up; in text the caret right",
     0, true},
    {:settings_big_left, [{:left, [:shift]}], :big_left, [:settings, :settings_edit],
     "Big step down", "A number one big step down (Shift-Left)", 0, true},
    {:settings_big_right, [{:right, [:shift]}], :big_right, [:settings, :settings_edit],
     "Big step up", "A number one big step up (Shift-Right)", 0, true},
    {:settings_prev_section, [{"[", []}], :prev_section, [:settings], "Prev section",
     "The section above on the rail", 1, true},
    {:settings_next_section, [{"]", []}], :next_section, [:settings], "Next section",
     "The section below on the rail", 1, true},
    {:settings_rail, [{:tab, []}, {:tab, [:shift]}, {:back_tab, []}], {:special, :settings_rail},
     [:settings], "Region",
     "Tab and Shift-Tab walk the rail, the page and the detail (the tabs of the cleanup wizard)",
     2, false},
    {:settings_jump, [{"f", [:control]}], :jump, [:settings], "Jump",
     "Letter badges on the rail; the badge's letter opens that section", 2, false},

    # --------------------------------------------------------- the layer
    {:settings_close, [{:escape, []}, {"q", []}, {{:function, 2}, []}],
     {:special, :settings_close}, [:settings], "Back",
     "Esc goes back one level and closes Settings at a section page; q and F2 close Settings", 9,
     false},
    {:settings_open_row, [{:enter, []}], :enter,
     [:settings, :settings_search, :settings_picker, :settings_popover], "Open",
     "Open, edit or run the focused row (choose the option, press the focused button)", 8, false},
    {:settings_toggle, [{" ", []}], :toggle, [:settings], "Toggle",
     "Flip a toggle, a switch or a checklist item", 7, false},
    {:settings_search, [{"/", []}], :search, [:settings], "Search",
     "Search every setting; in a list of more than 20 rows, filter the list", 7, false},
    {:settings_command, [{":", []}], :command, [:settings], "Command",
     "The command line: `:set key value`, `:reset key`, `:go section`", 1, false},
    {:settings_help, [{"?", []}, {{:function, 1}, []}], :help,
     [:settings, :settings_search, :settings_edit, :settings_picker, :settings_paste], "Keys",
     "Every key of this page; the same key closes it", 6, false},
    {:settings_info, [{"i", []}], :info, [:settings], "Detail",
     "The detail of the focused row (a page of its own on a small terminal)", 1, false},
    {:settings_refresh, [{"r", [:control]}], :refresh, [:settings], "Refresh",
     "Read this page again from the daemon and cli.json", 0, false},
    {:settings_needs_you, [{"n", [:control]}], :needs_you, [:settings, :settings_search],
     "Needs you", "Close Settings and go to the run that waits for you", 3, false},
    {:settings_interrupt, [{"c", [:control]}], :interrupt, @contexts, "Ctrl-C",
     "Clear the text, then cancel; on a page close Settings (twice quits, as in the shell)",
     [settings_capture: 1], false},
    {:settings_save, [{"s", [:control]}], :save, [:settings, :settings_edit], "Save",
     "Create the record being drafted; commit a multi-line text", 2, false},
    {:settings_external, [{"x", [:control]}], :external, [:settings, :settings_edit], "Editor",
     "Edit the text or the file in your editor (terminal.editor, VISUAL, EDITOR)", 1, false},
    {:settings_undo, [{"u", []}, {"z", [:control]}], :undo, [:settings], "Undo",
     "Undo the last change made here (not a key: those are never kept)", 3, false},
    {:settings_redo, [{"U", []}, {"y", [:control]}], :redo, [:settings], "Redo",
     "Redo what undo took back", 1, false},

    # ------------------------------------------------------- row letters
    {:settings_reset, [{"r", []}], :reset, [:settings], "Reset",
     "Reset to the default (revert a staged field)", 4, false},
    {:settings_restart, [{"R", []}], :restart, [:settings], "Restart",
     "Restart an MCP server now; reload the project file", 2, false},
    {:settings_add, [{"a", []}], :add, [:settings], "Add", "Add a record or a list item", 5,
     false},
    {:settings_add_key, [{"+", []}], :add_key, [:settings], "Add a key",
     "Key bindings: capture an additional key (4 at most)", 2, false},
    {:settings_delete, [{"x", []}, {:delete, []}], :delete, [:settings], "Delete",
     "Delete the focused item (asks when it cannot be undone)", 4, false},
    {:settings_delete_record, [{"D", []}], :delete_record, [:settings], "Delete record",
     "Delete the record this page shows (asks)", 2, false},
    {:settings_remove_all, [{"X", []}], :remove_all, [:settings], "Remove all",
     "Remove every item of a list; unbind every key of a binding (asks)", 1, false},
    {:settings_move_up, [{"K", []}, {:up, [:shift]}], :move_up, [:settings], "Move up",
     "Move the focused item up an ordered list", 2, true},
    {:settings_move_down, [{"J", []}, {:down, [:shift]}], :move_down, [:settings], "Move down",
     "Move the focused item down an ordered list", 2, true},
    {:settings_test, [{"t", []}], :test, [:settings], "Test",
     "Test the connection, the key or the command", 5, false},
    {:settings_fetch, [{"f", []}], :fetch, [:settings], "Fetch", "Fetch the provider's models", 4,
     false},
    {:settings_open_related, [{"o", []}], :open_related, [:settings], "Open",
     "An MCP server's output; a file's or a path's folder", 3, false},
    {:settings_cancel_task, [{"c", []}], :cancel_task, [:settings], "Cancel",
     "Cancel the task running on the focused row", 4, false},
    {:settings_copy, [{"y", []}], :copy, [:settings], "Copy",
     "Copy the setting's key or the path (never a secret)", 1, false},
    {:settings_new, [{"n", []}], :new, [:settings], "New",
     "Library: a new command, skill, agent definition or workflow file", 3, false},
    {:settings_clear, [{"C", []}], :clear, [:settings], "Clear", "Memory: clear the file (asks)",
     1, false},
    {:settings_edit_external, [{"e", []}], :edit_external, [:settings], "Edit",
     "Edit the file in your editor (as Ctrl-X)", 3, false},
    {:settings_all_on, [{"A", []}], :all_on, [:settings], "All on",
     "MCP tools: every tool on; storage sessions: pick every one shown", 1, false},
    {:settings_all_off, [{"N", []}], :all_off, [:settings], "All off",
     "MCP tools: every tool off", 1, false},
    {:settings_alt, [{"s", []}], :alt, [:settings], "Second action",
     "The row's second action: treat as secret, sort, save it anyway", 1, false},
    {:settings_goto, [{"g", []}], :goto, [:settings], "Go to",
     "A search result's section (vim: g g is the first row)", 1, false},

    # --------------------------------------------- typing (search, edit)
    {:settings_escape, [{:escape, []}], :escape,
     [:settings_search, :settings_edit, :settings_paste, :settings_picker, :settings_popover],
     "Esc", "Cancel the editor (the old value stays); clear the search, then leave; close once",
     9, false},
    {:settings_edit_commit, [{:enter, []}], :commit, [:settings_edit], "Save",
     "Save the value (a new line in a multi-line text: Ctrl-S saves)", 8, false},
    {:settings_complete, [{:tab, []}], :complete, [:settings_search, :settings_edit], "Complete",
     "Complete a key, a path, a model, an env name or an @filter", 3, false},
    {:settings_line_start, [{"a", [:control]}], :line_start, [:settings_edit, :settings_search],
     "Line start", "The caret to the start of the line", 0, false},
    {:settings_line_end, [{"e", [:control]}], :line_end, [:settings_edit, :settings_search],
     "Line end", "The caret to the end of the line", 0, false},
    {:settings_delete_word, [{"w", [:control]}], :delete_word,
     [:settings_edit, :settings_search, :settings_picker], "Delete word",
     "Delete the word before the caret", 0, true},
    {:settings_clear_line, [{"u", [:control]}], :clear_line,
     [:settings_edit, :settings_search, :settings_picker], "Clear",
     "Delete everything before the caret", 1, false},
    {:settings_backspace, [{:backspace, []}], :backspace,
     [:settings_edit, :settings_search, :settings_picker, :settings_popover], "Backspace",
     "Delete the character before the caret", 0, true},
    {:settings_delete_forward, [{:delete, []}], :delete_forward,
     [:settings_edit, :settings_search, :settings_picker], "Delete",
     "Delete the character after the caret", 0, true},

    # ------------------------------------------------------------ paste
    {:settings_paste_commit, [{:enter, []}], :paste_commit, [:settings_paste], "Save",
     "Check the pasted key and save it", 8, false},
    {:settings_paste_clear, [{"u", [:control]}], :paste_clear, [:settings_paste], "Clear",
     "Drop what was pasted", 3, false},
    {:settings_paste_type, [{"t", [:control]}], :paste_type, [:settings_paste], "Type instead",
     "Type the key instead of pasting it (never shown)", 4, false},

    # ---------------------------------------------------------- popover
    {:settings_popover_next, [{:tab, []}], :next_button, [:settings_popover], "Next button",
     "The next button (focus stays inside the popover)", 2, false},
    {:settings_popover_previous, [{:tab, [:shift]}, {:back_tab, []}], :previous_button,
     [:settings_popover], "Prev button", "The previous button", 1, false}
  ]

  @bindings Enum.map(@rows, fn {id, keys, verb, contexts, label, help, hint, repeat} ->
              action =
                case verb do
                  {:special, _} = special -> special
                  verb -> {:settings, {:verb, verb}}
                end

              %Binding{
                id: id,
                keys: keys,
                action: action,
                contexts: contexts,
                group: :settings,
                label: label,
                help: help,
                hint: hint,
                repeat: repeat
              }
            end)

  # The two special bindings answer with these verbs, and vim adds its own.
  @extra_verbs [:back, :close, :next_region, :previous_region]

  @verbs @rows
         |> Enum.flat_map(fn
           {_, _, {:special, _}, _, _, _, _, _} -> []
           {_, _, verb, _, _, _, _, _} -> [verb]
         end)
         |> Kernel.++(@extra_verbs)
         |> Enum.uniq()

  @doc "The settings rows of the binding table."
  @spec all() :: [Binding.t()]
  def all, do: @bindings

  @doc "Every verb a settings key can send."
  @spec verbs() :: [atom()]
  def verbs, do: @verbs

  @doc """
  The binding that opens Settings from the shell: F2 in the transcript, the
  composer (and vim NORMAL) and the inspector.
  """
  @spec open_binding() :: Binding.t()
  def open_binding do
    %Binding{
      id: :settings_open,
      keys: [{{:function, 2}, []}],
      action: {:settings_open, nil},
      contexts: [:main, :composer, :inspector, :composer_normal],
      group: :layers,
      label: "Settings",
      help:
        "Settings: every setting, provider, search engine, MCP server and key (also /settings)",
      hint: [main: 1, inspector: 1]
    }
  end
end
