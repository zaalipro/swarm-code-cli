defmodule SwarmCode.Daemon.Service.Settings.Layers do
  @moduledoc """
  Builds the provenance of a setting (pass 74, spec §3.3.3, D40): one layer
  map per layer of the entry, the winner (the first layer in the entry's
  order that is set and not ignored), the base (the home layer's stored value,
  the compare-and-set token) and the invalid state of a stored value this CLI
  does not understand (D34).
  """

  alias SwarmCode.Settings.{Entry, WireValue}

  @raw_bytes 200
  @note_chars 40

  @doc "A layer map."
  @spec layer(atom(), term(), keyword()) :: map()
  def layer(name, value, opts \\ []) do
    %{
      "layer" => Atom.to_string(name),
      "value" => WireValue.canonical(value),
      "set" => Keyword.get(opts, :set, true),
      "ignored" => false,
      "raw" => nil,
      "source" => Keyword.get(opts, :source),
      "note" => Keyword.get(opts, :note)
    }
  end

  @doc "A layer the runtime does not honour: shown, never the winner (D40)."
  @spec ignored(atom(), term(), String.t(), keyword()) :: map()
  def ignored(name, raw, note, opts \\ []) do
    %{
      "layer" => Atom.to_string(name),
      "value" => nil,
      "set" => true,
      "ignored" => true,
      "raw" => raw_text(raw),
      "source" => Keyword.get(opts, :source),
      "note" => note
    }
  end

  @doc "A layer holding a stored value that fails the entry's type (D34)."
  @spec invalid(atom(), term(), keyword()) :: map()
  def invalid(name, raw, opts \\ []) do
    %{
      "layer" => Atom.to_string(name),
      "value" => nil,
      "set" => true,
      "ignored" => false,
      "raw" => raw_text(raw),
      "source" => Keyword.get(opts, :source),
      "note" => nil
    }
  end

  @doc "An unset layer."
  @spec unset(atom()) :: map()
  def unset(name), do: layer(name, nil, set: false)

  @doc """
  The SettingValue of an entry from its layer maps (in the entry's order).
  `opts`: `:base` (the home layer's stored value; defaults to its layer
  value), `:invalid_raw` (the raw stored value when it failed the type),
  `:choices`, `:state`, `:note`.
  """
  @spec setting_value(Entry.t(), [map()], keyword()) :: map()
  def setting_value(%Entry{} = entry, layers, opts \\ []) do
    winner = Enum.find(layers, &(&1["set"] and not &1["ignored"]))
    invalid? = Keyword.has_key?(opts, :invalid_raw)

    {value, state, note} =
      cond do
        invalid? and winner != nil and winner["layer"] == Atom.to_string(entry.home) ->
          {nil, "invalid", invalid_note(Keyword.fetch!(opts, :invalid_raw))}

        true ->
          {winner && winner["value"], Keyword.get(opts, :state, "ok"), Keyword.get(opts, :note)}
      end

    home_layer = Enum.find(layers, &(&1["layer"] == Atom.to_string(entry.home || :default)))

    base =
      cond do
        Keyword.has_key?(opts, :base) -> WireValue.canonical(Keyword.fetch!(opts, :base))
        invalid? -> WireValue.canonical(Keyword.fetch!(opts, :invalid_raw))
        home_layer -> home_layer["value"]
        true -> nil
      end

    %{
      "key" => entry.key,
      "value" => value,
      "layers" => layers,
      "winner" => winner && winner["layer"],
      "writable" => if(Entry.writable?(entry), do: [Atom.to_string(entry.home)], else: []),
      "base" => base,
      "choices" => Keyword.get(opts, :choices),
      "state" => state,
      "note" => note
    }
  end

  @doc "The note of an invalid stored value (≤ 40 characters of its JSON)."
  @spec invalid_note(term()) :: String.t()
  def invalid_note(raw) do
    shown = raw |> json_text() |> String.slice(0, @note_chars)
    "the stored value #{shown} is not valid here; choose a new one"
  end

  @doc "A bounded display form of a raw stored value (≤ 200 bytes)."
  @spec raw_text(term()) :: String.t()
  def raw_text(raw) do
    text = if is_binary(raw), do: raw, else: json_text(raw)
    cut(text, @raw_bytes)
  end

  defp json_text(raw) do
    case Jason.encode(WireValue.canonical(raw)) do
      {:ok, text} -> text
      {:error, _} -> inspect(raw, limit: 5, printable_limit: 40)
    end
  end

  defp cut(text, bytes) when byte_size(text) <= bytes, do: text

  defp cut(text, bytes) do
    text
    |> binary_part(0, bytes)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end
end
