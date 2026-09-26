defmodule SwarmCodeCLI.UI.Settings.Editors.Number do
  @moduledoc """
  A number (spec §3.7.8): integers, durations, money. ← → step by `step`,
  Shift-← Shift-→ (and PgUp/PgDn inside the open editor) by `big_step`;
  digits type a value; Enter checks the bounds and writes, or keeps the
  editor open with the exact message; Esc puts the old value back. A special
  (`0` = "no limit") is typed by its words; a nullable number is cleared
  with Ctrl-U.

  Opts: `value`, `min`, `max`, `step` (1), `big_step`, `decimals` (0),
  `special` (`%{value => words}`), `nullable`, `null_label`, `unit`, and
  `entry` (a registry entry: its grammar `30m`, `2h`, `default` and its
  validators apply).
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCode.Settings.{Entry, TextValue, Validate}
  alias SwarmCodeCLI.UI.Settings.Buffer

  @doc "The value after stepping `delta` steps (`:big` steps scale by `big_step`)."
  @spec step(map(), term(), integer(), :small | :big) :: term()
  def step(opts, value, delta, size \\ :small) do
    unit = if size == :big, do: big_step(opts), else: Map.get(opts, :step, 1) || 1
    min = Map.get(opts, :min)
    max = Map.get(opts, :max)

    start =
      cond do
        not is_number(value) ->
          min || 0

        Map.has_key?(Map.get(opts, :special, %{}), value) and is_number(min) and value < min ->
          min

        true ->
          value
      end

    next = start + delta * unit
    next = if is_number(min), do: Kernel.max(next, min), else: next
    next = if is_number(max), do: Kernel.min(next, max), else: next
    round_to(next, Map.get(opts, :decimals, 0))
  end

  defp big_step(opts), do: Map.get(opts, :big_step) || (Map.get(opts, :step, 1) || 1) * 10

  defp round_to(value, 0) when is_float(value), do: round(value)
  defp round_to(value, 0), do: value
  defp round_to(value, decimals), do: Float.round(value * 1.0, decimals)

  @doc "The words of a value: its special words, its null label, else the number with its unit."
  @spec words(map(), term()) :: String.t()
  def words(opts, nil), do: Map.get(opts, :null_label) || "none"

  def words(%{entry: %Entry{} = entry}, value), do: TextValue.format(entry, value)

  def words(opts, value) do
    case Map.fetch(Map.get(opts, :special, %{}), value) do
      {:ok, words} -> words
      :error -> format(value, opts) <> unit_words(Map.get(opts, :unit))
    end
  end

  defp format(value, opts) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: Map.get(opts, :decimals, 2))

  defp format(value, _opts), do: to_string(value)

  defp unit_words(:usd_per_m), do: " $/M"
  defp unit_words(:ms), do: " ms"
  defp unit_words(:s), do: " s"
  defp unit_words(:days), do: " days"
  defp unit_words(:usd), do: ""
  defp unit_words(:rows), do: " rows"
  defp unit_words(:lines), do: " lines"
  defp unit_words(_unit), do: ""

  @impl true
  def init(_row, opts, _ctx) do
    value = Map.get(opts, :value)
    text = if value == nil, do: "", else: typed_text(opts, value)
    {:ok, %{opts: opts, buffer: Buffer.new(text, max: 64), original: value, error: nil}}
  end

  defp typed_text(%{entry: %Entry{} = entry}, value), do: TextValue.format(entry, value)
  defp typed_text(opts, value), do: format(value, opts)

  @impl true
  def handle(state, {:key, :enter}, _ctx) do
    case parse(state.opts, state.buffer.text) do
      {:ok, value} -> {:commit, value, %{state | error: nil}}
      {:error, message} -> {:cont, %{state | error: message}}
    end
  end

  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(state, {:key, key}, _ctx) when key in [:left, :right, :page_up, :page_down] do
    delta = if key in [:left, :page_down], do: -1, else: 1
    size = if key in [:page_up, :page_down], do: :big, else: :small
    {:cont, stepped(state, delta, size)}
  end

  def handle(state, {:key, {:shift, key}}, _ctx) when key in [:left, :right],
    do: {:cont, stepped(state, if(key == :left, do: -1, else: 1), :big)}

  # Ctrl-U: a nullable number becomes null; any other one is cleared to type.
  def handle(state, {:key, {:ctrl, "u"}}, _ctx) do
    if Map.get(state.opts, :nullable, false),
      do: {:commit, nil, state},
      else: {:cont, %{state | buffer: Buffer.new("", max: 64), error: nil}}
  end

  def handle(state, {:key, key}, _ctx),
    do: {:cont, %{state | buffer: Buffer.key(state.buffer, key), error: nil}}

  def handle(state, {event, text}, _ctx) when event in [:text, :paste] and is_binary(text) do
    case Buffer.insert(state.buffer, String.trim(text)) do
      {:ok, buffer} -> {:cont, %{state | buffer: buffer, error: nil}}
      {:error, _} -> {:cont, %{state | error: "that is too long for a number"}}
    end
  end

  def handle(state, _event, _ctx), do: {:cont, state}

  defp stepped(state, delta, size) do
    current =
      case parse(state.opts, state.buffer.text) do
        {:ok, value} -> value
        {:error, _} -> state.original
      end

    value = step(state.opts, current, delta, size)
    %{state | buffer: Buffer.new(typed_text(state.opts, value), max: 64), error: nil}
  end

  @doc "Parses typed text against the opts: `{:ok, value}` or `{:error, message}`."
  @spec parse(map(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def parse(%{entry: %Entry{} = entry}, text) do
    with {:ok, value} <- TextValue.parse(entry, text),
         :ok <- Validate.check(entry, value) do
      {:ok, value}
    end
  end

  def parse(opts, text) do
    trimmed = String.trim(text)
    special = Enum.find(Map.get(opts, :special, %{}), fn {_value, words} -> words == trimmed end)

    cond do
      special != nil ->
        {:ok, elem(special, 0)}

      trimmed == "" and Map.get(opts, :nullable, false) ->
        {:ok, nil}

      trimmed == "" ->
        {:error, "can't be blank"}

      true ->
        with {:ok, value} <- number(trimmed, Map.get(opts, :decimals, 0)),
             :ok <- bounds(opts, value),
             do: {:ok, value}
    end
  end

  defp number(text, 0) do
    case Integer.parse(String.replace(text, "_", "")) do
      {value, ""} -> {:ok, value}
      _ -> {:error, "is invalid"}
    end
  end

  defp number(text, decimals) do
    case Float.parse(String.replace(text, "_", "")) do
      {value, ""} -> {:ok, Float.round(value, decimals)}
      _ -> {:error, "is invalid"}
    end
  end

  defp bounds(opts, value) do
    min = Map.get(opts, :min)
    max = Map.get(opts, :max)

    cond do
      is_number(min) and is_number(max) and (value < min or value > max) ->
        {:error, "must be between #{min} and #{max}"}

      is_number(min) and value < min ->
        {:error, "must be greater than or equal to #{min}"}

      is_number(max) and value > max ->
        {:error, "must be less than or equal to #{max}"}

      true ->
        :ok
    end
  end

  @impl true
  def display(state, _ctx) do
    {before, rest} = Buffer.split(state.buffer)

    %{
      value: [{before, :text_primary}, {"▏", :focus}, {rest, :text_primary}],
      lines: if(state.error, do: [[{"✗ " <> state.error, :error}]], else: []),
      popover: nil,
      context: :settings_edit,
      footer:
        [{"←→", "step"}, {"PgUp PgDn", "big step"}, {"Enter", "save"}, {"Esc", "cancel"}] ++
          if(Map.get(state.opts, :nullable, false), do: [{"Ctrl-U", "clear"}], else: [])
    }
  end
end
