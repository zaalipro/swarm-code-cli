defmodule SwarmCodeCLI.UI.Keymap.KeyName do
  @moduledoc """
  Key names as the user writes them in cli.json's `keys` and on the Key
  bindings page (spec §4.4): `Ctrl-`, `Alt-`, `Shift-` prefixes in that order,
  then a lowercase letter (`x`), a shifted letter written as the capital (`X`,
  never `Shift-x`), a digit, a symbol (`?`, `[`, `/`) or a named key (`Enter`,
  `Esc`, `Tab`, `Backspace`, `Delete`, `Space`, `Up`, `Down`, `Left`, `Right`,
  `Home`, `End`, `PageUp`, `PageDown`, `Insert`, `F1`–`F12`).

  Parsing is case-insensitive for the prefixes and the named keys and
  case-sensitive for letters. The parsed form is the table's `{code, mods}`;
  the stored form is `format(key, :stored)` (`"Ctrl-L"`).
  """

  @named %{
    "enter" => :enter,
    "return" => :enter,
    "esc" => :escape,
    "escape" => :escape,
    "tab" => :tab,
    "backspace" => :backspace,
    "delete" => :delete,
    "del" => :delete,
    "space" => " ",
    "up" => :up,
    "down" => :down,
    "left" => :left,
    "right" => :right,
    "home" => :home,
    "end" => :end,
    "pageup" => :page_up,
    "pgup" => :page_up,
    "pagedown" => :page_down,
    "pgdn" => :page_down,
    "insert" => :insert
  }

  @stored %{
    enter: "Enter",
    escape: "Esc",
    tab: "Tab",
    back_tab: "Shift-Tab",
    backspace: "Backspace",
    delete: "Delete",
    up: "Up",
    down: "Down",
    left: "Left",
    right: "Right",
    home: "Home",
    end: "End",
    page_up: "PageUp",
    page_down: "PageDown",
    insert: "Insert",
    null: "Ctrl-Space"
  }

  @prefixes [{"ctrl-", :control}, {"alt-", :alt}, {"shift-", :shift}]
  @max_bytes 32

  @doc """
  `{:ok, {code, mods}}` for a key name, `{:error, words}` otherwise. Mods are
  sorted, as the binding table stores them.
  """
  @spec parse(String.t()) :: {:ok, {term(), [atom()]}} | {:error, String.t()}
  def parse(name) when is_binary(name) and byte_size(name) <= @max_bytes do
    trimmed = String.trim(name)

    with {:ok, mods, rest} <- prefixes(trimmed, []),
         {:ok, code, mods} <- key(rest, mods) do
      {:ok, {code, Enum.sort(mods)}}
    end
  end

  def parse(_name), do: {:error, "not a key name"}

  defp prefixes(text, mods) do
    down = String.downcase(text)

    case Enum.find(@prefixes, fn {prefix, _} ->
           String.starts_with?(down, prefix) and byte_size(text) > byte_size(prefix)
         end) do
      nil ->
        {:ok, Enum.reverse(mods), text}

      {prefix, mod} ->
        if mod in mods,
          do: {:error, "#{text} repeats a prefix"},
          else:
            prefixes(binary_part(text, byte_size(prefix), byte_size(text) - byte_size(prefix)), [
              mod | mods
            ])
    end
  end

  defp key("", _mods), do: {:error, "not a key name"}

  defp key(text, mods) do
    down = String.downcase(text)

    cond do
      Map.has_key?(@named, down) ->
        named(Map.fetch!(@named, down), mods)

      function_key(down) ->
        {:ok, {:function, function_key(down)}, mods}

      String.length(text) == 1 and printable?(text) ->
        character(text, mods)

      true ->
        {:error, "#{text} is not a key name"}
    end
  end

  defp named(:tab, mods) do
    if :shift in mods, do: {:ok, :back_tab, mods -- [:shift]}, else: {:ok, :tab, mods}
  end

  defp named(code, mods), do: {:ok, code, mods}

  defp function_key("f" <> digits) do
    case Integer.parse(digits) do
      {n, ""} when n in 1..12 -> n
      _ -> nil
    end
  end

  defp function_key(_text), do: nil

  # A letter carries its shift in its case: `X`, never `Shift-x`. Under Ctrl or
  # Alt the letter is stored lower-case (the terminal reports either case) and
  # Shift stays a real modifier.
  defp character(char, mods) do
    letter? = String.upcase(char) != String.downcase(char)
    chord? = :control in mods or :alt in mods

    cond do
      letter? and chord? ->
        {:ok, String.downcase(char), mods}

      letter? and :shift in mods ->
        {:error, "write Shift-#{char} as #{String.upcase(char)}"}

      :shift in mods and not chord? ->
        {:error, "write the shifted symbol itself, not Shift-#{char}"}

      true ->
        {:ok, char, mods}
    end
  end

  defp printable?(char), do: String.printable?(char) and char not in ["\n", "\r", "\t"]

  @doc """
  A key as text. `:stored` is the parse form (`Ctrl-L`, `PageDown`, `Up`);
  `:rich` and `:measured` print arrows as `↑ ↓ ← →`; `:ascii` spells them.
  """
  @spec format({term(), [atom()]}, :stored | :rich | :measured | :ascii) :: String.t()
  def format({code, mods}, tier) when is_list(mods) do
    prefix =
      Enum.map_join([:control, :alt, :shift], "", fn mod ->
        if mod in mods, do: %{control: "Ctrl-", alt: "Alt-", shift: "Shift-"}[mod], else: ""
      end)

    prefix <> code_name(code, mods, tier)
  end

  defp code_name(code, _mods, tier)
       when code in [:up, :down, :left, :right] and tier in [:rich, :measured],
       do: %{up: "↑", down: "↓", left: "←", right: "→"}[code]

  defp code_name({:function, n}, _mods, _tier), do: "F#{n}"
  defp code_name(" ", _mods, _tier), do: "Space"

  defp code_name(code, mods, _tier) when is_binary(code) do
    if :control in mods or :alt in mods, do: String.upcase(code), else: code
  end

  defp code_name(code, _mods, _tier) when is_atom(code),
    do: Map.get(@stored, code, Atom.to_string(code))
end
