defmodule SwarmCodeCLI.UI.Settings.Event do
  @moduledoc """
  The closed vocabulary of `{:settings, event}` actions (cli74): what the
  keymap sends the settings layer, and what the session runtime and the data
  source hand back to it. `valid?/1` is the gate `UI.Action.validate/1` uses,
  so nothing unbounded or unknown reaches the reducer.

  Keys: `{:verb, verb}` (a binding's verb, §3.9.2), `{:text, text}` (typing in
  a typing context), `{:key, key}` (an editor key, `Settings.Editor`),
  `{:paste, text}` (a bracketed paste), `{:raw, {code, mods}}` (the key-capture
  editor and Ctrl-F's badges), `{:wheel, delta, column, row}`.
  """

  alias SwarmCodeCLI.UI.Keymap.SettingsBindings
  alias SwarmCodeCLI.UI.Settings.{Editor, Sections}

  # A typed fragment is one key's text; a paste has the input's own bound.
  @max_text_bytes 4_096
  @max_paste_bytes 262_144
  @max_open_arg_bytes 200
  @mods [:alt, :control, :shift, :super, :meta, :hyper]

  @doc "Whether `event` may be carried by a `{:settings, event}` action."
  @spec valid?(term()) :: boolean()
  def valid?({:verb, verb}) when is_atom(verb), do: verb in SettingsBindings.verbs()

  def valid?({:text, text}) when is_binary(text),
    do: text != "" and byte_size(text) <= @max_text_bytes and printable?(text)

  def valid?({:key, _key} = event), do: Editor.event?(event)

  def valid?({:paste, text}) when is_binary(text),
    do: byte_size(text) <= @max_paste_bytes and String.valid?(text)

  def valid?({:raw, {code, mods}}) when is_list(mods),
    do: raw_code?(code) and Enum.all?(mods, &(&1 in @mods))

  def valid?({:wheel, delta, column, row}),
    do: is_integer(delta) and abs(delta) <= 10 and non_neg?(column) and non_neg?(row)

  def valid?(_event), do: false

  @doc """
  Whether `arg` may open the layer: `nil` (the resume point), the rest of a
  `/settings` line (≤ 200 bytes), `{:section, id}` or `{:key, registry_key}`.
  """
  @spec open_arg?(term()) :: boolean()
  def open_arg?(nil), do: true

  def open_arg?(arg) when is_binary(arg),
    do: byte_size(arg) <= @max_open_arg_bytes and String.valid?(arg) and printable?(arg)

  def open_arg?({:section, id}) when is_atom(id), do: id in Sections.ids()

  def open_arg?({:key, key}) when is_binary(key),
    do: key != "" and byte_size(key) <= 64 and String.valid?(key)

  def open_arg?(_arg), do: false

  defp raw_code?(code) when is_binary(code),
    do: code != "" and byte_size(code) <= 16 and String.valid?(code)

  defp raw_code?({:function, n}), do: is_integer(n) and n in 1..12
  defp raw_code?(code), do: is_atom(code) and not is_nil(code) and not is_boolean(code)

  defp non_neg?(value), do: is_integer(value) and value >= 0

  # Control codes, DEL and C1 are never text.
  defp printable?(text) do
    String.valid?(text) and
      text
      |> String.to_charlist()
      |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F and not (&1 >= 0x80 and &1 <= 0x9F)))
  end
end
