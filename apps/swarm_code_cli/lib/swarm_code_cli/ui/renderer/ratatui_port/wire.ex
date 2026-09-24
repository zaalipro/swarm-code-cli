defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Wire do
  @moduledoc "Closed, bounded terminal control and response records; contains no terminal IO."
  import Bitwise
  alias SwarmCodeCLI.UI.{Input, Size}
  @max_u64 18_446_744_073_709_551_615
  @max_response 262_167
  @controls %{credit: 2, shutdown: 4, suspend: 5, resume: 6}
  @keys ~w(backspace enter left right up down home end page_up page_down tab back_tab delete insert escape null caps_lock scroll_lock num_lock print_screen pause menu keypad_begin)a
  @phases {:press, :repeat, :release}
  @mods [:shift, :control, :alt, :super, :hyper, :meta]
  @rejections {:invalid_utf8, :text_fragment_too_large, :paste_too_large}
  @errors {:protocol, :initialization, :draw, :read, :write, :restoration}
  # Init flag bits the native side accepts (alternate, focus, paste, mouse).
  @flag_mask 1 ||| 2 ||| 4 ||| 16
  @max_copy 65_536

  @doc """
  The init record. `mouse?` (pass70 B10, optional, default false) asks for
  SGR mouse reports so the wheel arrives as `{:mouse, :wheel_up | :wheel_down,
  nil, column, row, modifiers}`; it also turns off the terminal's own text
  selection, so it stays opt-in.
  """
  def init(generation, %{alternate?: alt, focus?: focus, paste?: paste} = options)
      when is_integer(generation) and generation >= 0 and generation <= @max_u64 and
             map_size(options) in [3, 4] and is_boolean(alt) and is_boolean(focus) and
             is_boolean(paste) do
    case Map.drop(options, [:alternate?, :focus?, :paste?]) do
      extra when extra == %{} or extra in [%{mouse?: true}, %{mouse?: false}] ->
        flags =
          bit(alt, 1) ||| bit(focus, 2) ||| bit(paste, 4) |||
            bit(Map.get(extra, :mouse?, false), 16)

        {:ok, <<11::32, 1, 1, generation::64, flags>>}

      _ ->
        invalid()
    end
  end

  def init(_, _), do: invalid()

  @doc """
  pass70 B10: clipboard text for OSC 52. Bounded (1..65,536 bytes of UTF-8);
  line feeds and tabs are kept, CRLF becomes LF, and any other control or
  bidirectional override is refused, so the clipboard never carries terminal
  instructions.
  """
  def copy(generation, token, text)
      when is_integer(generation) and generation >= 0 and generation <= @max_u64 and
             is_integer(token) and token >= 0 and token <= @max_u64 and is_binary(text) do
    text = String.replace(text, "\r\n", "\n")

    if byte_size(text) in 1..@max_copy and String.valid?(text) and inert?(text),
      do:
        {:ok,
         <<22 + byte_size(text)::32, 1, 7, generation::64, token::64, byte_size(text)::32,
           text::binary>>},
      else: invalid()
  end

  def copy(_, _, _), do: invalid()

  @doc """
  pass73 T9: wheel reports on or off live: `1, 8, generation, token, on`.
  The port answers nothing; it updates its flags, so the `ready` of a later
  resume reports them.
  """
  def mouse(generation, token, on?)
      when is_integer(generation) and generation >= 0 and generation <= @max_u64 and
             is_integer(token) and token >= 0 and token <= @max_u64 and is_boolean(on?),
      do: {:ok, <<19::32, 1, 8, generation::64, token::64, if(on?, do: 1, else: 0)>>}

  def mouse(_, _, _), do: invalid()

  defp inert?(text) do
    not String.match?(
      text,
      ~r/[\x{0}-\x{8}\x{b}-\x{1f}\x{7f}-\x{9f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/u
    )
  end

  def control(operation, generation, token)
      when operation in [:credit, :shutdown, :suspend, :resume] and
             is_integer(generation) and generation >= 0 and generation <= @max_u64 and
             is_integer(token) and token >= 0 and token <= @max_u64,
      do: {:ok, <<18::32, 1, Map.fetch!(@controls, operation), generation::64, token::64>>}

  def control(_, _, _), do: invalid()

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_response,
    do: record(bytes)

  def decode(_), do: invalid()

  defp record(<<1, 16, generation::64, columns::16, rows::16, flags>>)
       when columns > 0 and rows > 0 and (flags &&& bnot(@flag_mask)) == 0,
       do: {:ok, {:ready, generation, %Size{columns: columns, rows: rows}, flags}}

  defp record(<<1, 24, generation::64>>), do: {:ok, {:resume_needed, generation}}

  defp record(<<1, 18, generation::64, sequence::64, revision::64>>),
    do: {:ok, {:painted, generation, sequence, revision}}

  defp record(<<1, 23, generation::64, sequence::64, revision::64>>),
    do: {:ok, {:skipped, generation, sequence, revision}}

  defp record(<<1, 19, generation::64, token::64, state>>) when state in [0, 1],
    do: {:ok, {:restored, generation, token, if(state == 0, do: :closed, else: :suspended)}}

  defp record(<<1, 20, generation::64, token::64, columns::16, rows::16>>)
       when columns > 0 and rows > 0,
       do: input(generation, token, {:resize, %Size{columns: columns, rows: rows}})

  defp record(<<1, 21, generation::64, reason>>) when reason in 1..6,
    do: {:ok, {:error, generation, elem(@errors, reason - 1)}}

  defp record(<<1, 17, generation::64, token::64, payload::binary>>) do
    case payload(payload) do
      {:ok, event} -> input(generation, token, event)
      error -> error
    end
  end

  defp record(_), do: invalid()

  defp payload(<<0, phase, key, modifiers>>)
       when phase <= 2 and modifiers < 64 and (key <= 22 or key in 32..43) do
    key = if key <= 22, do: Enum.at(@keys, key), else: {:function, key - 31}
    {:ok, {:key, elem(@phases, phase), key, modifiers(modifiers)}}
  end

  defp payload(<<1, phase, modifiers, length::16, text::binary-size(length)>>)
       when phase <= 2 and modifiers < 64 and length in 1..4096,
       do: {:ok, {:text_fragment, elem(@phases, phase), text, modifiers(modifiers)}}

  defp payload(<<2, length::32, text::binary-size(length)>>) when length <= 262_144,
    do: {:ok, {:paste, text}}

  defp payload(<<3, rejection>>) when rejection <= 2,
    do: {:ok, {:rejected, elem(@rejections, rejection)}}

  defp payload(<<6, direction, modifiers, column::16, row::16>>)
       when direction in [0, 1] and modifiers < 64 do
    kind = if direction == 0, do: :wheel_up, else: :wheel_down
    {:ok, {:mouse, kind, nil, column, row, modifiers(modifiers)}}
  end

  defp payload(<<4>>), do: {:ok, :focus_gained}
  defp payload(<<5>>), do: {:ok, :focus_lost}
  defp payload(_), do: invalid()

  defp input(generation, token, event) do
    case Input.validate(event) do
      {:ok, event} -> {:ok, {:input, generation, token, event}}
      _ -> invalid()
    end
  end

  defp modifiers(bits),
    do: for({modifier, i} <- Enum.with_index(@mods), (bits &&& 1 <<< i) != 0, do: modifier)

  defp bit(true, bit), do: bit
  defp bit(false, _), do: 0
  defp invalid, do: {:error, :invalid_record}
end
