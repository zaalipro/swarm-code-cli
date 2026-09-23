defmodule SwarmCodeCLI.UI.Keymap.Vim do
  @moduledoc """
  The composer's vim grammar: the specials behind the `:composer_normal` and
  `:composer_visual` rows of the binding table.

  This module is pure. It reads `state.vim` (mode, pending operator, count) and
  the draft's editor, and returns one action per keystroke. The reducer owns
  the state: an operator that needs a second key is stored through
  `{:vim, {:pending, "d"}}`, a count through `{:vim, {:count, n}}`, and a key
  that edits *and* changes mode goes out as one compound
  `{:vim, {:edit_then, operations, mode}}` so the reducer applies both in
  order. A completed editor action clears the pending operator and the count.

  ## The caret model

  Vim's NORMAL cursor sits *on* a character; this editor's caret sits *between*
  graphemes, and every motion here is the editor's own. The visible
  consequences, all deliberate:

    * `$` puts the caret after the last grapheme of the line, where `A` would.
    * `x` at the very end of a line does nothing rather than joining lines;
      `X` at the very start does nothing rather than deleting the newline.
    * `Esc` from INSERT steps the caret one left unless it is already at the
      start of its line, which is what vim does.
    * `e` ends the word the caret is inside, or the next one.

  ## Not in this version

  `.` repeat, `f`/`t`/`;`/`,`, `J`, `~`, `r`, `>`/`<`, named registers, marks
  and macros. `cc` and `S` ignore a count.
  """

  alias SwarmCodeCLI.UI.{Drafts, Editor, Keymap, State, Vim}

  @specials [
    :focus_composer,
    :vim_motion,
    :vim_digit,
    :vim_prefix,
    :vim_operator,
    :vim_command,
    :vim_visual_command
  ]

  @operators ["d", "c", "y"]

  @motions %{
    "h" => :left,
    "l" => :right,
    "j" => :down,
    "k" => :up,
    "^" => :first_nonblank,
    "$" => :line_end,
    "w" => :word_right,
    "b" => :word_left,
    "e" => :word_end,
    "G" => :buffer_end
  }

  @doc "The special names this module resolves."
  @spec specials() :: [atom()]
  def specials, do: @specials

  @doc "True when `name` is one of this module's specials."
  @spec special?(atom()) :: boolean()
  def special?(name), do: name in @specials

  @doc "The operator letters that wait for a motion."
  @spec operators() :: [binary()]
  def operators, do: @operators

  @doc "The keys `Esc` steps through, from the composer, when the vim keymap is on."
  @spec escape(map()) :: {:ok, term()} | :ignore
  def escape(%{vim: %{mode: :visual}}), do: ok({:vim, {:mode, :normal}})

  # A bare NORMAL has no mode left to leave; like the plain composer's Esc it
  # stops a streaming turn and never takes the caret out of the composer.
  def escape(%{vim: %{mode: :normal, pending: nil, count: nil}}),
    do: ok({:interrupt, :escape})

  def escape(%{vim: %{mode: :normal}}), do: ok({:vim, {:pending, nil}})

  def escape(%{vim: %{mode: :insert}} = state) do
    cond do
      Keymap.editor_context(state) == nil -> ok({:vim, {:mode, :normal}})
      line_start?(state) -> ok({:vim, {:mode, :normal}})
      true -> ok({:vim, {:edit_then, [{:move, :left}], :normal}})
    end
  end

  @spec run(atom(), {term(), [atom()]}, map(), map()) :: {:ok, term()} | :ignore
  def run(name, key, state, table)

  # `i` from the transcript: with vim on it is INSERT, which also focuses the
  # composer, so a NORMAL left behind by the last visit cannot survive `i`.
  def run(:focus_composer, _key, %{keymap: :vim}, _table), do: ok({:vim, {:mode, :insert}})
  def run(:focus_composer, _key, _state, _table), do: ok({:focus_region, "composer"})

  # A bare `0` is the line-start motion; after a count digit it extends the
  # count, exactly as vim reads `10j`.
  def run(:vim_digit, {"0", _}, %{vim: %{count: nil}} = state, _table),
    do: motion(state, :line_start)

  def run(:vim_digit, {digit, _}, state, _table) do
    count = min(Vim.max_count(), (state.vim.count || 0) * 10 + String.to_integer(digit))
    ok({:vim, {:count, count}})
  end

  def run(:vim_motion, {code, _}, state, _table), do: motion(state, Map.fetch!(@motions, code))

  # `g` waits for a second `g`; anything else after it cancels the prefix.
  def run(:vim_prefix, {"g", _}, %{vim: %{pending: "g"}} = state, _table),
    do: reach(state, :buffer_start)

  def run(:vim_prefix, {"g", _}, %{vim: %{pending: nil}}, _table), do: pending("g")
  def run(:vim_prefix, _key, _state, _table), do: cancel()

  # `d`, `c`, `y` wait for a motion; doubled they take the whole line.
  def run(:vim_operator, {op, _}, %{vim: %{pending: nil}}, _table) when op in @operators,
    do: pending(op)

  def run(:vim_operator, {"d", _}, %{vim: %{pending: "d"}} = state, _table),
    do: edit(state, times(state, {:delete, :line}))

  def run(:vim_operator, {"y", _}, %{vim: %{pending: "y"}} = state, _table),
    do: edit(state, times(state, {:yank, :line}))

  def run(:vim_operator, {"c", _}, %{vim: %{pending: "c"}} = state, _table),
    do: edit_then(state, [{:move, :line_start}, {:delete, :line_end}], :insert)

  def run(:vim_operator, _key, _state, _table), do: cancel()

  # A command key while an operator is pending is not that operator's motion,
  # so it cancels the prefix instead of doing its own thing on top of it.
  def run(:vim_command, _key, %{vim: %{pending: pending}}, _table) when not is_nil(pending),
    do: cancel()

  def run(:vim_command, {code, mods}, state, _table), do: command(code, mods, state)

  def run(:vim_visual_command, {code, _}, state, _table) do
    case code do
      c when c in ["d", "x"] -> edit_then(state, [{:delete, :selection}], :normal)
      "y" -> edit_then(state, [{:yank, :selection}], :normal)
      "c" -> edit_then(state, [{:delete, :selection}], :insert)
      _ -> :ignore
    end
  end

  def run(_name, _key, _state, _table), do: :ignore

  # ---------------------------------------------------------------- normal

  defp command("i", [], _state), do: ok({:vim, {:mode, :insert}})

  defp command("a", [], state) do
    if line_end?(state),
      do: ok({:vim, {:mode, :insert}}),
      else: edit_then(state, [{:move, :right}], :insert)
  end

  defp command("I", [], state), do: edit_then(state, [{:move, :first_nonblank}], :insert)
  defp command("A", [], state), do: edit_then(state, [{:move, :line_end}], :insert)
  defp command("o", [], state), do: edit_then(state, [{:move, :line_end}, :newline], :insert)

  defp command("O", [], state),
    do: edit_then(state, [{:move, :line_start}, :newline, {:move, :up}], :insert)

  defp command("x", [], state) do
    if line_end?(state), do: :ignore, else: edit(state, times(state, {:delete, :right}))
  end

  defp command("X", [], state) do
    if line_start?(state), do: :ignore, else: edit(state, times(state, {:delete, :left}))
  end

  defp command("D", [], state), do: edit(state, {:delete, :line_end})
  defp command("C", [], state), do: edit_then(state, [{:delete, :line_end}], :insert)
  defp command("Y", [], state), do: edit(state, times(state, {:yank, :line}))

  defp command("s", [], state) do
    if line_end?(state),
      do: ok({:vim, {:mode, :insert}}),
      else: edit_then(state, [times(state, {:delete, :right})], :insert)
  end

  defp command("S", [], state),
    do: edit_then(state, [{:move, :line_start}, {:delete, :line_end}], :insert)

  defp command("p", [], state), do: edit(state, times(state, :put_after))
  defp command("P", [], state), do: edit(state, times(state, :put_before))
  defp command("u", [], state), do: edit(state, times(state, :undo))
  # In NORMAL, Ctrl-R is redo and nothing else: a vim user's hands expect it,
  # and the run palette is one Esc away on every other surface.
  defp command("r", [:control], state), do: edit(state, times(state, :redo))
  defp command("v", [], _state), do: ok({:vim, {:mode, :visual}})

  defp command("V", [], state),
    do: edit_then(state, [{:move, :line_start}, {:extend_selection, :line_end}], :visual)

  defp command(_code, _mods, _state), do: :ignore

  # --------------------------------------------------------------- motions

  # A motion completes a pending operator, extends a VISUAL selection, or just
  # moves; a count multiplies whichever it is.
  defp motion(state, movement) do
    case state.vim do
      %{pending: "d"} -> edit(state, times(state, {:delete, movement}))
      %{pending: "c"} -> edit_then(state, [times(state, {:delete, movement})], :insert)
      %{pending: "y"} -> edit(state, times(state, {:yank, movement}))
      %{pending: pending} when not is_nil(pending) -> cancel()
      _ -> reach(state, movement)
    end
  end

  # A plain move, or in VISUAL an extension of the selection.
  defp reach(%{vim: %{mode: :visual}} = state, movement),
    do: edit(state, times(state, {:extend_selection, movement}))

  defp reach(state, movement), do: edit(state, times(state, {:move, movement}))

  defp times(%{vim: %{count: nil}}, operation), do: operation
  defp times(%{vim: %{count: count}}, operation), do: {:times, count, operation}

  # ------------------------------------------------------------------ guts

  defp edit(state, operation), do: Keymap.edit(state, operation)

  defp edit_then(state, operations, mode) do
    if Keymap.editor_context(state),
      do: ok({:vim, {:edit_then, operations, mode}}),
      else: :ignore
  end

  defp pending(prefix), do: ok({:vim, {:pending, prefix}})
  defp cancel, do: ok({:vim, {:pending, nil}})
  defp ok(action), do: Keymap.result(action)

  # The caret's neighbours in the draft, read off the editor's zipper: the
  # grapheme before it heads `left`, the grapheme after it heads `right`.
  defp line_start?(state) do
    case buffer(state) do
      %{left: []} -> true
      %{left: [before | _]} -> Editor.newline?(before)
      nil -> true
    end
  end

  defp line_end?(state) do
    case buffer(state) do
      %{right: []} -> true
      %{right: [after_ | _]} -> Editor.newline?(after_)
      nil -> true
    end
  end

  defp buffer(state) do
    case State.current_draft_key(state) do
      nil -> nil
      key -> Drafts.fetch(state.drafts, key).editor.buffer
    end
  end
end
