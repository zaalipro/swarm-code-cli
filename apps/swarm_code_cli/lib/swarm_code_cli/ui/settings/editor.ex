defmodule SwarmCodeCLI.UI.Settings.Editor do
  @moduledoc """
  A field editor of the settings layer (spec §3.7.2, §3.7.8). Pure: `init/3`
  opens it on a row, `handle/3` takes one event and answers

    * `{:cont, state}` — keep editing;
    * `{:commit, wire_value, state}` — write this value (the layer's commit
      path, or the section's `commit/3`);
    * `{:cancel, state}` — put the old value back;
    * `{:ops, [op], state}` — anything else (open a picker, a confirmation).

  Events: `{:key, :enter | :escape | :left | :right | :up | :down | :tab |
  :backtab | :home | :end | :backspace | :delete | :space | :page_up |
  :page_down | {:ctrl, char} | {:shift, atom}}`, `{:text, string}`,
  `{:paste, string}`, `{:raw, {code, mods}}` (capture editors only) and
  `:tick`.

  `display/2` says how the row looks while the editor is open: the value
  segments, continuation lines, an optional popover, the keymap context the
  editor needs (`:settings_edit` for typing, `:settings` for stepping,
  `:settings_capture`) and its footer keys.
  """

  alias SwarmCodeCLI.UI.Settings.{Ctx, Op, Row}

  @type event ::
          {:key, atom() | {:ctrl, String.t()} | {:shift, atom()}}
          | {:text, String.t()}
          | {:paste, String.t()}
          | {:raw, {term(), [atom()]}}
          | :tick

  @type display :: %{
          value: [{String.t(), atom()}],
          lines: [[{String.t(), atom()}]],
          popover: nil | map(),
          context: atom(),
          footer: [{String.t(), String.t()}]
        }

  @callback init(Row.t(), opts :: map(), Ctx.t()) :: {:ok, term()} | {:error, String.t()}
  @callback handle(term(), event(), Ctx.t()) ::
              {:cont, term()}
              | {:commit, term(), term()}
              | {:cancel, term()}
              | {:ops, [Op.t()], term()}
  @callback display(term(), Ctx.t()) :: display()

  @keys [
    :enter,
    :escape,
    :left,
    :right,
    :up,
    :down,
    :tab,
    :backtab,
    :home,
    :end,
    :backspace,
    :delete,
    :space,
    :page_up,
    :page_down
  ]

  @doc "The plain key events an editor receives."
  def keys, do: @keys

  @doc "Whether `event` is one an editor may receive."
  @spec event?(term()) :: boolean()
  def event?({:key, key}) when key in @keys, do: true
  def event?({:key, {:ctrl, char}}) when is_binary(char), do: byte_size(char) == 1
  def event?({:key, {:shift, key}}) when key in @keys, do: true
  def event?({:text, text}) when is_binary(text), do: text != ""
  def event?({:paste, text}) when is_binary(text), do: true
  def event?({:raw, {_code, mods}}) when is_list(mods), do: true
  def event?(:tick), do: true
  def event?(_event), do: false
end
