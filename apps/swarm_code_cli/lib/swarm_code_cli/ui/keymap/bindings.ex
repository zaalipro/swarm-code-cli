defmodule SwarmCodeCLI.UI.Keymap.Binding do
  @moduledoc """
  One row of the keyboard grammar.

  `keys` are `{code, mods}` pairs in the shape `Keymap` looks them up with: a
  special key code (`:enter`, `{:function, 1}`) or a text fragment (`"j"`), and
  a sorted modifier list with `:shift` already stripped from text fragments
  (uppercase arrives as the uppercase fragment, so `"G"` and `"g"` are distinct
  codes and `:shift` carries no information there).

  `action` is one of

    * a literal `UI.Action` the resolver validates and returns,
    * `{:special, name}` for an action that needs state or the table, resolved
      by `UI.Keymap.Special` (module attributes cannot hold functions, so a
      stateful entry is a symbolic atom),
    * `{:editor_op, operation}` for an `Editor.Operation` the resolver aims at
      whichever editor the context owns (composer draft or field editor).

  `repeat` says whether the binding fires on an auto-repeat phase. A binding
  that does not repeat falls through on `:repeat` exactly as if it were unbound,
  which is what keeps a held `q` typing into a picker filter rather than
  closing the layer once per repeat.
  """

  @enforce_keys [:id, :keys, :action, :contexts, :group, :label, :help]
  defstruct [:id, :keys, :action, :contexts, :group, :label, :help, hint: 0, repeat: false]

  @type key :: {atom() | {:function, 1..12} | binary(), [atom()]}
  @type t :: %__MODULE__{
          id: atom(),
          keys: [key()],
          action: term(),
          contexts: [atom()],
          group: atom(),
          label: binary(),
          help: binary(),
          hint: non_neg_integer() | [{atom(), non_neg_integer()}],
          repeat: boolean()
        }
end

defmodule SwarmCodeCLI.UI.Keymap.Bindings do
  @moduledoc """
  The keyboard grammar. One table, read by the resolver, the status hints and
  the help sheet.

  Anything not listed here is unbound. `:global` in `contexts` expands to every
  context, except that a bare printable key (a text fragment with no command
  modifier) is dropped from the contexts where it would be typing — the
  composer, a field editor and a picker's filter. That is why `?` opens help
  everywhere but inside a text field, while `F1` opens it everywhere.
  """

  alias SwarmCodeCLI.UI.Keymap.Binding

  @contexts [
    :composer,
    :composer_normal,
    :composer_visual,
    :main,
    :inspector,
    :picker,
    :field,
    :dialog
  ]

  # The contexts where a bare printable key is the user typing, not a binding.
  @typing_contexts [:composer, :field, :picker]

  # The groups the help sheet renders, in the order it renders them. Vim first:
  # it only appears in the NORMAL and VISUAL sheets, where it is the point.
  @groups [:vim, :navigate, :focus, :runs, :act, :layers, :edit, :session]

  @inspector_tabs [:thread, :agents, :timeline, :changes]

  @bindings [
    # ------------------------------------------------------------------
    # Session and layers
    # ------------------------------------------------------------------
    %Binding{
      id: :help,
      keys: [{"?", []}, {{:function, 1}, []}],
      action: {:special, :help},
      contexts: [:global],
      group: :session,
      label: "Help",
      help: "The keyboard help sheet; the same key closes it",
      hint: [
        main: 6,
        inspector: 6,
        dialog: 3,
        picker: 2,
        composer: 1,
        composer_normal: 2,
        composer_visual: 1,
        field: 1
      ]
    },
    %Binding{
      id: :command_palette,
      keys: [{"k", [:control]}],
      action: {:special, :command_palette},
      contexts: [:global],
      group: :layers,
      label: "Palette",
      help: "Command palette; the same chord closes it",
      hint: 7
    },
    %Binding{
      id: :runs_dashboard,
      keys: [{"g", [:control]}],
      action: {:special, :runs_dashboard},
      contexts: [:global],
      group: :layers,
      label: "Runs",
      help: "Runs dashboard; the same chord closes it",
      hint: 5
    },
    # Everywhere but the composer's NORMAL and VISUAL modes, where Ctrl-R is
    # vim's redo; the palette is one Esc away from there.
    %Binding{
      id: :run_palette,
      keys: [{"r", [:control]}],
      action: {:special, :run_palette},
      contexts: [:composer, :main, :inspector, :picker, :field, :dialog],
      group: :layers,
      label: "Switch run",
      help: "Run palette; the same chord closes it",
      hint: 3
    },
    %Binding{
      id: :toggle_inspector,
      keys: [{"b", [:control]}, {"i", [:alt]}],
      action: {:toggle_dock, :inspector},
      contexts: [:global],
      group: :layers,
      label: "Inspector",
      help: "Show or hide the inspector dock",
      hint: 2
    },
    %Binding{
      id: :detach,
      keys: [{"c", [:control]}],
      action: {:special, :detach},
      contexts: [:global],
      group: :session,
      label: "Detach",
      help: "Detach from the session and leave it running",
      hint: 0
    },
    %Binding{
      id: :close_or_quit,
      keys: [{"q", []}],
      action: {:special, :close_or_quit},
      contexts: [:main, :inspector, :dialog, :picker],
      group: :session,
      label: "Close/Quit",
      help: "Close the top layer; with none open, quit",
      hint: [main: 4, inspector: 4, dialog: 4]
    },
    # Never hinted where it declines: in main with nothing open it does nothing.
    %Binding{
      id: :escape,
      keys: [{:escape, []}],
      action: {:special, :escape},
      contexts: [:global],
      group: :session,
      label: "Back out",
      help: "Step out one level; never navigates history",
      hint: [composer: 8, composer_normal: 7, composer_visual: 8, dialog: 6, picker: 5]
    },
    %Binding{
      id: :back,
      keys: [{:left, [:alt]}, {:backspace, []}],
      action: :back,
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Back",
      help: "Go back to where you came from",
      hint: 2
    },
    %Binding{
      id: :presenter_handoff,
      keys: [{"P", []}],
      action: {:presenter_handoff_requested, :plain},
      contexts: [:main, :inspector],
      group: :session,
      label: "Plain",
      help: "Hand off to the plain presenter",
      hint: 0
    },

    # ------------------------------------------------------------------
    # Focus
    # ------------------------------------------------------------------
    %Binding{
      id: :focus_next,
      keys: [{:tab, []}],
      action: {:special, :focus_next},
      contexts: [:global],
      group: :focus,
      label: "Next",
      help: "Move focus on; from the transcript, into the composer",
      hint: [composer: 5, main: 2, inspector: 2, dialog: 1],
      repeat: true
    },
    %Binding{
      id: :focus_previous,
      keys: [{:tab, [:shift]}, {:back_tab, []}],
      action: {:focus_cycle, :previous},
      contexts: [:global],
      group: :focus,
      label: "Previous",
      help: "Move focus back",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :focus_composer,
      keys: [{"i", []}],
      action: {:special, :focus_composer},
      contexts: [:main, :inspector],
      group: :focus,
      label: "Compose",
      help: "Focus the composer (INSERT in vim)",
      hint: 9
    },

    # ------------------------------------------------------------------
    # Runs
    # ------------------------------------------------------------------
    %Binding{
      id: :jump_prefix,
      keys: [{"g", []}],
      action: {:special, :jump},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Go to",
      help: "Go-to prefix: g top, G bottom, t / T run tabs",
      hint: 3
    },
    %Binding{
      id: :jump_top,
      keys: [{"g", []}],
      action: {:special, :jump_first},
      contexts: [:picker],
      group: :navigate,
      label: "Top",
      help: "From the go-to popup, jump to the first item",
      hint: 0
    },
    %Binding{
      id: :jump_bottom,
      keys: [{"G", []}],
      action: {:special, :jump_last},
      contexts: [:picker],
      group: :navigate,
      label: "Bottom",
      help: "From the go-to popup, jump to the last item",
      hint: 0
    },
    %Binding{
      id: :jump_next_run,
      keys: [{"t", []}],
      action: {:special, :jump_run_next},
      contexts: [:picker],
      group: :runs,
      label: "Next run",
      help: "From the go-to popup, the next run tab",
      hint: 0
    },
    %Binding{
      id: :jump_previous_run,
      keys: [{"T", []}],
      action: {:special, :jump_run_previous},
      contexts: [:picker],
      group: :runs,
      label: "Prev run",
      help: "From the go-to popup, the previous run tab",
      hint: 0
    },
    %Binding{
      id: :run_tab_1,
      keys: [{"1", [:alt]}],
      action: {:run_tab, 1},
      contexts: [:global],
      group: :runs,
      label: "Run 1",
      help: "Switch to the first run tab as drawn",
      hint: 0
    },
    %Binding{
      id: :run_tab_2,
      keys: [{"2", [:alt]}],
      action: {:run_tab, 2},
      contexts: [:global],
      group: :runs,
      label: "Run 2",
      help: "Switch to the second run tab as drawn",
      hint: 0
    },
    %Binding{
      id: :run_tab_3,
      keys: [{"3", [:alt]}],
      action: {:run_tab, 3},
      contexts: [:global],
      group: :runs,
      label: "Run 3",
      help: "Switch to the third run tab as drawn",
      hint: 0
    },
    %Binding{
      id: :run_tab_4,
      keys: [{"4", [:alt]}],
      action: {:run_tab, 4},
      contexts: [:global],
      group: :runs,
      label: "Run 4",
      help: "Switch to the fourth run tab as drawn",
      hint: 0
    },
    %Binding{
      id: :inspector_tab_next,
      keys: [{"]", []}],
      action: {:special, :inspector_tab_next},
      contexts: [:global],
      group: :runs,
      label: "Next tab",
      help: "Next inspector tab while the inspector is visible",
      hint: 1
    },
    %Binding{
      id: :inspector_tab_previous,
      keys: [{"[", []}],
      action: {:special, :inspector_tab_previous},
      contexts: [:global],
      group: :runs,
      label: "Prev tab",
      help: "Previous inspector tab while the inspector is visible",
      hint: 0
    },
    %Binding{
      id: :stop_run,
      keys: [{"x", []}],
      action: {:special, :stop_run},
      contexts: [:main, :inspector],
      group: :act,
      label: "Stop",
      help: "Stop the current run (asks to confirm)",
      hint: 2
    },
    %Binding{
      id: :pause_run,
      keys: [{"p", []}],
      action: {:special, :pause_run},
      contexts: [:main, :inspector],
      group: :act,
      label: "Pause",
      help: "Pause or continue the current run",
      hint: 1
    },
    %Binding{
      id: :mark_seen,
      keys: [{"m", []}],
      action: {:special, :mark_seen},
      contexts: [:main, :inspector],
      group: :act,
      label: "Mark read",
      help: "Mark the current run as seen",
      hint: 0
    },
    %Binding{
      id: :action_menu,
      keys: [{"a", []}],
      action: {:special, :action_menu},
      contexts: [:main, :inspector],
      group: :act,
      label: "Actions",
      help: "Open the action menu for what is selected",
      hint: 3
    },
    %Binding{
      id: :run_inspector,
      keys: [{"t", []}],
      action: {:special, :run_inspector},
      contexts: [:main, :inspector],
      group: :runs,
      label: "Inspect",
      help: "Open the run inspector over this run",
      hint: 2
    },
    %Binding{
      id: :open_detail,
      keys: [{"o", []}],
      action: {:special, :open_detail},
      contexts: [:main, :inspector],
      group: :act,
      label: "Detail",
      help: "Open the full text of the selected item",
      hint: 1
    },

    # ------------------------------------------------------------------
    # Selection and scrolling, main and inspector
    # ------------------------------------------------------------------
    %Binding{
      id: :move_next,
      keys: [{"j", []}, {:down, []}],
      action: {:move, :next},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Down",
      help: "Move the selection down",
      hint: 1,
      repeat: true
    },
    %Binding{
      id: :move_previous,
      keys: [{"k", []}, {:up, []}],
      action: {:move, :previous},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Up",
      help: "Move the selection up",
      hint: 1,
      repeat: true
    },
    %Binding{
      id: :move_first,
      keys: [{:home, []}],
      action: {:move, :first},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Top",
      help: "Select the first item (also g g)",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :move_last,
      keys: [{"G", []}, {:end, []}],
      action: {:move, :last},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Bottom",
      help: "Select the last item and follow the stream",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :scroll_page_down,
      keys: [{:page_down, []}],
      action: {:special, :scroll_page_down},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Page down",
      help: "Scroll one page down",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :scroll_page_up,
      keys: [{:page_up, []}],
      action: {:special, :scroll_page_up},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Page up",
      help: "Scroll one page up",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :scroll_half_down,
      keys: [{"d", [:control]}],
      action: {:special, :scroll_half_down},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Half down",
      help: "Scroll half a page down",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :scroll_half_up,
      keys: [{"u", [:control]}],
      action: {:special, :scroll_half_up},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Half up",
      help: "Scroll half a page up",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :scroll_line_down,
      keys: [{"e", [:control]}],
      action: {:special, :scroll_line_down},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Line down",
      help: "Scroll one line down, keeping the selection",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :scroll_line_up,
      keys: [{"y", [:control]}],
      action: {:special, :scroll_line_up},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Line up",
      help: "Scroll one line up, keeping the selection",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :collapse,
      keys: [{"h", []}, {:left, []}],
      action: {:special, :collapse},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Collapse",
      help: "Collapse the selected item",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :expand,
      keys: [{"l", []}, {:right, []}],
      action: {:special, :expand},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Expand",
      help: "Expand the selected item",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :toggle_expand,
      keys: [{" ", []}],
      action: {:special, :toggle_expand},
      contexts: [:main, :inspector],
      group: :navigate,
      label: "Toggle",
      help: "Expand or collapse the selected item",
      hint: 0
    },
    %Binding{
      id: :activate,
      keys: [{:enter, []}],
      action: {:special, :activate},
      contexts: [:main, :inspector, :picker, :field, :dialog],
      group: :act,
      label: "Act",
      help: "Activate what is focused",
      hint: 8
    },
    # The same key and the same special as :activate, split out so the status
    # bar and the help sheet can call it what it is in the composer.
    %Binding{
      id: :send,
      keys: [{:enter, []}],
      action: {:special, :send},
      contexts: [:composer, :composer_normal, :composer_visual],
      group: :act,
      label: "Send",
      help: "Send the draft (in every vim mode)",
      hint: 9
    },
    %Binding{
      id: :queue,
      keys: [{:enter, [:alt]}],
      action: {:special, :queue},
      contexts: [:global],
      group: :act,
      label: "Queue",
      help: "Queue the draft instead of sending it",
      hint: 0
    },

    # ------------------------------------------------------------------
    # Pickers
    # ------------------------------------------------------------------
    %Binding{
      id: :picker_next,
      keys: [{:down, []}, {"n", [:control]}],
      action: {:focus_cycle, :next},
      contexts: [:picker],
      group: :navigate,
      label: "Down",
      help: "Next result",
      hint: 4,
      repeat: true
    },
    %Binding{
      id: :picker_previous,
      keys: [{:up, []}, {"p", [:control]}],
      action: {:focus_cycle, :previous},
      contexts: [:picker],
      group: :navigate,
      label: "Up",
      help: "Previous result",
      hint: 3,
      repeat: true
    },
    %Binding{
      id: :picker_page_down,
      keys: [{:page_down, []}, {"d", [:control]}],
      action: {:special, :picker_page_down},
      contexts: [:picker],
      group: :navigate,
      label: "Page down",
      help: "A screenful further down the list",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :picker_page_up,
      keys: [{:page_up, []}, {"u", [:control]}],
      action: {:special, :picker_page_up},
      contexts: [:picker],
      group: :navigate,
      label: "Page up",
      help: "A screenful further up the list",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :picker_first,
      keys: [{:home, []}],
      action: {:special, :picker_first},
      contexts: [:picker],
      group: :navigate,
      label: "Top",
      help: "The first row of the list",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :picker_last,
      keys: [{:end, []}],
      action: {:special, :picker_last},
      contexts: [:picker],
      group: :navigate,
      label: "Bottom",
      help: "The last row of the list",
      hint: 0,
      repeat: true
    },

    # ------------------------------------------------------------------
    # Dialogs
    # ------------------------------------------------------------------
    %Binding{
      id: :dialog_next,
      keys: [{"j", []}, {:down, []}, {:right, []}],
      action: {:focus_cycle, :next},
      contexts: [:dialog],
      group: :navigate,
      label: "Down",
      help: "Focus the next control",
      hint: 5,
      repeat: true
    },
    %Binding{
      id: :dialog_previous,
      keys: [{"k", []}, {:up, []}, {:left, []}],
      action: {:focus_cycle, :previous},
      contexts: [:dialog],
      group: :navigate,
      label: "Up",
      help: "Focus the previous control",
      hint: 4,
      repeat: true
    },
    %Binding{
      id: :dialog_page_down,
      keys: [{:page_down, []}],
      action: {:special, :dialog_page_down},
      contexts: [:dialog],
      group: :navigate,
      label: "Page down",
      help: "Scroll the dialog down a page",
      hint: 1,
      repeat: true
    },
    %Binding{
      id: :dialog_page_up,
      keys: [{:page_up, []}],
      action: {:special, :dialog_page_up},
      contexts: [:dialog],
      group: :navigate,
      label: "Page up",
      help: "Scroll the dialog up a page",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :dialog_half_down,
      keys: [{"d", [:control]}],
      action: {:scroll, "dialog", {:half_page, 1}},
      contexts: [:dialog],
      group: :navigate,
      label: "Half down",
      help: "Scroll the dialog down half a page",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :dialog_half_up,
      keys: [{"u", [:control]}],
      action: {:scroll, "dialog", {:half_page, -1}},
      contexts: [:dialog],
      group: :navigate,
      label: "Half up",
      help: "Scroll the dialog up half a page",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :dialog_first,
      keys: [{:home, []}],
      action: {:scroll, "dialog", :first},
      contexts: [:dialog],
      group: :navigate,
      label: "Top",
      help: "Scroll the dialog to the top",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :dialog_last,
      keys: [{"G", []}, {:end, []}],
      action: {:scroll, "dialog", :last},
      contexts: [:dialog],
      group: :navigate,
      label: "Bottom",
      help: "Scroll the dialog to the bottom",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :approve,
      keys: [{"a", []}],
      action: {:special, :approve},
      contexts: [:dialog],
      group: :act,
      label: "Approve",
      help: "Approve the pending request",
      hint: 3
    },
    %Binding{
      id: :deny,
      keys: [{"d", []}],
      action: {:special, :deny},
      contexts: [:dialog],
      group: :act,
      label: "Deny",
      help: "Deny the pending request",
      hint: 2
    },
    %Binding{
      id: :always_allow,
      keys: [{"A", []}],
      action: {:special, :always_allow},
      contexts: [:dialog],
      group: :act,
      label: "Always",
      help: "Approve this request and ones like it",
      hint: 0
    },
    %Binding{
      id: :confirm_yes,
      keys: [{"y", []}],
      action: {:special, :confirm_yes},
      contexts: [:dialog],
      group: :act,
      label: "Yes",
      help: "Confirm: yes",
      hint: 2
    },
    %Binding{
      id: :confirm_no,
      keys: [{"n", []}],
      action: {:special, :confirm_no},
      contexts: [:dialog],
      group: :act,
      label: "No",
      help: "Confirm: no, close without doing it",
      hint: 1
    },
    %Binding{
      id: :question_option,
      keys: [
        {"1", []},
        {"2", []},
        {"3", []},
        {"4", []},
        {"5", []},
        {"6", []},
        {"7", []},
        {"8", []},
        {"9", []}
      ],
      action: {:special, :question_option},
      contexts: [:dialog],
      group: :act,
      label: "1-9 pick",
      help: "Pick a numbered question option",
      hint: 1
    },
    %Binding{
      id: :select_option,
      keys: [{" ", []}],
      action: {:special, :select_option},
      contexts: [:dialog],
      group: :act,
      label: "Select",
      help: "Tick or untick the focused option",
      hint: 0
    },

    # ------------------------------------------------------------------
    # Field editors
    # ------------------------------------------------------------------
    %Binding{
      id: :field_left,
      keys: [{:left, []}],
      action: {:special, :field_left},
      contexts: [:field],
      group: :edit,
      label: "Left",
      help: "Move the cursor left, or pick the previous choice",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :field_right,
      keys: [{:right, []}],
      action: {:special, :field_right},
      contexts: [:field],
      group: :edit,
      label: "Right",
      help: "Move the cursor right, or pick the next choice",
      hint: 0,
      repeat: true
    },

    # ------------------------------------------------------------------
    # Composer, default keymap (readline)
    # ------------------------------------------------------------------
    %Binding{
      id: :composer_newline,
      keys: [{"o", [:control]}, {:enter, [:shift]}],
      action: {:special, :composer_newline},
      contexts: [:composer, :field],
      group: :edit,
      label: "Newline",
      help: "Insert a line break without sending",
      hint: 7
    },
    %Binding{
      id: :composer_up,
      keys: [{:up, []}],
      action: {:special, :composer_up},
      contexts: [:composer],
      group: :edit,
      label: "Up",
      help: "Up a line, or up the slash-command list",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_down,
      keys: [{:down, []}],
      action: {:special, :composer_down},
      contexts: [:composer],
      group: :edit,
      label: "Down",
      help: "Down a line, or down the slash-command list",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_line_start,
      keys: [{"a", [:control]}],
      action: {:editor_op, {:move, :line_start}},
      contexts: [:composer, :field],
      group: :edit,
      label: "Line start",
      help: "Move to the start of the line",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_line_end,
      keys: [{"e", [:control]}],
      action: {:editor_op, {:move, :line_end}},
      contexts: [:composer, :field],
      group: :edit,
      label: "Line end",
      help: "Move to the end of the line",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_delete_word_backward,
      keys: [{"w", [:control]}],
      action: {:editor_op, :delete_word_backward},
      contexts: [:composer, :field],
      group: :edit,
      label: "Del word",
      help: "Delete the word before the cursor",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_delete_line_start,
      keys: [{"u", [:control]}],
      action: {:editor_op, {:delete, :line_start}},
      contexts: [:composer, :field],
      group: :edit,
      label: "Del to start",
      help: "Delete back to the start of the line",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_undo,
      keys: [{"z", [:control]}],
      action: {:editor_op, :undo},
      contexts: [:composer, :field],
      group: :edit,
      label: "Undo",
      help: "Undo the last edit",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_redo,
      keys: [{"z", [:control, :shift]}],
      action: {:editor_op, :redo},
      contexts: [:composer, :field],
      group: :edit,
      label: "Redo",
      help: "Redo (needs a terminal that reports Ctrl-Shift)",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_taller,
      keys: [{:up, [:control]}],
      action: {:composer_height, {:nudge, 1}},
      contexts: [:composer],
      group: :edit,
      label: "Taller",
      help: "Give the composer one more row",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_shorter,
      keys: [{:down, [:control]}],
      action: {:composer_height, {:nudge, -1}},
      contexts: [:composer],
      group: :edit,
      label: "Shorter",
      help: "Take one row back from the composer",
      hint: 0,
      repeat: true
    },

    # ------------------------------------------------------------------
    # Composer, vim keymap: NORMAL and VISUAL. INSERT is the plain composer.
    # The specials read state.vim (pending operator, count) so that "d" then
    # "w" is one binding each and still one action per key.
    # ------------------------------------------------------------------
    %Binding{
      id: :vim_left,
      keys: [{"h", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Left",
      help: "Left one character",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_down,
      keys: [{"j", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Down",
      help: "Down one line",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_up,
      keys: [{"k", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Up",
      help: "Up one line",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_right,
      keys: [{"l", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Right",
      help: "Right one character",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_word_next,
      keys: [{"w", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Next word",
      help: "Forward to the start of the next word",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_word_previous,
      keys: [{"b", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Prev word",
      help: "Back to the start of the previous word",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_word_end,
      keys: [{"e", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Word end",
      help: "Forward to the end of the word",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_line_start,
      keys: [{"0", []}],
      action: {:special, :vim_digit},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Line start",
      help: "Start of the line; after a count, one more digit",
      hint: 0
    },
    %Binding{
      id: :vim_first_nonblank,
      keys: [{"^", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "First char",
      help: "First non-blank character of the line",
      hint: 0
    },
    %Binding{
      id: :vim_line_end,
      keys: [{"$", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Line end",
      help: "End of the line",
      hint: 0
    },
    %Binding{
      id: :vim_buffer_end,
      keys: [{"G", []}],
      action: {:special, :vim_motion},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Bottom",
      help: "End of the draft",
      hint: 0
    },
    %Binding{
      id: :vim_goto,
      keys: [{"g", []}],
      action: {:special, :vim_prefix},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "g g top",
      help: "g g: start of the draft",
      hint: 0
    },
    %Binding{
      id: :vim_count,
      keys: [
        {"1", []},
        {"2", []},
        {"3", []},
        {"4", []},
        {"5", []},
        {"6", []},
        {"7", []},
        {"8", []},
        {"9", []}
      ],
      action: {:special, :vim_digit},
      contexts: [:composer_normal, :composer_visual],
      group: :vim,
      label: "Count",
      help: "Repeat the next motion or operator that many times",
      hint: 0
    },
    %Binding{
      id: :vim_delete,
      keys: [{"d", []}],
      action: {:special, :vim_operator},
      contexts: [:composer_normal],
      group: :vim,
      label: "Delete",
      help: "Delete with a motion; d d deletes the line",
      hint: 3
    },
    %Binding{
      id: :vim_change,
      keys: [{"c", []}],
      action: {:special, :vim_operator},
      contexts: [:composer_normal],
      group: :vim,
      label: "Change",
      help: "Delete with a motion, then INSERT; c c the line",
      hint: 2
    },
    %Binding{
      id: :vim_yank,
      keys: [{"y", []}],
      action: {:special, :vim_operator},
      contexts: [:composer_normal],
      group: :vim,
      label: "Yank",
      help: "Copy with a motion; y y copies the line",
      hint: 1
    },
    %Binding{
      id: :vim_delete_char,
      keys: [{"x", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Del char",
      help: "Delete the character under the caret",
      hint: 1,
      repeat: true
    },
    %Binding{
      id: :vim_delete_char_back,
      keys: [{"X", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Del back",
      help: "Delete the character before the caret",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_delete_to_end,
      keys: [{"D", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Del to end",
      help: "Delete to the end of the line",
      hint: 0
    },
    %Binding{
      id: :vim_change_to_end,
      keys: [{"C", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Change end",
      help: "Delete to the end of the line, then INSERT",
      hint: 0
    },
    %Binding{
      id: :vim_yank_line,
      keys: [{"Y", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Yank line",
      help: "Copy the line",
      hint: 0
    },
    %Binding{
      id: :vim_substitute,
      keys: [{"s", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Substitute",
      help: "Delete the character under the caret, then INSERT",
      hint: 0
    },
    %Binding{
      id: :vim_substitute_line,
      keys: [{"S", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Subst line",
      help: "Clear the line, then INSERT",
      hint: 0
    },
    %Binding{
      id: :vim_put_after,
      keys: [{"p", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Put",
      help: "Put the last deleted or yanked text after the caret",
      hint: 2,
      repeat: true
    },
    %Binding{
      id: :vim_put_before,
      keys: [{"P", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Put before",
      help: "Put the last deleted or yanked text before the caret",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :vim_undo,
      keys: [{"u", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Undo",
      help: "Undo the last edit",
      hint: 2,
      repeat: true
    },
    %Binding{
      id: :vim_redo,
      keys: [{"r", [:control]}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Redo",
      help: "Redo (Ctrl-R is the run palette outside NORMAL)",
      hint: 1,
      repeat: true
    },
    %Binding{
      id: :vim_insert,
      keys: [{"i", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Insert",
      help: "INSERT at the caret",
      hint: 6
    },
    %Binding{
      id: :vim_append,
      keys: [{"a", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Append",
      help: "INSERT after the caret",
      hint: 0
    },
    %Binding{
      id: :vim_insert_line_start,
      keys: [{"I", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Insert start",
      help: "INSERT at the first non-blank of the line",
      hint: 0
    },
    %Binding{
      id: :vim_append_line_end,
      keys: [{"A", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Append end",
      help: "INSERT at the end of the line",
      hint: 1
    },
    %Binding{
      id: :vim_open_below,
      keys: [{"o", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Open below",
      help: "New line below, then INSERT",
      hint: 1
    },
    %Binding{
      id: :vim_open_above,
      keys: [{"O", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Open above",
      help: "New line above, then INSERT",
      hint: 0
    },
    %Binding{
      id: :vim_visual,
      keys: [{"v", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Visual",
      help: "VISUAL: motions select, then d, y or c act on it",
      hint: 3
    },
    %Binding{
      id: :vim_visual_line,
      keys: [{"V", []}],
      action: {:special, :vim_command},
      contexts: [:composer_normal],
      group: :vim,
      label: "Visual line",
      help: "VISUAL with the whole line selected",
      hint: 0
    },
    %Binding{
      id: :vim_visual_delete,
      keys: [{"d", []}, {"x", []}],
      action: {:special, :vim_visual_command},
      contexts: [:composer_visual],
      group: :vim,
      label: "Delete",
      help: "Delete the selection",
      hint: 3
    },
    %Binding{
      id: :vim_visual_yank,
      keys: [{"y", []}],
      action: {:special, :vim_visual_command},
      contexts: [:composer_visual],
      group: :vim,
      label: "Yank",
      help: "Copy the selection",
      hint: 2
    },
    %Binding{
      id: :vim_visual_change,
      keys: [{"c", []}],
      action: {:special, :vim_visual_command},
      contexts: [:composer_visual],
      group: :vim,
      label: "Change",
      help: "Delete the selection, then INSERT",
      hint: 1
    },

    # ------------------------------------------------------------------
    # Layout accelerators (Alt chords only; each pane also has a dock toggle)
    # ------------------------------------------------------------------
    %Binding{
      id: :layout_narrower,
      keys: [
        {"H", [:alt]},
        {"h", [:alt]},
        {"H", [:alt, :shift]},
        {"h", [:alt, :shift]},
        {"H", [:alt, :control]},
        {"h", [:alt, :control]},
        {"H", [:alt, :control, :shift]},
        {"h", [:alt, :control, :shift]}
      ],
      action: {:special, :layout_narrower},
      contexts: [:global],
      group: :layers,
      label: "Narrower",
      help: "Narrow the inspector dock (add Ctrl for a bigger step)",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :layout_wider,
      keys: [
        {"L", [:alt]},
        {"l", [:alt]},
        {"L", [:alt, :shift]},
        {"l", [:alt, :shift]},
        {"L", [:alt, :control]},
        {"l", [:alt, :control]},
        {"L", [:alt, :control, :shift]},
        {"l", [:alt, :control, :shift]}
      ],
      action: {:special, :layout_wider},
      contexts: [:global],
      group: :layers,
      label: "Wider",
      help: "Widen the inspector dock (add Ctrl for a bigger step)",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :layout_reset,
      keys: [
        {"0", [:alt]},
        {"0", [:alt, :shift]},
        {"0", [:alt, :control]},
        {"0", [:alt, :control, :shift]}
      ],
      action: {:special, :layout_reset},
      contexts: [:global],
      group: :layers,
      label: "Reset size",
      help: "Reset the inspector dock to its default width",
      hint: 0
    }
  ]

  # The go-to popup is a which-key list, not a searchable picker: these are its
  # rows, and the reducer's focus graph, the dialog projector and Enter all read
  # the same four from here.
  @jump_rows [
    {"jump_top", :jump_top, {:move, :first}},
    {"jump_bottom", :jump_bottom, {:move, :last}},
    {"jump_next_run", :jump_next_run, {:run_tab, :next}},
    {"jump_previous_run", :jump_previous_run, {:run_tab, :previous}}
  ]

  @table Enum.reduce(@bindings, %{}, fn binding, table ->
           Enum.reduce(binding.keys, table, fn {code, mods} = key, table ->
             typing? = is_binary(code) and mods == []

             contexts =
               Enum.flat_map(binding.contexts, fn
                 :global when typing? -> @contexts -- @typing_contexts
                 :global -> @contexts
                 context -> [context]
               end)

             Enum.reduce(contexts, table, &Map.put(&2, {&1, key}, binding))
           end)
         end)

  @doc "Every context `Context.of/1` can return."
  @spec contexts() :: [atom()]
  def contexts, do: @contexts

  @doc "The contexts where a bare printable key is typing rather than a binding."
  @spec typing_contexts() :: [atom()]
  def typing_contexts, do: @typing_contexts

  @doc "The help sheet's groups, in the order it renders them."
  @spec groups() :: [atom()]
  def groups, do: @groups

  @doc "The inspector's tabs in `[` / `]` order."
  @spec inspector_tabs() :: [atom()]
  def inspector_tabs, do: @inspector_tabs

  @doc "Every binding, in table order."
  @spec all() :: [Binding.t()]
  def all, do: @bindings

  @doc "The flattened `{context, key} => binding` map the resolver looks up."
  @spec table() :: %{{atom(), Binding.key()} => Binding.t()}
  def table, do: @table

  @doc "The binding bound to `code`/`mods` in `context`, or `nil`."
  @spec lookup(atom(), term(), [atom()]) :: Binding.t() | nil
  def lookup(context, code, mods), do: Map.get(@table, {context, {code, mods}})

  @doc "Every binding reachable in `context`, in table order."
  @spec for_context(atom()) :: [Binding.t()]
  def for_context(context) do
    bound =
      @table
      |> Enum.filter(fn {{entry_context, _}, _} -> entry_context == context end)
      |> MapSet.new(fn {_, binding} -> binding.id end)

    Enum.filter(@bindings, &MapSet.member?(bound, &1.id))
  end

  @doc """
  How strongly `binding` wants a place in the status bar in `context`.

  `hint` is one integer for every context, or a keyword list per context where
  a binding matters in some places and not others (`Esc` in main has nothing
  to step out of). A context the list does not name is 0: never hinted.
  """
  @spec hint(Binding.t(), atom()) :: non_neg_integer()
  def hint(%Binding{hint: hint}, _context) when is_integer(hint), do: hint
  def hint(%Binding{hint: hints}, context) when is_list(hints), do: Keyword.get(hints, context, 0)

  @doc "The bindings the status bar may hint in `context`, strongest first, ties by id."
  @spec hinted(atom()) :: [Binding.t()]
  def hinted(context) do
    context
    |> for_context()
    |> Enum.map(&{&1, hint(&1, context)})
    |> Enum.filter(fn {_binding, hint} -> hint > 0 end)
    |> Enum.sort_by(fn {binding, hint} -> {-hint, binding.id} end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc """
  The first of `binding`'s keys that reaches it in `context`, or `nil`.

  A global binding can have a key that is typing in one context and a chord
  that is not (`?` and `F1` for help), so the key a surface prints for a
  context has to be one the resolver would actually route there.
  """
  @spec key_in_context(Binding.t(), atom()) :: Binding.key() | nil
  def key_in_context(%Binding{} = binding, context),
    do: Enum.find(binding.keys, fn {code, mods} -> lookup(context, code, mods) == binding end)

  @doc "Every one of `binding`'s keys that reaches it in `context`, in table order."
  @spec keys_in_context(Binding.t(), atom()) :: [Binding.key()]
  def keys_in_context(%Binding{} = binding, context),
    do: Enum.filter(binding.keys, fn {code, mods} -> lookup(context, code, mods) == binding end)

  @doc "The keys `id` is bound to, or `[]` when there is no such binding."
  @spec keys_for(atom()) :: [Binding.key()]
  def keys_for(id) do
    case Enum.find(@bindings, &(&1.id == id)) do
      nil -> []
      binding -> binding.keys
    end
  end

  @doc "The binding whose `id` matches, or `nil`."
  @spec fetch(atom()) :: Binding.t() | nil
  def fetch(id), do: Enum.find(@bindings, &(&1.id == id))

  @doc """
  The go-to popup's rows as `{focus_id, chrome_token, action}`.

  Exposed so `Reducer.focus_graph/1`, `Projector.Dialog` and Enter all agree on
  one list rather than three copies of it.
  """
  @spec jump_rows() :: [{binary(), atom(), term()}]
  def jump_rows, do: @jump_rows
end
