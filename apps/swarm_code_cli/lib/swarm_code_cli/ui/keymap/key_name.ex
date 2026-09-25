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
  The key a name spells (`{code, mods}`), syntactically: `Ctrl-Shift-Z`
  parses, although a terminal cannot report it (`keys/1` says so); `Shift-x`
  does not (a shifted letter is written as the capital, `X`).
  """
  @spec parse(term()) :: {:ok, key()} | {:error, String.t()}
  def parse(name) when is_binary(name) and byte_size(name) in 1..@max_bytes do
    with {:ok, mods, rest} <- prefixes(String.trim(name), []),
         {:ok, code} <- code(rest) do
      build(code, mods)
    end
  end

  def parse(_), do: {:error, "not a key name"}

  @doc """
  The keys an override of `name` binds: the parsed key when the terminal can
  report it, plus the second code a terminal sends for the same chord
  (`Shift-Tab` is both the back-tab code and Tab with Shift).
  """
  @spec keys(term()) :: {:ok, [key()]} | {:error, String.t()}
  def keys(name) do
    with {:ok, key} <- parse(name),
         :ok <- reportable(key),
         do: {:ok, expand(key)}
  end

  @doc "Every code a terminal may send for `key` (`Shift-Tab`: two)."
  @spec expand(key()) :: [key()]
  def expand({:back_tab, []}), do: [{:back_tab, []}, {:tab, [:shift]}]
  def expand({:tab, [:shift]}), do: [{:back_tab, []}, {:tab, [:shift]}]
  def expand(key), do: [key]

  @doc """
  Whether a terminal without the enhanced keyboard protocol can report `key`
  as itself: not `Ctrl-Shift-<letter>`, `Ctrl-Enter`, `Shift-Enter`,
  `Ctrl-Tab`, `Shift-Space`, nor the Ctrl letters that arrive as another key
  (`Ctrl-I` is Tab, `Ctrl-M` Enter, `Ctrl-[` Esc) or Ctrl with a symbol.
  """
  @spec reportable(key()) :: :ok | {:error, String.t()}
  def reportable({code, mods} = key) do
    control? = :control in mods
    shift? = :shift in mods
    letter? = is_binary(code) and String.match?(code, ~r/\A[A-Za-z]\z/)

    unreportable? =
      cond do
        code == :enter ->
          control? or shift?

        code == :tab ->
          control?

        code == " " ->
          shift?

        is_binary(code) and control? and letter? ->
          shift? or Map.has_key?(@ctrl_aliases, String.downcase(code))

        is_binary(code) and control? ->
          true

        true ->
          false
      end

    if unreportable?, do: {:error, "this terminal cannot report #{name(key)}"}, else: :ok
  end

  @doc "Whether `name` parses."
  @spec valid?(term()) :: boolean()
  def valid?(name), do: match?({:ok, _}, parse(name))

  @doc """
  The stored spelling of a key (the parse form, `Ctrl-L`, `PageDown`, `Up`):
  what cli.json holds and `parse/1` reads back to the same key.
  """
  @spec name(key()) :: String.t()
  def name({:back_tab, _mods}), do: "Shift-Tab"
  def name({:tab, mods}) when mods == [:shift], do: "Shift-Tab"

  def name({code, mods}) when is_list(mods) do
    {code, mods} = normalize(code, mods)
    prefix(mods) <> code_name(code)
  end

  @doc """
  A key as the screen prints it: arrows as `↑ ↓ ← →` in the rich and measured
  glyph tiers, words in ascii; `:stored` is `name/1`; everything else as
  `Projector.KeyLabel` spells it for the rest of the interface.
  """
  @spec format(key() | String.t(), :stored | :rich | :measured | :ascii | boolean()) ::
          String.t()
  def format(name, tier) when is_binary(name) do
    case parse(name) do
      {:ok, key} -> format(key, tier)
      {:error, _} -> name
    end
  end

  def format(key, :stored), do: name(key)
  def format(key, tier), do: KeyLabel.label(key, tier in [:ascii, true])

  @doc "The canonical stored spelling of a typed name, or why it is not one."
  @spec canonical(term()) :: {:ok, String.t()} | {:error, String.t()}
  def canonical(name) do
    with {:ok, key} <- parse(name), :ok <- reportable(key), do: {:ok, name(key)}
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

  defp build(:tab, [:shift]), do: {:ok, {:back_tab, []}}

  defp build(code, mods) when is_binary(code) do
    letter? = String.match?(code, ~r/\A[A-Za-z]\z/)
    command? = :control in mods or :alt in mods

    cond do
      :control in mods and letter? ->
        {:ok, {String.downcase(code), mods}}

      # A shifted letter or symbol is the character itself (`X`, `?`).
      :shift in mods and not command? ->
        {:error, "not a key name"}

      true ->
        {:ok, {code, mods}}
    end
  end

  defp build(code, mods), do: {:ok, {code, mods}}

  # --------------------------------------------------------------- printing

  defp normalize(code, mods) when is_binary(code) do
    cond do
      :control in mods and String.length(code) == 1 -> {String.upcase(code), mods}
      :alt in mods and String.length(code) == 1 -> {code, mods}
      true -> {code, mods -- [:shift]}
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
