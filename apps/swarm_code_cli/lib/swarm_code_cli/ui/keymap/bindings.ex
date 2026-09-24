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
    :dialog,
    :overlay,
    :hint
  ]

  # The contexts where a bare printable key is the user typing, not a binding.
  # The agent overlay has a composer of its own (pass 72).
  @typing_contexts [:composer, :field, :picker, :overlay]

  # The groups the help sheet renders, in the order it renders them. Vim first:
  # it only appears in the NORMAL and VISUAL sheets, where it is the point.
  @groups [:vim, :navigate, :focus, :runs, :act, :layers, :edit, :session]

  @inspector_tabs [:agents, :timeline, :changes]

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
      # Ctrl-P, the palette key of most editors. Ctrl-K was taken by the
      # user's workspace switcher, and a chord the terminal never delivers is
      # no chord at all.
      keys: [{"p", [:control]}],
      action: {:special, :command_palette},
      contexts: [:global],
      group: :layers,
      label: "Palette",
      help: "Command palette; pressed again it keeps the palette and its query",
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
    # pass72 (K6): the side panel cycles full -> compact -> hidden; under 120
    # columns, where the panel is a one-row strip, strip -> off. The choice is
    # remembered in the CLI preferences file.
    %Binding{
      id: :toggle_inspector,
      keys: [{"b", [:control]}, {"i", [:alt]}],
      action: {:panel_mode, :cycle},
      contexts: [:global],
      group: :layers,
      label: "Panel",
      help: "Side panel: full, compact, hidden (strip or off under 120 columns)",
      hint: 2
    },
    # pass72 (P7, K1): hint mode badges every agent and run in the side panel.
    # Ctrl-F is no longer the composer's Emacs forward-char (the Right arrow
    # moves the caret); Ctrl-Space arrives as NUL where the terminal sends it.
    %Binding{
      id: :hint_mode,
      keys: [{"f", [:control]}, {" ", [:control]}],
      action: {:hint, :open},
      # :dialog only over a request card (the reducer ignores it elsewhere).
      contexts: [
        :composer,
        :composer_normal,
        :composer_visual,
        :main,
        :inspector,
        :overlay,
        :dialog
      ],
      group: :runs,
      label: "Hints",
      help:
        "Hint mode: a letter opens an agent, a digit a run (not forward-char: Right moves the caret)",
      hint: [composer: 6, main: 5, inspector: 5, overlay: 3]
    },
    %Binding{
      id: :hint_again,
      keys: [{"f", [:control]}, {" ", [:control]}],
      action: {:hint, :again},
      contexts: [:hint],
      group: :runs,
      label: "Needs you",
      help: "Pressed again: the next request waiting on you (as Ctrl-N)",
      hint: [hint: 3]
    },
    %Binding{
      id: :hint_pick,
      keys: Enum.map(~w(s f g h j k l w e r t u i o p), &{&1, []}),
      action: {:special, :hint_key},
      contexts: [:hint],
      group: :runs,
      label: "Open",
      help: "Open the agent with this badge in the overlay (two letters past 15 agents)",
      hint: [hint: 5]
    },
    %Binding{
      id: :hint_run,
      keys: Enum.map(~w(1 2 3 4 5 6 7 8 9), &{&1, []}),
      action: {:special, :hint_key},
      contexts: [:hint],
      group: :runs,
      label: "Run",
      help: "Show the run with this number in the chat",
      hint: [hint: 4]
    },
    %Binding{
      id: :hint_runs_dashboard,
      keys: [{"0", []}],
      action: {:special, :hint_key},
      contexts: [:hint],
      group: :runs,
      label: "All runs",
      help: "The runs dashboard (as Ctrl-G)",
      hint: 0
    },
    %Binding{
      id: :hint_cancel,
      keys: [{:escape, []}],
      action: {:hint, :cancel},
      contexts: [:hint],
      group: :session,
      label: "Cancel",
      help: "Leave hint mode; hint keys never answer a request",
      hint: [hint: 2]
    },
    %Binding{
      id: :hint_backspace,
      keys: [{:backspace, []}],
      action: {:hint, :backspace},
      contexts: [:hint],
      group: :session,
      label: "Undo letter",
      help: "Take back the first letter of a two-letter badge",
      hint: 0
    },
    # pass72 (P8, K5): the agent overlay, a full-screen view of one agent.
    %Binding{
      id: :overlay_close,
      keys: [{:escape, []}],
      action: {:overlay, :close},
      contexts: [:overlay],
      group: :session,
      label: "Back",
      help: "Back to the chat, at the same scroll and with the same draft",
      hint: [overlay: 9]
    },
    %Binding{
      id: :overlay_focus_next,
      keys: [{:tab, []}],
      action: {:overlay, {:focus, :next}},
      contexts: [:overlay],
      group: :focus,
      label: "Focus",
      help: "Focus the band, the activity, the composer (and the pages under 120 columns)",
      hint: [overlay: 6],
      repeat: true
    },
    %Binding{
      id: :overlay_focus_previous,
      keys: [{:tab, [:shift]}, {:back_tab, []}],
      action: {:overlay, {:focus, :previous}},
      contexts: [:overlay],
      group: :focus,
      label: "Focus back",
      help: "Move the overlay's focus back",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :overlay_next_agent,
      keys: [{"]", []}],
      action: {:special, :overlay_letter},
      contexts: [:overlay],
      group: :navigate,
      label: "Next agent",
      help: "The next agent in panel order, wrapping (types while the composer has text)",
      hint: [overlay: 8],
      repeat: true
    },
    %Binding{
      id: :overlay_previous_agent,
      keys: [{"[", []}],
      action: {:special, :overlay_letter},
      contexts: [:overlay],
      group: :navigate,
      label: "Prev agent",
      help: "The previous agent in panel order, wrapping",
      hint: [overlay: 7],
      repeat: true
    },
    %Binding{
      id: :overlay_raw_ops,
      keys: [{"o", []}],
      action: {:special, :overlay_letter},
      contexts: [:overlay],
      group: :act,
      label: "Operations",
      help: "Show every raw operation instead of the grouped activity, and back",
      hint: [overlay: 5]
    },
    %Binding{
      id: :overlay_stop_agent,
      keys: [{"x", []}],
      action: {:special, :overlay_letter},
      contexts: [:overlay],
      group: :act,
      label: "Stop agent",
      help:
        "Stop the agent the overlay shows (asks to confirm); only while the composer is empty",
      hint: 0
    },
    %Binding{
      id: :overlay_answer,
      keys: Enum.map(~w(y a Y A d D n), &{&1, []}),
      action: {:special, :overlay_letter},
      contexts: [:overlay],
      group: :act,
      label: "Answer",
      help:
        "y/a once, Y this run, A always the family, d deny, D deny + stop, n next; only while the composer is empty",
      hint: [overlay: 4]
    },
    %Binding{
      id: :overlay_activate,
      keys: [{:enter, []}],
      action: {:overlay, :activate},
      contexts: [:overlay],
      group: :act,
      label: "Steer",
      help:
        "In the composer, steer only this agent; on a group, expand it; on the band, the card",
      hint: [overlay: 10]
    },
    %Binding{
      id: :overlay_move_down,
      keys: [{:down, []}],
      action: {:overlay, {:move, :down}},
      contexts: [:overlay],
      group: :navigate,
      label: "Down",
      help: "Next group of the activity",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :overlay_move_up,
      keys: [{:up, []}],
      action: {:overlay, {:move, :up}},
      contexts: [:overlay],
      group: :navigate,
      label: "Up",
      help: "Previous group of the activity",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :overlay_page_down,
      keys: [{:page_down, []}],
      action: {:overlay, {:move, :page_down}},
      contexts: [:overlay],
      group: :navigate,
      label: "Page down",
      help: "Scroll the activity a page down",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :overlay_page_up,
      keys: [{:page_up, []}],
      action: {:overlay, {:move, :page_up}},
      contexts: [:overlay],
      group: :navigate,
      label: "Page up",
      help: "Scroll the activity a page up",
      hint: 0,
      repeat: true
    },
    # Ctrl-C never ends the session by itself: it closes a layer, else clears
    # the draft, else stops the turn in view (or the one Enter just sent), and
    # such a press never arms the quit. Only two presses within 1.5 s that
    # have nothing else to do quit (asking first when runs are still live).
    %Binding{
      id: :interrupt,
      keys: [{"c", [:control]}],
      action: {:special, :interrupt},
      contexts: [:global],
      group: :session,
      label: "Interrupt",
      help: "Clear the draft, else stop the turn; twice with nothing to stop quits",
      hint: [composer: 2]
    },
    %Binding{
      id: :close_or_quit,
      keys: [{"q", []}],
      action: {:special, :close_or_quit},
      contexts: [:main, :inspector, :dialog, :picker],
      group: :session,
      label: "Close/Quit",
      help: "Close the top layer; in select mode with none open, quit",
      hint: [main: 4, inspector: 4, dialog: 4]
    },
    # Esc never moves focus out of the composer: there it stops a streaming
    # turn. Everywhere else it steps out one level: a layer closes, a vim
    # mode ends, select mode hands back to the composer.
    %Binding{
      id: :escape,
      keys: [{:escape, []}],
      action: {:special, :escape},
      contexts: [:composer_normal, :composer_visual, :main, :inspector, :picker, :field, :dialog],
      group: :session,
      label: "Back out",
      help: "Close the top layer, end a vim mode, or leave select mode",
      hint: [composer_normal: 7, composer_visual: 8, dialog: 6, picker: 5, main: 6, inspector: 6]
    },
    %Binding{
      id: :interrupt_turn,
      keys: [{:escape, []}],
      action: {:special, :escape},
      contexts: [:composer],
      group: :session,
      label: "Interrupt",
      help: "Stop the turn that is streaming; the draft stays",
      hint: [composer: 8]
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
      id: :complete,
      keys: [{:tab, []}],
      action: {:special, :focus_next},
      contexts: [:composer],
      group: :edit,
      label: "Complete",
      help: "Complete a slash command; while a turn runs, queue the draft behind it",
      hint: [composer: 5],
      repeat: true
    },
    %Binding{
      id: :focus_next,
      keys: [{:tab, []}],
      action: {:special, :focus_next},
      contexts: [:composer_normal, :composer_visual, :main, :inspector, :picker, :field, :dialog],
      group: :focus,
      label: "Next",
      help: "Move focus on; from select mode, back into the composer",
      hint: [main: 2, inspector: 2, dialog: 1],
      repeat: true
    },
    %Binding{
      id: :focus_previous,
      keys: [{:tab, [:shift]}, {:back_tab, []}],
      action: {:focus_cycle, :previous},
      contexts: [:main, :inspector, :picker, :field, :dialog],
      group: :focus,
      label: "Previous",
      help: "Move focus back",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :select_mode,
      keys: [{"t", [:control]}],
      action: {:special, :select_mode},
      contexts: [:composer, :composer_normal, :composer_visual, :main, :inspector],
      group: :focus,
      label: "Select",
      help: "Select mode: j/k move, Enter open, y copy, Esc back to typing",
      hint: [composer: 3, composer_normal: 1, main: 7, inspector: 5]
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
      id: :copy_selected,
      keys: [{"y", []}],
      action: {:special, :copy_selected},
      contexts: [:main, :inspector],
      group: :act,
      label: "Copy",
      help: "Copy the selected item's text to the clipboard",
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
      contexts: [:main, :inspector, :composer, :composer_normal, :composer_visual],
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
      contexts: [:main, :inspector, :composer, :composer_normal, :composer_visual],
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
      help: "Activate what is focused; on an approval card that cuts its command, show all of it",
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
      help: "Send the draft (in every vim mode); while loading, it sends once ready",
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
    # pass73 T5: a message that names a workflow is sent as /create-workflow;
    # this key sends that one message as it is. Ctrl-S is free everywhere
    # (raw mode turns flow control off, so the terminal passes it through).
    %Binding{
      id: :send_plain,
      keys: [{"s", [:control]}],
      action: :send_plain,
      contexts: [:composer, :composer_normal, :composer_visual],
      group: :act,
      label: "Plain",
      help: "Send a message that names a workflow as a plain message, not as /create-workflow",
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
      # No Ctrl-P alias: that chord is the palette everywhere, pickers included.
      keys: [{:up, []}],
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
      id: :next_need,
      keys: [{"n", []}],
      action: {:special, :next_need},
      contexts: [:main, :inspector],
      group: :act,
      label: "Next waiting",
      help: "Open the next approval or question waiting on you, across every run",
      hint: 1
    },
    # The composer's way to the next approval or question: a chord, because a
    # bare "n" there is typing.
    %Binding{
      id: :next_need_chord,
      keys: [{"n", [:control]}],
      action: {:special, :next_need},
      contexts: [:composer, :composer_normal, :composer_visual, :overlay],
      group: :act,
      label: "Waiting",
      help: "Open the next approval or question waiting on you",
      hint: [composer: 4, composer_normal: 3]
    },
    %Binding{
      id: :previous_need,
      keys: [{"N", []}],
      action: {:special, :previous_need},
      contexts: [:main, :inspector],
      group: :act,
      label: "Prev waiting",
      help: "Open the previous approval or question waiting on you",
      hint: 0
    },
    # An approval reads y once · Y this run · A always "<family>" · d deny ·
    # D deny & stop · n next. On a yes/no confirmation "y" and "n" are yes and
    # no; the same two keys, one special each.
    %Binding{
      id: :confirm_yes,
      keys: [{"y", []}],
      action: {:special, :confirm_yes},
      contexts: [:dialog],
      group: :act,
      label: "Yes",
      help: "Confirm: yes; on an approval, allow it once",
      hint: 3
    },
    # The older spelling of "allow once", kept so a card that still names
    # :approve keeps its key.
    %Binding{
      id: :approve,
      keys: [{"a", []}],
      action: {:special, :approve},
      contexts: [:dialog],
      group: :act,
      label: "Approve",
      help: "Allow the pending request once (same as y)",
      hint: 0
    },
    %Binding{
      id: :approve_run,
      keys: [{"Y", []}],
      action: {:special, :approve_run},
      contexts: [:dialog],
      group: :act,
      label: "This run",
      help: "Allow it for the rest of this run",
      hint: 2
    },
    %Binding{
      id: :always_allow,
      keys: [{"A", []}],
      action: {:special, :always_allow},
      contexts: [:dialog],
      group: :act,
      label: "Always",
      help: "Always allow commands of this family in the project",
      hint: 1
    },
    %Binding{
      id: :deny,
      keys: [{"d", []}],
      action: {:special, :deny},
      contexts: [:dialog],
      group: :act,
      label: "Deny",
      help: "Deny the pending request; the run goes on without it",
      hint: 2
    },
    %Binding{
      id: :deny_stop,
      keys: [{"D", []}],
      action: {:special, :deny_stop},
      contexts: [:dialog],
      group: :act,
      label: "Deny, stop",
      help: "Deny the pending request and stop the run",
      hint: 1
    },
    %Binding{
      id: :confirm_no,
      keys: [{"n", []}],
      action: {:special, :confirm_no},
      contexts: [:dialog],
      group: :act,
      label: "No",
      help: "Confirm: no; on an approval or question, the next one waiting",
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
      keys: [{"o", [:control]}, {"j", [:control]}, {:enter, [:shift]}],
      action: {:special, :composer_newline},
      contexts: [:composer, :field, :overlay],
      group: :edit,
      label: "Newline",
      help: "Insert a line break without sending (Ctrl-O or Ctrl-J)",
      hint: 7
    },
    %Binding{
      id: :external_editor,
      keys: [{"x", [:control]}],
      action: {:special, :external_editor},
      contexts: [:composer, :composer_normal, :overlay],
      group: :edit,
      label: "Editor",
      help: "Edit the draft in $VISUAL or $EDITOR; saving and quitting brings it back"
    },
    %Binding{
      id: :composer_up,
      keys: [{:up, []}],
      action: {:special, :composer_up},
      contexts: [:composer],
      group: :edit,
      label: "Up",
      help: "Up a line; on an empty draft, the previous prompt; up the slash list",
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
      help: "Down a line; back towards the draft in prompt history; down the slash list",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_line_start,
      keys: [{"a", [:control]}],
      action: {:editor_op, {:move, :line_start}},
      contexts: [:composer, :field, :overlay],
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
      contexts: [:composer, :field, :overlay],
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
      contexts: [:composer, :field, :overlay],
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
      contexts: [:field],
      group: :edit,
      label: "Del to start",
      help: "Delete back to the start of the line",
      hint: 0,
      repeat: true
    },
    # Readline's Ctrl-U in the composer, except that on an empty draft (where
    # it would delete nothing) it and Ctrl-D scroll the transcript half a page.
    %Binding{
      id: :composer_half_up,
      keys: [{"u", [:control]}],
      action: {:special, :composer_half_up},
      contexts: [:composer],
      group: :edit,
      label: "Del to start",
      help: "Delete back to the start of the line; on an empty draft, scroll up",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_half_down,
      keys: [{"d", [:control]}],
      action: {:special, :composer_half_down},
      contexts: [:composer],
      group: :navigate,
      label: "Half down",
      help: "On an empty draft, scroll the transcript half a page down",
      hint: 0,
      repeat: true
    },
    %Binding{
      id: :composer_undo,
      keys: [{"z", [:control]}],
      action: {:editor_op, :undo},
      contexts: [:composer, :field, :overlay],
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
      contexts: [:composer, :field, :overlay],
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
