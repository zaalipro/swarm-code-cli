defmodule SwarmCode.Protocol.JsonLimits do
  @moduledoc """
  Bounded JSON admission for protocol frames.

  The lexical pass is intentionally conservative: container openings and the
  punctuation which separates object/array members are counted before Jason is
  called.  The decoded value is then counted exactly as a second, independent
  guard.
  """

  alias SwarmCode.Protocol.Error

  @default_max_bytes 1_048_576
  @default_max_depth 16
  @default_max_entries 8_192

  @typedoc false
  @type options :: [
          {:max_bytes, non_neg_integer()}
          | {:max_depth, non_neg_integer()}
          | {:max_entries, non_neg_integer()}
        ]

  @doc "Decode one bounded JSON value, rejecting duplicate object keys."
  @spec decode(binary(), options()) :: {:ok, term()} | {:error, Error.t()}
  def decode(binary, opts \\ [])

  def decode(binary, opts) when is_binary(binary) do
    with {:ok, limits} <- normalize_options(opts),
         :ok <- check_size(binary, limits.max_bytes),
         :ok <- preflight(binary, limits.max_depth, limits.max_entries),
         {:ok, ordered} <- decode_ordered(binary),
         {:ok, value, _count} <- convert_and_count(ordered, limits.max_entries) do
      {:ok, value}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, :invalid_json} -> {:error, Error.new(:invalid_json)}
      {:error, :json_entry_limit} -> {:error, Error.new(:json_entry_limit)}
      _other -> {:error, Error.new(:invalid_json)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_json)}
  catch
    _kind, _reason -> {:error, Error.new(:invalid_json)}
  end

  def decode(_input, _opts), do: {:error, Error.new(:invalid_json)}

  @doc "Validate bounded JSON and discard the decoded value."
  @spec validate(binary(), options()) :: :ok | {:error, Error.t()}
  def validate(binary, opts \\ []) do
    case decode(binary, opts) do
      {:ok, _value} -> :ok
      {:error, %Error{} = error} -> {:error, error}
      _other -> {:error, Error.new(:invalid_json)}
    end
  end

  defp normalize_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      defaults = %{
        max_bytes: @default_max_bytes,
        max_depth: @default_max_depth,
        max_entries: @default_max_entries
      }

      Enum.reduce_while(opts, {:ok, defaults}, fn
        {:max_bytes, value}, {:ok, acc} ->
          update_limit(acc, :max_bytes, value)

        {:max_depth, value}, {:ok, acc} ->
          update_limit(acc, :max_depth, value)

        {:max_entries, value}, {:ok, acc} ->
          update_limit(acc, :max_entries, value)

        _unknown, _acc ->
          {:halt, {:error, Error.new(:invalid_json)}}
      end)
    else
      {:error, Error.new(:invalid_json)}
    end
  rescue
    _exception -> {:error, Error.new(:invalid_json)}
  end

  defp normalize_options(_opts), do: {:error, Error.new(:invalid_json)}

  defp update_limit(_acc, _key, value) when not is_integer(value) or value < 0,
    do: {:halt, {:error, Error.new(:invalid_json)}}

  defp update_limit(acc, key, value), do: {:cont, {:ok, Map.put(acc, key, value)}}

  defp check_size(binary, max_bytes) when byte_size(binary) <= max_bytes, do: :ok
  defp check_size(_binary, _max_bytes), do: {:error, Error.new(:json_too_large)}

  defp preflight(binary, max_depth, max_entries) do
    scan(binary, 0, byte_size(binary), false, false, 0, [], 0, max_depth, max_entries)
  end

  defp scan(_binary, index, size, false, _escaped, 0, [], _entries, _max_depth, _max_entries)
       when index == size,
       do: :ok

  defp scan(
         _binary,
         index,
         size,
         true,
         _escaped,
         _depth,
         _stack,
         _entries,
         _max_depth,
         _max_entries
       )
       when index == size,
       do: {:error, Error.new(:invalid_json)}

  defp scan(
         _binary,
         index,
         size,
         false,
         _escaped,
         _depth,
         _stack,
         _entries,
         _max_depth,
         _max_entries
       )
       when index == size,
       do: {:error, Error.new(:invalid_json)}

  defp scan(binary, index, size, true, true, depth, stack, entries, max_depth, max_entries) do
    # Any byte after a backslash is consumed as an escaped byte here.  Jason is
    # responsible for deciding whether the escape itself is a legal JSON
    # escape; this pass only keeps punctuation inside strings inert.
    scan(binary, index + 1, size, true, false, depth, stack, entries, max_depth, max_entries)
  end

  defp scan(binary, index, size, true, false, depth, stack, entries, max_depth, max_entries) do
    byte = :binary.at(binary, index)

    cond do
      byte == ?\\ ->
        scan(binary, index + 1, size, true, true, depth, stack, entries, max_depth, max_entries)

      byte == ?" ->
        scan(binary, index + 1, size, false, false, depth, stack, entries, max_depth, max_entries)

      byte < 0x20 ->
        {:error, Error.new(:invalid_json)}

      true ->
        scan(binary, index + 1, size, true, false, depth, stack, entries, max_depth, max_entries)
    end
  end

  defp scan(binary, index, size, false, false, depth, stack, entries, max_depth, max_entries) do
    byte = :binary.at(binary, index)

    case byte do
      ?" ->
        scan(binary, index + 1, size, true, false, depth, stack, entries, max_depth, max_entries)

      ?{ ->
        open_container(binary, index, size, depth, stack, entries, max_depth, max_entries, ?})

      ?[ ->
        open_container(binary, index, size, depth, stack, entries, max_depth, max_entries, ?])

      ?} ->
        close_container(binary, index, size, depth, stack, entries, max_depth, max_entries, ?})

      ?] ->
        close_container(binary, index, size, depth, stack, entries, max_depth, max_entries, ?])

      ?, ->
        increment_entry(binary, index, size, depth, stack, entries, max_depth, max_entries)

      ?: ->
        increment_entry(binary, index, size, depth, stack, entries, max_depth, max_entries)

      _other ->
        scan(binary, index + 1, size, false, false, depth, stack, entries, max_depth, max_entries)
    end
  end

  defp open_container(binary, index, size, depth, stack, entries, max_depth, max_entries, closer) do
    cond do
      depth + 1 > max_depth ->
        {:error, Error.new(:json_too_deep)}

      entries + 1 > max_entries ->
        {:error, Error.new(:json_entry_limit)}

      true ->
        scan(
          binary,
          index + 1,
          size,
          false,
          false,
          depth + 1,
          [closer | stack],
          entries + 1,
          max_depth,
          max_entries
        )
    end
  end

  defp close_container(
         binary,
         index,
         size,
         depth,
         [expected | rest],
         entries,
         max_depth,
         max_entries,
         byte
       )
       when expected == byte do
    scan(binary, index + 1, size, false, false, depth - 1, rest, entries, max_depth, max_entries)
  end

  defp close_container(
         _binary,
         _index,
         _size,
         _depth,
         _stack,
         _entries,
         _max_depth,
         _max_entries,
         _byte
       ),
       do: {:error, Error.new(:invalid_json)}

  defp increment_entry(binary, index, size, depth, stack, entries, max_depth, max_entries) do
    if entries + 1 > max_entries do
      {:error, Error.new(:json_entry_limit)}
    else
      scan(
        binary,
        index + 1,
        size,
        false,
        false,
        depth,
        stack,
        entries + 1,
        max_depth,
        max_entries
      )
    end
  end

  defp decode_ordered(binary) do
    case Jason.decode(binary, keys: :strings, strings: :copy, objects: :ordered_objects) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> {:error, :invalid_json}
      _other -> {:error, :invalid_json}
    end
  rescue
    _exception -> {:error, :invalid_json}
  catch
    _kind, _reason -> {:error, :invalid_json}
  end

  defp convert_and_count(value, max_entries), do: convert(value, max_entries)

  defp convert(%Jason.OrderedObject{values: pairs}, max_entries) when is_list(pairs) do
    convert_object(pairs, %{}, 0, max_entries)
  end

  defp convert(value, max_entries) when is_map(value) do
    # Jason's ordered decoder should make this clause unreachable.  Keeping it
    # defensive ensures an unexpected decoder value is rejected without ever
    # trusting non-binary keys.
    pairs = Map.to_list(value)
    convert_object(pairs, %{}, 0, max_entries)
  rescue
    _exception -> {:error, :invalid_json}
  end

  # Keep the copy guarantee explicit for both values and keys.  Jason's
  # `strings: :copy` handles values; copying here also keeps this invariant if
  # the decoder implementation ever changes its string policy.
  defp convert(value, _max_entries) when is_binary(value), do: {:ok, :binary.copy(value), 0}
  defp convert(value, _max_entries) when is_integer(value), do: {:ok, value, 0}

  defp convert(value, _max_entries) when is_float(value) do
    if finite_float?(value), do: {:ok, value, 0}, else: {:error, :invalid_json}
  end

  defp convert(value, _max_entries) when value in [nil, true, false], do: {:ok, value, 0}

  defp convert(value, max_entries) when is_list(value) do
    convert_list(value, [], 0, max_entries)
  end

  defp convert(_value, _max_entries), do: {:error, :invalid_json}

  defp convert_object([], map, count, _max_entries), do: {:ok, map, count}

  defp convert_object([{key, value} | rest], map, count, max_entries)
       when is_binary(key) do
    key = :binary.copy(key)

    if Map.has_key?(map, key) do
      {:error, :invalid_json}
    else
      with {:ok, converted, child_count} <- convert(value, max_entries),
           {:ok, next_count} <- add_count(count, child_count + 1, max_entries) do
        convert_object(rest, Map.put(map, key, converted), next_count, max_entries)
      end
    end
  end

  defp convert_object(_pairs, _map, _count, _max_entries), do: {:error, :invalid_json}

  defp convert_list([], acc, count, _max_entries), do: {:ok, Enum.reverse(acc), count}

  defp convert_list([value | rest], acc, count, max_entries) do
    with {:ok, converted, child_count} <- convert(value, max_entries),
         {:ok, next_count} <- add_count(count, child_count + 1, max_entries) do
      convert_list(rest, [converted | acc], next_count, max_entries)
    end
  end

  defp convert_list(_improper, _acc, _count, _max_entries), do: {:error, :invalid_json}

  defp add_count(count, addition, max_entries) when count + addition <= max_entries,
    do: {:ok, count + addition}

  defp add_count(_count, _addition, _max_entries), do: {:error, :json_entry_limit}

  defp finite_float?(value) do
    <<_sign::1, exponent::11, _fraction::52>> = <<value::float-64>>
    exponent != 0x7FF
  end
end
