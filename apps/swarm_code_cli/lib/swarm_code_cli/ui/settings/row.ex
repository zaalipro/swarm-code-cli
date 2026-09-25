defmodule SwarmCodeCLI.UI.Settings.Row do
  @moduledoc """
  One row of a settings page (spec §3.7.2), pure data a section builds and the
  projector draws.

    * `id` is stable inside its page: `key:<registry key>`, `rec:<kind>:<id>`,
      `fld:<kind>:<id>:<field>`, `act:<name>`, `head:<group>`, `item:<list>:<n>`,
      `info:<name>`.
    * `kind` is `:setting | :record | :field | :action | :heading | :info | :link
      | :list_item | :kv_item`.
    * `value` and `tag` are segment lists `[{text, role}]` (`role` a
      `UI.Theme` role); the tag is right-aligned on the row.
    * `marks` are `:changed | :attention | :invalid | :running | :pending |
      :conflict`; the projector draws the strongest one in the mark column.
    * `lines` are continuation lines (each a segment list) drawn under the row.
    * `editor` is `nil` or `{module, opts}` (a `Settings.Editor`).
    * `keys` are `[{key_label, action_verb, words}]` the footer and the detail
      show for this row: only the letters a row lists are hinted.
    * `columns` is `nil` or `[{text, role, priority}]` for record tables:
      columns drop right to left by priority as the page narrows.
    * `target` is opaque to U1 and handed back to the section's `act/3`.
  """

  alias SwarmCodeCLI.UI.Settings.Detail

  defstruct id: nil,
            kind: :setting,
            key: nil,
            label: "",
            value: [],
            tag: [],
            marks: [],
            lines: [],
            editor: nil,
            keys: [],
            detail: nil,
            state: :normal,
            columns: nil,
            target: nil,
            indent: 0

  @type segment :: {String.t(), atom()}
  @type t :: %__MODULE__{
          id: String.t(),
          kind:
            :setting
            | :record
            | :field
            | :action
            | :heading
            | :info
            | :link
            | :list_item
            | :kv_item,
          key: String.t() | nil,
          label: String.t(),
          value: [segment()],
          tag: [segment()],
          marks: [atom()],
          lines: [[segment()]],
          editor: nil | {module(), map()},
          keys: [{String.t(), atom(), String.t()}],
          detail: nil | Detail.t(),
          state: :normal | :readonly | :disabled | :loading | :running,
          columns: nil | [{String.t(), atom(), pos_integer()}],
          target: term(),
          indent: non_neg_integer()
        }

  @kinds [:setting, :record, :field, :action, :heading, :info, :link, :list_item, :kv_item]
  @marks [:changed, :attention, :invalid, :running, :pending, :conflict]

  @doc "The row kinds."
  def kinds, do: @kinds

  @doc "The marks a row may carry."
  def marks, do: @marks

  @doc "Whether the cursor may rest on this row (headings and blank info rows are skipped)."
  @spec focusable?(t()) :: boolean()
  def focusable?(%__MODULE__{kind: :heading}), do: false
  def focusable?(%__MODULE__{kind: :info, target: nil, keys: []}), do: false
  def focusable?(%__MODULE__{}), do: true

  @doc "A lowercase group heading row."
  @spec heading(String.t(), [segment()]) :: t()
  def heading(text, tag \\ []),
    do: %__MODULE__{id: "head:" <> text, kind: :heading, label: text, tag: tag}

  @doc "A row of words that is not a setting (an empty state, a note)."
  @spec info(String.t(), [segment()] | String.t(), keyword()) :: t()
  def info(name, value, opts \\ [])

  def info(name, value, opts) when is_binary(value),
    do: info(name, [{value, Keyword.get(opts, :role, :text_muted)}], opts)

  def info(name, value, opts) do
    %__MODULE__{
      id: "info:" <> name,
      kind: :info,
      label: Keyword.get(opts, :label, ""),
      value: value,
      target: Keyword.get(opts, :target),
      keys: Keyword.get(opts, :keys, [])
    }
  end
end
