defmodule SwarmCodeCLI.Plain.Lexer do
  @moduledoc false
  @maximum_line 16_384
  def words(line) when is_binary(line) and byte_size(line) <= @maximum_line + 2 do
    line =
      cond do
        String.ends_with?(line, "\r\n") -> binary_part(line, 0, byte_size(line) - 2)
        String.ends_with?(line, "\n") -> binary_part(line, 0, byte_size(line) - 1)
        true -> line
      end

    if byte_size(line) <= @maximum_line and String.valid?(line) and
         :binary.match(line, [<<0>>, "\r", "\n"]) == :nomatch do
      scan(line, [])
    else
      {:error, :invalid_line}
    end
  end

  def words(_), do: {:error, :invalid_line}
  defp scan(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp scan(<<c, rest::binary>>, acc) when c in [32, 9], do: scan(rest, acc)
  defp scan(_, acc) when length(acc) >= 64, do: {:error, :too_many_arguments}

  defp scan(<<quote, rest::binary>>, acc) when quote in [?', ?"] do
    with {:ok, word, tail} <- quoted(rest, quote, [], 0),
         true <- tail == "" or binary_part(tail, 0, 1) in [" ", "\t"] do
      scan(tail, [word | acc])
    else
      _ -> {:error, :invalid_quote}
    end
  end

  defp scan(line, acc) do
    with {:ok, word, rest} <- bare(line, [], 0), do: scan(rest, [word | acc])
  end

  defp bare(<<>>, acc, _), do: finish_bare(acc, "")
  defp bare(<<c, _::binary>> = tail, acc, _) when c in [32, 9], do: finish_bare(acc, tail)
  defp bare(<<c, _::binary>>, _, _) when c in [?', ?", ?\\], do: {:error, :invalid_word}

  defp bare(<<c, rest::binary>>, acc, bytes) when bytes < 4096,
    do: bare(rest, [<<c>> | acc], bytes + 1)

  defp bare(_, _, _), do: {:error, :argument_too_large}
  defp quoted(<<quote, rest::binary>>, quote, acc, _), do: finish(acc, rest)

  defp quoted(<<?\\, escaped, rest::binary>>, ?", acc, bytes)
       when escaped in [?\\, ?", ?n, ?t] and bytes < 4096 do
    value =
      case escaped do
        ?n -> "\n"
        ?t -> "\t"
        c -> <<c>>
      end

    quoted(rest, ?", [value | acc], bytes + 1)
  end

  defp quoted(<<?\\, _::binary>>, ?", _, _), do: {:error, :invalid_escape}

  defp quoted(<<c, rest::binary>>, quote, acc, bytes) when bytes < 4096,
    do: quoted(rest, quote, [<<c>> | acc], bytes + 1)

  defp quoted(_, _, _, _), do: {:error, :invalid_quote}

  defp finish_bare(acc, rest) do
    {:ok, word, rest} = finish(acc, rest)
    if Regex.match?(~r/\s/u, word), do: {:error, :invalid_word}, else: {:ok, word, rest}
  end

  defp finish(acc, rest), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
end
