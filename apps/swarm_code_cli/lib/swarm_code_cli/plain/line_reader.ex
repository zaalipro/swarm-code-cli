defmodule SwarmCodeCLI.Plain.LineReader do
  @moduledoc "Demand-driven, byte-bounded Unicode physical-line reader. Only its owner requests another line."
  @limit 16_384

  def start(owner, device) do
    :erlang.spawn_opt(fn -> loop(owner, device, false) end, [:link, :monitor])
  end

  defp loop(owner, device, draining) do
    receive do
      :read_next ->
        {result, draining} = if draining, do: drain(device), else: read(device, [], 0)
        send(owner, {:plain_input, self(), result})
        if result != :eof, do: loop(owner, device, draining)
    end
  end

  defp read(device, reversed, bytes) do
    case character(device) do
      :eof when bytes == 0 ->
        {:eof, false}

      :eof ->
        finish_line(reversed)

      "\n" ->
        finish_line(["\n" | reversed])

      character when is_binary(character) ->
        if bytes + byte_size(character) > @limit + 1 do
          {{:error, :line_too_large}, true}
        else
          read(device, [character | reversed], bytes + byte_size(character))
        end

      _ ->
        {{:error, :input_failed}, false}
    end
  end

  defp finish_line(reversed) do
    line = IO.iodata_to_binary(Enum.reverse(reversed))
    bytes = byte_size(line)

    delimiter =
      cond do
        String.ends_with?(line, "\r\n") -> 2
        String.ends_with?(line, "\n") -> 1
        true -> 0
      end

    if bytes - delimiter <= @limit,
      do: {{:line, line}, false},
      else: {{:error, :line_too_large}, false}
  end

  defp character(device) do
    case :io.get_chars(device, "", 1) do
      chars when is_list(chars) -> :unicode.characters_to_binary(chars)
      value -> value
    end
  rescue
    _ -> {:error, :input_failed}
  catch
    :exit, _ -> {:error, :input_failed}
  end

  defp drain(device) do
    case character(device) do
      :eof -> {:eof, false}
      "\n" -> read(device, [], 0)
      char when is_binary(char) -> drain(device)
      _ -> {{:error, :input_failed}, false}
    end
  end
end
