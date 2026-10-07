defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Wire do
  @moduledoc "Closed, bounded terminal control and response records; contains no terminal IO."
  import Bitwise
  alias SwarmCodeCLI.UI.{Input, Size}
  @max_u64 18_446_744_073_709_551_615
  @max_response 262_167
  @controls %{credit: 2, shutdown: 4, suspend: 5, resume: 6, redraw: 10}
  @keys ~w(backspace enter left right up down home end page_up page_down tab back_tab delete insert escape null caps_lock scroll_lock num_lock print_screen pause menu keypad_begin)a
  @phases {:press, :repeat, :release}
  @mods [:shift, :control, :alt, :super, :hyper, :meta]
  @rejections {:invalid_utf8, :text_fragment_too_large, :paste_too_large}
  @errors {:protocol, :initialization, :draw, :read, :write, :restoration}
  # Init flag bits the native side accepts (alternate, focus, paste, mouse).
  @flag_mask 1 ||| 2 ||| 4 ||| 16
  # cli020 D2: Ready (only) may add "enhanced keys are on".
  @ready_enhanced_keys 128
  @max_copy 65_536
  # cli020 D3: the longest Notify text.
  @max_notify 512
  @notify_kinds %{bell: 0, notification: 1, title: 2}

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

  @doc """
  cli020 D3: a bell, an OSC 9 notification or an OSC 2 title:
  `1, 9, generation, token, kind:u8, length:u16, text`. The text is at most
  512 bytes of UTF-8 with no C0 or C1 control (the port refuses one as a
  protocol error, so it is checked here first), and a notification may not
  start with a digit (ConEmu's `OSC 9;<n>` progress sequences).
  """
  def notify(generation, token, kind, text)
      when is_integer(generation) and generation >= 0 and generation <= @max_u64 and
             is_integer(token) and token >= 0 and token <= @max_u64 and
             is_map_key(@notify_kinds, kind) and is_binary(text) do
    if notify_text?(kind, text) do
      code = Map.fetch!(@notify_kinds, kind)
      length = byte_size(text)
      {:ok, <<21 + length::32, 1, 9, generation::64, token::64, code, length::16, text::binary>>}
    else
      invalid()
    end
  end

  def notify(_, _, _, _), do: invalid()

  @doc "cli020 D3: whether `text` may travel in a Notify of `kind`."
  def notify_text?(kind, text) when is_binary(text) do
    byte_size(text) <= @max_notify and String.valid?(text) and
      not String.match?(text, ~r/[\x{0}-\x{1f}\x{7f}-\x{9f}]/u) and
      not (kind == :notification and String.match?(text, ~r/\A[0-9]/))
  end

  def notify_text?(_kind, _text), do: false

  defp inert?(text) do
    not String.match?(
      text,
      ~r/[\x{0}-\x{8}\x{b}-\x{1f}\x{7f}-\x{9f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/u
    )
  end

  def control(operation, generation, token)
      when operation in [:credit, :shutdown, :suspend, :resume, :redraw] and
             is_integer(generation) and generation >= 0 and generation <= @max_u64 and
             is_integer(token) and token >= 0 and token <= @max_u64,
      do: {:ok, <<18::32, 1, Map.fetch!(@controls, operation), generation::64, token::64>>}

  def control(_, _, _), do: invalid()

  def decode(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_response,
    do: record(bytes)

  def decode(_), do: invalid()

  defp record(<<1, 16, generation::64, columns::16, rows::16, flags>>)
       when columns > 0 and rows > 0 and
              (flags &&& bnot(@flag_mask ||| @ready_enhanced_keys)) == 0,
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

  # cli020 D5: an arrow burst under alternate scroll (mouse reports off).
  defp payload(<<7, up, count>>) when up in [0, 1] and count in 1..32,
    do: {:ok, {:scroll, if(up == 1, do: :up, else: :down), count}}

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
