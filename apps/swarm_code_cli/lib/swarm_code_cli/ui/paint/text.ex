defmodule SwarmCodeCLI.UI.Paint.Text do
  @moduledoc """
  Bounded wrapping of already-visible SafeText runs, retaining first-contributor ownership.

  Only the visible prefix is segmented. Run envelopes and aggregate bytes are checked
  before shaping; selected graphemes are checked for UTF-8 and terminal controls.
  Callers supply SafeText.value/1 output, not unsanitized external strings.
  """
  alias SwarmCodeCLI.UI.Width
  alias SwarmCodeCLI.UI.Paint.{Cell, Style}
  @max_bytes 4 * 1024 * 1024
  @max_unit_bytes 262_144
  @type run :: %{text: binary(), style: Style.entry(), action_id: binary() | nil}
  @type unit :: %{
          text: binary(),
          width: pos_integer(),
          style: Style.entry(),
          action_id: binary() | nil
        }
  @type line :: %{units: [unit()], cells: non_neg_integer()}

  @spec lines([run()], non_neg_integer(), :narrow | :wide, non_neg_integer()) ::
          {:ok, [line()]} | {:error, :invalid_text | :capacity_exceeded}
  def lines(runs, width, policy, max_rows)
      when is_integer(width) and width >= 0 and is_integer(max_rows) and max_rows >= 0 and
             policy in [:narrow, :wide] do
    cond do
      width > 500 or max_rows > 200 ->
        {:error, :capacity_exceeded}

      true ->
        with :ok <- envelope(runs, 0, 0) do
          if width == 0 or max_rows == 0 do
            {:ok, []}
          else
            wrap(runs, width, policy, max_rows, [], "", 0, [], false)
          end
        end
    end
  rescue
    _ -> {:error, :invalid_text}
  end

  def lines(_, _, _, _), do: {:error, :invalid_text}

  defp envelope([], _, _), do: :ok
  defp envelope([_ | _], 4096, _), do: {:error, :capacity_exceeded}

  defp envelope([%{text: text, style: style, action_id: action} = run | rest], count, bytes)
       when is_binary(text) do
    cond do
      bytes + byte_size(text) > @max_bytes ->
        {:error, :capacity_exceeded}

      is_struct(run) or map_size(run) != 3 or not Style.entry?(style) or
          not (is_nil(action) or Cell.id?(action)) ->
        {:error, :invalid_text}

      true ->
        envelope(rest, count + 1, bytes + byte_size(text))
    end
  end

  defp envelope(_, _, _), do: {:error, :invalid_text}

  defp wrap(_runs, _width, _policy, 0, _units, _text, _cells, acc, _line_open),
    do: {:ok, Enum.reverse(acc)}

  defp wrap(runs, width, policy, rows, units, text, cells, acc, line_open) do
    case next(runs) do
      :eof ->
        result = if line_open, do: [line(units, cells) | acc], else: acc
        {:ok, Enum.reverse(result)}

      {:error, _} = error ->
        error

      {:ok, grapheme, owner, rest} ->
        cond do
          grapheme in ["\n", "\r\n"] ->
            wrap(rest, width, policy, rows - 1, [], "", 0, [line(units, cells) | acc], true)

          not printable?(grapheme) ->
            {:error, :invalid_text}

          true ->
            {grapheme, rest} =
              if Width.cells(text <> grapheme, policy) > width,
                do: complete_context(grapheme, rest, policy),
                else: {grapheme, rest}

            place(grapheme, owner, rest, width, policy, rows, units, text, cells, acc)
        end
    end
  end

  defp place(grapheme, owner, rest, width, policy, rows, units, text, cells, acc) do
    candidate = text <> grapheme
    occupied = Width.cells(candidate, policy)

    cond do
      byte_size(grapheme) > @max_unit_bytes ->
        {:error, :capacity_exceeded}

      occupied == 0 ->
        {:error, :invalid_text}

      occupied <= width ->
        unit = %{
          text: grapheme,
          width: Width.cells(grapheme, policy),
          style: owner.style,
          action_id: owner.action_id
        }

        case append(units, unit, cells, occupied, policy) do
          {:ok, updated} ->
            wrap(rest, width, policy, rows, updated, candidate, occupied, acc, true)

          error ->
            error
        end

      units == [] ->
        wrap(rest, width, policy, rows - 1, [], "", 0, [line([], 0) | acc], false)

      rows == 1 ->
        {:ok, Enum.reverse([line(units, cells) | acc])}

      true ->
        # Reuse the selected grapheme. Re-segmenting a suffix changes RI pairs.
        place(grapheme, owner, rest, width, policy, rows - 1, [], "", 0, [
          line(units, cells) | acc
        ])
    end
  end

  # Some ligatures have an intermediate grapheme wider than their completed
  # unit (Tifinagh consonant + joiner + consonant). Check the following complete
  # cluster before declaring that intermediate prefix clipped.
  defp complete_context(grapheme, rest, policy) do
    case next(rest) do
      {:ok, following, _owner, tail} ->
        combined = grapheme <> following

        if printable?(following) and Width.cells(combined, policy) > 0 and
             Width.cells(combined, policy) <
               Width.cells(grapheme, policy) + Width.cells(following, policy),
           do: {combined, tail},
           else: {grapheme, rest}

      _ ->
        {grapheme, rest}
    end
  end

  defp line(units, cells), do: %{units: Enum.reverse(units), cells: cells}

  # If width is contextual, merge the shortest suffix that accounts for it.
  # The first contributor of that suffix owns its resulting glyph and action.
  defp append(units, unit, cells, occupied, policy) do
    if unit.width > 0 and cells + unit.width == occupied do
      {:ok, [unit | units]}
    else
      merge(units, unit, cells, occupied, policy)
    end
  end

  defp merge([previous | rest], unit, cells, occupied, policy) do
    text = previous.text <> unit.text
    width = Width.cells(text, policy)
    merged = %{previous | text: text, width: width}

    cond do
      byte_size(text) > @max_unit_bytes -> {:error, :capacity_exceeded}
      width > 0 and cells - previous.width + width == occupied -> {:ok, [merged | rest]}
      true -> merge(rest, merged, cells - previous.width, occupied, policy)
    end
  end

  defp merge([], _, _, _, _), do: {:error, :invalid_text}

  defp next([]), do: :eof
  defp next([%{text: ""} | rest]), do: next(rest)

  defp next([%{text: text} = owner | rest]) do
    case first(text) do
      {:ok, grapheme, ""} -> extend(grapheme, owner, rest)
      {:ok, grapheme, tail} -> {:ok, grapheme, owner, [%{owner | text: tail} | rest]}
      error -> error
    end
  end

  # Probe only the first cluster of the next run at a span boundary. If RI
  # pairing consumes part of it, retain its already-selected leftover separately.
  defp extend(grapheme, owner, [%{text: ""} | rest]), do: extend(grapheme, owner, rest)
  defp extend(grapheme, owner, []), do: {:ok, grapheme, owner, []}

  defp extend(grapheme, owner, [%{text: text} = next_owner | rest] = runs) do
    with {:ok, following, tail} <- first(text) do
      {combined, remaining} = String.next_grapheme(grapheme <> following)

      cond do
        combined == grapheme ->
          {:ok, grapheme, owner, runs}

        byte_size(combined) > @max_unit_bytes ->
          {:error, :capacity_exceeded}

        remaining != "" ->
          {:ok, combined, owner,
           [%{next_owner | text: remaining}, %{next_owner | text: tail} | rest]}

        tail != "" ->
          {:ok, combined, owner, [%{next_owner | text: tail} | rest]}

        true ->
          extend(combined, owner, rest)
      end
    end
  end

  defp first(text) do
    # A giant first combining sequence cannot make the scanner traverse 4 MiB.
    sample = binary_part(text, 0, min(byte_size(text), @max_unit_bytes + 4))
    {grapheme, _} = String.next_grapheme(sample)
    bytes = byte_size(grapheme)

    if bytes > @max_unit_bytes,
      do: {:error, :capacity_exceeded},
      else: {:ok, grapheme, binary_part(text, bytes, byte_size(text) - bytes)}
  end

  defp printable?(<<>>), do: true

  defp printable?(<<cp::utf8, rest::binary>>) when cp >= 32 and cp not in 127..159,
    do: printable?(rest)

  defp printable?(_), do: false
end
