defmodule SwarmCodeCLI.UI.Settings.Editors.Text do
  @moduledoc """
  A single-line text (spec §3.7.8): typing and pastes insert at the caret,
  ← → Home End Ctrl-A Ctrl-E Ctrl-W Ctrl-U edit, Enter writes (after the
  entry's own checks, when it has one), Esc puts the old value back. A value
  longer than `max` bytes is refused whole with the words, never cut.

  Opts: `value`, `max` (bytes, 4 096), `entry` (a registry entry: its
  normalisation and validators), `parse` (an entry whose text form is
  parsed: a model's `provider/model`), `placeholder`, `nullable` (blank =
  null).
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCode.Settings.{Entry, TextValue, Validate}
  alias SwarmCodeCLI.UI.Settings.Buffer

  @impl true
  def init(_row, opts, _ctx) do
    value = Map.get(opts, :value)
    text = if is_binary(value), do: value, else: to_string(value || "")
    max = Map.get(opts, :max, 4_096)

    if byte_size(text) > max,
      do: {:ok, %{opts: opts, buffer: Buffer.new("", max: max), original: value, error: nil}},
      else: {:ok, %{opts: opts, buffer: Buffer.new(text, max: max), original: value, error: nil}}
  end

  @impl true
  def handle(state, {:key, :enter}, _ctx) do
    case check(state.opts, state.buffer.text) do
      {:ok, value} -> {:commit, value, %{state | error: nil}}
      {:error, message} -> {:cont, %{state | error: message}}
    end
  end

  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(state, {:key, key}, _ctx),
    do: {:cont, %{state | buffer: Buffer.key(state.buffer, key), error: nil}}

  def handle(state, {event, text}, _ctx) when event in [:text, :paste] and is_binary(text) do
    text = if event == :paste, do: String.trim_trailing(text, "\n"), else: text

    case Buffer.insert(state.buffer, text) do
      {:ok, buffer} ->
        {:cont, %{state | buffer: buffer, error: nil}}

      {:error, :multiline} ->
        {:cont, %{state | error: "one line only"}}

      {:error, :too_long} ->
        {:cont, %{state | error: "that is longer than #{state.buffer.max} bytes"}}
    end
  end

  def handle(state, _event, _ctx), do: {:cont, state}

  @doc "The value Enter writes: `{:ok, value}` or `{:error, message}`."
  @spec check(map(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def check(%{parse: %Entry{} = entry} = opts, text) do
    if text == "" and Map.get(opts, :nullable, entry.nullable) do
      {:ok, nil}
    else
      with {:ok, value} <- TextValue.parse(entry, text),
           :ok <- Validate.check(entry, value) do
        {:ok, value}
      end
    end
  end

  def check(%{entry: %Entry{} = entry} = opts, text) do
    value = if text == "" and Map.get(opts, :nullable, entry.nullable), do: nil, else: text
    value = if is_binary(value), do: Validate.normalise(entry, value), else: value

    case Validate.check(entry, value) do
      :ok -> {:ok, value}
      {:error, message} -> {:error, message}
    end
  end

  def check(opts, text) do
    cond do
      text == "" and Map.get(opts, :nullable, false) -> {:ok, nil}
      Map.get(opts, :required, false) and String.trim(text) == "" -> {:error, "can't be blank"}
      true -> {:ok, text}
    end
  end

  @impl true
  def display(state, _ctx) do
    {before, rest} = Buffer.split(state.buffer)

    value =
      if state.buffer.text == "" and is_binary(Map.get(state.opts, :placeholder)),
        do: [{"▏", :focus}, {state.opts.placeholder, :text_faint}],
        else: [{before, :text_primary}, {"▏", :focus}, {rest, :text_primary}]

    %{
      value: value,
      lines: if(state.error, do: [[{"✗ " <> state.error, :error}]], else: []),
      popover: nil,
      context: :settings_edit,
      footer: [{"Enter", "save"}, {"Esc", "cancel"}, {"Ctrl-U", "clear"}]
    }
  end
end
