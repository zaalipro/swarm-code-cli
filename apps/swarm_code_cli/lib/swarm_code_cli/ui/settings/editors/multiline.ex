defmodule SwarmCodeCLI.UI.Settings.Editors.Multiline do
  @moduledoc """
  A multi-line text (spec §3.7.8): Enter inserts a line break, Ctrl-S
  writes, Ctrl-X hands the text to `terminal.editor` (the external-edit
  op; its return comes back through the file CAS), Esc puts it back. At
  most 16 384 bytes; more is refused whole, never cut. Opts: `value`,
  `max`, `ref` and `suffix` (for the external edit), `loading`.
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCodeCLI.UI.Settings.Buffer

  @max 16_384
  @shown 12

  @impl true
  def init(_row, opts, _ctx) do
    value = Map.get(opts, :value) || ""
    max = Map.get(opts, :max, @max)
    text = if byte_size(value) > max, do: "", else: value

    {:ok,
     %{
       opts: opts,
       buffer: Buffer.new(text, max: max, multiline?: true),
       original: value,
       error: nil
     }}
  end

  @impl true
  def handle(state, {:key, {:ctrl, "s"}}, _ctx), do: {:commit, state.buffer.text, state}
  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(state, {:key, {:ctrl, "x"}}, _ctx) do
    spec = %{
      ref: Map.get(state.opts, :ref, "text"),
      content: state.buffer.text,
      fingerprint: Map.get(state.opts, :fingerprint),
      suffix: Map.get(state.opts, :suffix, ".md")
    }

    {:ops, [{:external_edit, spec}], state}
  end

  def handle(state, {:replace, text}, _ctx) when is_binary(text) do
    case Buffer.replace(state.buffer, text) do
      {:ok, buffer} -> {:cont, %{state | buffer: buffer, error: nil}}
      {:error, _} -> {:cont, %{state | error: "that is longer than #{state.buffer.max} bytes"}}
    end
  end

  def handle(state, {:key, :enter}, _ctx), do: insert(state, "\n")

  def handle(state, {:key, key}, _ctx),
    do: {:cont, %{state | buffer: Buffer.key(state.buffer, key), error: nil}}

  def handle(state, {event, text}, _ctx) when event in [:text, :paste] and is_binary(text),
    do: insert(state, text)

  def handle(state, _event, _ctx), do: {:cont, state}

  defp insert(state, text) do
    case Buffer.insert(state.buffer, text) do
      {:ok, buffer} -> {:cont, %{state | buffer: buffer, error: nil}}
      {:error, _} -> {:cont, %{state | error: "that is longer than #{state.buffer.max} bytes"}}
    end
  end

  @doc "Whether the text differs from what was stored."
  def dirty?(state), do: state.buffer.text != (state.original || "")

  @impl true
  def display(state, _ctx) do
    {line, column} = Buffer.position(state.buffer)
    lines = Buffer.lines(state.buffer)
    start = max(min(line - div(@shown, 2), length(lines) - @shown), 0)

    shown =
      lines
      |> Enum.with_index()
      |> Enum.slice(start, @shown)
      |> Enum.map(fn {text, index} ->
        if index == line do
          {before, rest} = String.split_at(text, column)
          [{before, :text_primary}, {"▏", :focus}, {rest, :text_primary}]
        else
          [{text, :text_primary}]
        end
      end)

    error = if state.error, do: [[{"✗ " <> state.error, :error}]], else: []

    %{
      value: [{"#{length(lines)} lines · #{byte_size(state.buffer.text)} bytes", :text_muted}],
      lines: shown ++ error,
      popover: nil,
      context: :settings_edit,
      footer: [{"Ctrl-S", "save"}, {"Ctrl-X", "editor"}, {"Esc", "cancel"}]
    }
  end
end
