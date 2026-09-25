defmodule SwarmCodeCLI.UI.Keymap.KeyName do
  @moduledoc """
  pass74 (spec §4.4): key names as cli.json stores them and as a user types
  them — `Ctrl-L`, `Alt-Enter`, `Shift-Tab`, `F5`, `PageDown`, `x`, `X`, `?`,
  `Space` — to and from the `{code, mods}` keys of `Keymap.Bindings`.

  `Ctrl-`, `Alt-`, `Shift-` prefixes come in that order; prefixes and named
  keys are case-insensitive, a bare letter is not (`X` is the shifted `x`,
  never `Shift-x`, which parses to `X`). A letter under Ctrl is one key
  whatever its case (the terminal cannot tell them apart).

  Keys the terminal cannot report without the enhanced keyboard protocol (the
  CLI never enables it) parse to `{:error, "this terminal cannot report …"}`:
  `Ctrl-Shift-<letter>`, `Ctrl-Enter`, `Ctrl-Tab`, `Shift-Enter`, and the Ctrl
  letters that arrive as another key (`Ctrl-I` is Tab, `Ctrl-M` Enter,
  `Ctrl-[` Esc).

  Pure; runtime input never becomes an atom (named keys are a closed table).
  """

  alias SwarmCodeCLI.UI.Projector.KeyLabel

  @type key :: {atom() | {:function, 1..12} | binary(), [atom()]}

  @named %{
    "enter" => :enter,
    "return" => :enter,
    "esc" => :escape,
    "escape" => :escape,
    "tab" => :tab,
    "backspace" => :backspace,
    "delete" => :delete,
    "del" => :delete,
    "insert" => :insert,
    "ins" => :insert,
    "space" => " ",
    "up" => :up,
    "↑" => :up,
    "down" => :down,
    "↓" => :down,
    "left" => :left,
    "←" => :left,
    "right" => :right,
    "→" => :right,
    "home" => :home,
    "end" => :end,
    "pageup" => :page_up,
    "pgup" => :page_up,
    "pagedown" => :page_down,
    "pgdn" => :page_down
  }

  @function Map.new(1..12, &{"f#{&1}", {:function, &1}})

  @stored %{
    enter: "Enter",
    escape: "Esc",
    tab: "Tab",
    back_tab: "Shift-Tab",
    backspace: "Backspace",
    delete: "Delete",
    insert: "Insert",
    up: "Up",
    down: "Down",
    left: "Left",
    right: "Right",
    home: "Home",
    end: "End",
    page_up: "PageUp",
    page_down: "PageDown"
  }

  # Ctrl letters a terminal delivers as another key.
  @ctrl_aliases %{"i" => "Tab", "m" => "Enter", "[" => "Esc"}

  @max_bytes 32

  @doc """
  The keys a name stands for (usually one; `Shift-Tab` is both the back-tab
  code and Tab with Shift, as the binding table spells it).
  """
  @spec parse(term()) :: {:ok, [key()]} | {:error, String.t()}
  def parse(name) when is_binary(name) and byte_size(name) in 1..@max_bytes do
    trimmed = String.trim(name)

    with {:ok, mods, rest} <- prefixes(trimmed, []),
         {:ok, code} <- code(rest) do
      build(code, mods, trimmed)
    end
  end

  def parse(_), do: {:error, "not a key name"}

  @doc "Whether `name` parses."
  @spec valid?(term()) :: boolean()
  def valid?(name), do: match?({:ok, _}, parse(name))

  @doc """
  The stored spelling of a key (the parse form, `Ctrl-L`, `PageDown`, `Up`):
  what cli.json holds and `parse/1` reads back to the same key.
  """
  @spec name(key()) :: String.t()
  def name({:back_tab, _mods}), do: "Shift-Tab"

  def name({code, mods}) when is_list(mods) do
    {code, mods} = normalize(code, mods)
    prefix(mods) <> code_name(code)
  end

  @doc """
  A key as the screen prints it: arrows as `↑ ↓ ← →` in the rich and measured
  glyph tiers, words in ascii; everything else as `Projector.KeyLabel` spells
  it for the rest of the interface.
  """
  @spec format(key() | String.t(), :rich | :measured | :ascii | boolean()) :: String.t()
  def format(name, tier) when is_binary(name) do
    case parse(name) do
      {:ok, [key | _]} -> format(key, tier)
      {:error, _} -> name
    end
  end

  def format(key, tier), do: KeyLabel.label(key, tier in [:ascii, true])

  @doc "The canonical stored spelling of a typed name, or the parse error."
  @spec canonical(term()) :: {:ok, String.t()} | {:error, String.t()}
  def canonical(name) do
    with {:ok, [key | _]} <- parse(name), do: {:ok, name(key)}
  end

  # ---------------------------------------------------------------- parsing

  defp prefixes(text, mods) do
    case Regex.run(~r/\A(ctrl|control|alt|opt|option|shift)-(.+)\z/i, text) do
      [_, prefix, rest] ->
        mod =
          case String.downcase(prefix) do
            p when p in ["ctrl", "control"] -> :control
            p when p in ["alt", "opt", "option"] -> :alt
            "shift" -> :shift
          end

        if mod in mods, do: {:error, "not a key name"}, else: prefixes(rest, [mod | mods])

      nil ->
        {:ok, Enum.sort(mods), text}
    end
  end

  defp code(text) do
    down = String.downcase(text)

    cond do
      Map.has_key?(@named, down) -> {:ok, Map.fetch!(@named, down)}
      Map.has_key?(@function, down) -> {:ok, Map.fetch!(@function, down)}
      single_printable?(text) -> {:ok, text}
      true -> {:error, "not a key name"}
    end
  end

  defp single_printable?(text) do
    String.length(text) == 1 and String.printable?(text) and text != " " and
      not String.match?(text, ~r/\A[\x00-\x1f\x7f]\z/)
  end

  defp build(:tab, [:shift], _name), do: {:ok, [{:back_tab, []}, {:tab, [:shift]}]}

  defp build(code, mods, name) when code in [:enter, :tab] do
    if :control in mods or (:shift in mods and code == :enter),
      do: unreportable(name),
      else: {:ok, [{code, mods}]}
  end

  defp build(" ", mods, name) do
    if :shift in mods, do: unreportable(name), else: {:ok, [{" ", mods}]}
  end

  defp build(code, mods, name) when is_binary(code) do
    letter? = String.match?(code, ~r/\A[A-Za-z]\z/)

    cond do
      :control in mods and letter? and :shift in mods ->
        unreportable(name)

      :control in mods and Map.has_key?(@ctrl_aliases, String.downcase(code)) ->
        unreportable(name)

      :control in mods and not letter? ->
        unreportable(name)

      :control in mods ->
        {:ok, [{String.downcase(code), mods}]}

      letter? and :shift in mods ->
        {:ok, [{String.upcase(code), mods -- [:shift]}]}

      :shift in mods ->
        # a shifted symbol arrives as the symbol itself (`?`, not Shift-/)
        {:ok, [{code, mods -- [:shift]}]}

      true ->
        {:ok, [{code, mods}]}
    end
  end

  defp build(code, mods, _name), do: {:ok, [{code, mods}]}

  defp unreportable(name), do: {:error, "this terminal cannot report #{name}"}

  # --------------------------------------------------------------- printing

  defp normalize(code, mods) when is_binary(code) do
    cond do
      (:control in mods or :alt in mods) and String.length(code) == 1 and :shift in mods and
          code == String.upcase(code) ->
        {code, mods -- [:shift]}

      :control in mods and String.length(code) == 1 ->
        {String.upcase(code), mods}

      true ->
        {code, mods -- [:shift]}
    end
  end

  defp normalize(code, mods), do: {code, mods}

  defp prefix(mods) do
    Enum.map_join([:control, :alt, :shift], "", fn
      :control -> if :control in mods, do: "Ctrl-", else: ""
      :alt -> if :alt in mods, do: "Alt-", else: ""
      :shift -> if :shift in mods, do: "Shift-", else: ""
    end)
  end

  defp code_name({:function, n}), do: "F#{n}"
  defp code_name(" "), do: "Space"
  defp code_name(code) when is_binary(code), do: code
  defp code_name(code) when is_map_key(@stored, code), do: Map.fetch!(@stored, code)
  defp code_name(code) when is_atom(code), do: Atom.to_string(code)

  @doc false
  def ctrl_aliases, do: @ctrl_aliases
end
