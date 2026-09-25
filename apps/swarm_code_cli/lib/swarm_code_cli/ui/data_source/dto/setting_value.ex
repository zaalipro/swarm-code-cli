defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingValue do
  @moduledoc """
  pass74 §3.3.3 / §3.4.6: one scalar setting as the service resolved it — the
  effective `value`, every `layer` (`%{layer, value, set, ignored, raw, source,
  note}`, in the entry's layer order), the `winner`, the `writable` layers, the
  `base` (the home layer's stored wire value: the CAS token), dynamic `choices`
  (`%{value, label, hint}`), `state` (`:ok`, `:invalid`, `:attention`) and `note`.

  Decoding (rule 1): a key that is not a registry scalar is dropped (logged by key
  only); a value or layer value that fails `WireValue.type_ok?/2` makes this value
  `:invalid` with `value: nil` — the rest of the snapshot is kept.
  """
  require Logger

  alias SwarmCode.Settings.{Entry, Registry, WireValue}
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  @states %{"ok" => :ok, "invalid" => :invalid, "attention" => :attention}

  defstruct key: nil,
            value: nil,
            layers: [],
            winner: nil,
            writable: [],
            base: nil,
            choices: nil,
            state: :ok,
            note: nil

  @type layer :: %{
          layer: atom(),
          value: term(),
          set: boolean(),
          ignored: boolean(),
          raw: String.t() | nil,
          source: String.t() | nil,
          note: String.t() | nil
        }
  @type t :: %__MODULE__{
          key: String.t(),
          value: term(),
          layers: [layer()],
          winner: atom() | nil,
          writable: [atom()],
          base: term(),
          choices: [%{value: term(), label: String.t(), hint: String.t() | nil}] | nil,
          state: :ok | :invalid | :attention,
          note: String.t() | nil
        }

  @doc "Decode one SettingValue; `{:ok, :drop}` for a key this client does not know."
  @spec decode(term()) :: {:ok, t() | :drop} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    key = SettingsDecode.text!(SettingsDecode.fetch!(wire, "key"), 64, :setting_key)

    case Registry.fetch(key) do
      {:ok, %Entry{} = entry} ->
        if Entry.scalar?(entry), do: decode_entry!(entry, wire), else: drop(key)

      _ ->
        drop(key)
    end
  end

  defp drop(key) do
    Logger.warning("settings value dropped: unknown key #{SettingsDecode.safe_name(key)}")
    :drop
  end

  defp decode_entry!(entry, wire) do
    layers =
      wire
      |> SettingsDecode.fetch!("layers")
      |> SettingsDecode.list!(8, :layers)
      |> Enum.map(&layer!(entry, &1))

    state = SettingsDecode.enum!(SettingsDecode.fetch!(wire, "state"), @states, :state)
    value = entry |> WireValue.normalize(SettingsDecode.fetch!(wire, "value"))
    SettingsDecode.json!(value, 65_536, :value)
    typed? = state != :invalid and WireValue.type_ok?(entry, value)
    layers_ok? = Enum.all?(layers, &(&1 != :invalid))

    {state, value} =
      cond do
        state == :invalid -> {:invalid, nil}
        typed? and layers_ok? -> {state, value}
        true -> {:invalid, nil}
      end

    %__MODULE__{
      key: entry.key,
      value: value,
      layers: Enum.map(layers, &clean_layer/1),
      winner: winner!(SettingsDecode.fetch!(wire, "winner")),
      writable:
        wire
        |> SettingsDecode.fetch!("writable")
        |> SettingsDecode.list!(8, :writable)
        |> Enum.map(&SettingsDecode.layer!/1),
      base: SettingsDecode.json!(SettingsDecode.fetch!(wire, "base"), 65_536, :base),
      choices: choices!(SettingsDecode.fetch!(wire, "choices")),
      state: state,
      note: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "note"), 2_048, :note)
    }
  end

  defp layer!(entry, wire) do
    SettingsDecode.map!(wire, 16, :layer)
    set = SettingsDecode.bool!(SettingsDecode.fetch!(wire, "set"), :layer_set)
    ignored = SettingsDecode.bool!(Map.get(wire, "ignored", false), :layer_ignored)
    value = WireValue.normalize(entry, SettingsDecode.fetch!(wire, "value"))
    SettingsDecode.json!(value, 65_536, :layer_value)

    layer = %{
      layer: SettingsDecode.layer!(SettingsDecode.fetch!(wire, "layer")),
      value: value,
      set: set,
      ignored: ignored,
      raw: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "raw"), 1_024, :layer_raw),
      source: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "source"), 256, :source),
      note: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "note"), 2_048, :layer_note)
    }

    # A set, honoured layer whose value is outside the entry's type: the value
    # is not shown as a value (it stays readable as `raw`).
    if set and not ignored and value != nil and not WireValue.type_ok?(entry, value),
      do: {:invalid, %{layer | value: nil, raw: layer.raw || raw_text(value)}},
      else: layer
  end

  defp clean_layer({:invalid, layer}), do: layer
  defp clean_layer(layer), do: layer

  defp raw_text(value) do
    case Jason.encode(value) do
      {:ok, text} -> String.slice(text, 0, 100)
      _ -> nil
    end
  end

  defp winner!(nil), do: nil
  defp winner!(name), do: SettingsDecode.layer!(name)

  defp choices!(nil), do: nil

  defp choices!(choices) do
    choices
    |> SettingsDecode.list!(400, :choices)
    |> Enum.map(fn choice ->
      %{
        value: SettingsDecode.json!(SettingsDecode.fetch!(choice, "value"), 1_024, :choice),
        label: SettingsDecode.text!(SettingsDecode.fetch!(choice, "label"), 400, :choice_label),
        hint: SettingsDecode.opt_text!(Map.get(choice, "hint"), 400, :choice_hint)
      }
    end)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{key: key, layers: layers, writable: writable, state: state} = value)
      when is_binary(key) and is_list(layers) and is_list(writable) and
             state in [:ok, :invalid, :attention],
      do: {:ok, value}

  def validate(_value), do: {:error, :invalid_dto}
end
