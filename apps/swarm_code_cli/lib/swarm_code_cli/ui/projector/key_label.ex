defmodule SwarmCodeCLI.UI.Projector.KeyLabel do
  @moduledoc """
  How one `{code, mods}` key from the binding table is spelled on screen.

  One formatter for the three surfaces that print keys — the status hints, the
  `?` sheet and `mix swarm_code.keymap` — so a rebind can never leave two of
  them disagreeing. It is pure text: a key label is *data* derived from the
  table, not chrome, so it goes through `Density.safe/3` at the call site like
  every other external string.

  Two display rules that are not obvious from the table:

    * A modified letter chord is case-insensitive at the terminal, and the
      table binds both cases (and the `:shift` permutations) so a real keyboard
      cannot miss. `Ctrl-k`, `Alt-h`, `Alt-Shift-H` therefore all *print* as
      `Ctrl-K` / `Alt-H`, and `labels/2` dedupes them, which is what keeps
      `:layout_narrower`'s eight keys from printing as eight alternatives.
    * A bare fragment keeps its case, because there `g` and `G` are different
      bindings.

  Arrows are the ambiguous-width block, so they are *not* `Support.glyph/2`
  chrome (that catalogue is one cell under both width policies, and `↑` is two
  under `:wide`). Callers measure with `Width.cells/2` under the state's own
  policy instead; `ascii?` swaps in the word forms for a terminal that cannot
  draw them at all.
  """

  alias SwarmCodeCLI.UI.Keymap.Binding

  # Printed in this order: Ctrl before Alt before Shift, as every key reference
  # in the wild spells it.
  @mod_order [:control, :alt, :shift]
  @mod_labels %{control: "Ctrl-", alt: "Alt-", shift: "Shift-"}

  @arrows %{
    up: {"↑", "Up"},
    down: {"↓", "Down"},
    left: {"←", "Left"},
    right: {"→", "Right"}
  }

  @doc """
  One key as text. `key` is a `{code, mods}` pair, or a list of them for a
  sequence (`[{"g", []}, {"t", []}]` prints as `g t`).
  """
  @spec label(Binding.key() | [Binding.key()], boolean()) :: binary()
  def label(key, ascii? \\ false)

  def label(keys, ascii?) when is_list(keys),
    do: Enum.map_join(keys, " ", &label(&1, ascii?))

  def label({code, mods}, ascii?) when is_list(mods) do
    {code, mods} = normalize(code, mods)
    modifiers(mods) <> code_label(code, ascii?)
  end

  @doc """
  Every distinct spelling of `binding`'s keys, in table order.

  Alternatives that print the same (the case and `:shift` permutations of a
  modified chord) collapse to one entry.
  """
  @spec labels(Binding.t() | [Binding.key()], boolean()) :: [binary()]
  def labels(binding, ascii? \\ false)

  def labels(%Binding{keys: keys}, ascii?), do: labels(keys, ascii?)

  def labels(keys, ascii?) when is_list(keys),
    do: keys |> Enum.map(&label(&1, ascii?)) |> Enum.uniq()

  @doc """
  The keys of `binding` joined for a help row or a doc table: `Ctrl-B / Alt-I`.
  """
  @spec joined(Binding.t() | [Binding.key()], boolean()) :: binary()
  def joined(binding, ascii? \\ false),
    do: binding |> labels(ascii?) |> collapse_digits() |> Enum.join(" / ")

  # "1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9" is a key column nobody can read; three
  # or more consecutive single digits print as the range they are.
  defp collapse_digits(labels) do
    labels
    |> Enum.chunk_by(&digit?/1)
    |> Enum.flat_map(fn
      [first | _] = run when length(run) >= 3 ->
        if digit?(first), do: [first <> "-" <> List.last(run)], else: run

      run ->
        run
    end)
  end

  defp digit?(label), do: label =~ ~r/^[0-9]$/

  @doc """
  The one key a one-line surface shows for `binding`: the first in table order,
  which is the primary spelling.
  """
  @spec primary(Binding.t() | [Binding.key()], boolean()) :: binary()
  def primary(binding, ascii? \\ false) do
    case labels(binding, ascii?) do
      [] -> ""
      [first | _] -> first
    end
  end

  # A letter under Ctrl or Alt prints as the uppercase letter, which is how key
  # references name it. An uppercase letter that also carries `:shift` already
  # says Shift in its case, so the modifier is dropped; a lowercase letter with
  # `:shift` is a real chord (`Ctrl-Shift-Z` is redo, `Ctrl-Z` is undo) and
  # keeps it.
  defp normalize(code, mods) when is_binary(code) do
    cond do
      not (command_chord?(mods) and String.length(code) == 1) ->
        {code, mods}

      :shift in mods and code == String.upcase(code) and code != String.downcase(code) ->
        {code, mods -- [:shift]}

      true ->
        {String.upcase(code), mods}
    end
  end

  defp normalize(code, mods), do: {code, mods}

  defp command_chord?(mods), do: :control in mods or :alt in mods

  defp modifiers(mods),
    do:
      Enum.map_join(@mod_order, "", fn mod -> if mod in mods, do: @mod_labels[mod], else: "" end)

  defp code_label(:enter, _ascii?), do: "Enter"
  defp code_label(:escape, _ascii?), do: "Esc"
  defp code_label(:tab, _ascii?), do: "Tab"
  # Shift-Tab arrives as its own code, and reads as the chord the user pressed.
  defp code_label(:back_tab, _ascii?), do: "Shift-Tab"
  defp code_label(:backspace, _ascii?), do: "Backspace"
  defp code_label(:page_up, _ascii?), do: "PgUp"
  defp code_label(:page_down, _ascii?), do: "PgDn"
  defp code_label(:home, _ascii?), do: "Home"
  defp code_label(:end, _ascii?), do: "End"
  defp code_label(:delete, _ascii?), do: "Del"
  defp code_label(:insert, _ascii?), do: "Ins"
  defp code_label({:function, n}, _ascii?) when is_integer(n), do: "F" <> Integer.to_string(n)
  defp code_label(" ", _ascii?), do: "Space"

  defp code_label(code, ascii?) when is_map_key(@arrows, code) do
    {unicode, word} = @arrows[code]
    if ascii?, do: word, else: unicode
  end

  defp code_label(code, _ascii?) when is_binary(code), do: code

  # A special code the table grows later still prints as something readable
  # rather than raising in the middle of a paint.
  defp code_label(code, _ascii?) when is_atom(code),
    do: code |> Atom.to_string() |> String.split("_") |> Enum.map_join(" ", &String.capitalize/1)
end
