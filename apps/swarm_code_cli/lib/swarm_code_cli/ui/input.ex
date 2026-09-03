defmodule SwarmCodeCLI.UI.Input do
  @moduledoc """
  Bounded renderer-neutral terminal input.

  Lifecycle ingress intentionally does not add an Input variant: Ctrl+Z is a
  normal `:control` + textual `"z"` key input and the keymap later emits the
  generation-correlated lifecycle Action.
  """

  alias SwarmCodeCLI.UI.Size

  @max_fragment_bytes 4_096
  @max_paste_bytes 262_144

  @special_keys [
    :backspace,
    :enter,
    :left,
    :right,
    :up,
    :down,
    :home,
    :end,
    :page_up,
    :page_down,
    :tab,
    :back_tab,
    :delete,
    :insert,
    :escape,
    :null,
    :caps_lock,
    :scroll_lock,
    :num_lock,
    :print_screen,
    :pause,
    :menu,
    :keypad_begin
  ]
  @modifiers [:shift, :control, :alt, :super, :hyper, :meta]
  @mouse_kinds [
    :press,
    :release,
    :drag,
    :moved,
    :wheel_up,
    :wheel_down,
    :wheel_left,
    :wheel_right
  ]
  @mouse_buttons [:left, :right, :middle]
  @phases [:press, :repeat, :release]
  @rejections [:invalid_utf8, :text_fragment_too_large, :paste_too_large]

  @type phase :: :press | :repeat | :release
  @type key_code ::
          :backspace
          | :enter
          | :left
          | :right
          | :up
          | :down
          | :home
          | :end
          | :page_up
          | :page_down
          | :tab
          | :back_tab
          | :delete
          | :insert
          | :escape
          | :null
          | :caps_lock
          | :scroll_lock
          | :num_lock
          | :print_screen
          | :pause
          | :menu
          | :keypad_begin
          | {:function, 1..12}
  @type modifier :: :shift | :control | :alt | :super | :hyper | :meta
  @type mouse_kind ::
          :press
          | :release
          | :drag
          | :moved
          | :wheel_up
          | :wheel_down
          | :wheel_left
          | :wheel_right
  @type mouse_button :: :left | :right | :middle
  @type rejection :: :invalid_utf8 | :text_fragment_too_large | :paste_too_large

  @type t ::
          {:key, phase(), key_code(), [modifier()]}
          | {:text_fragment, phase(), binary(), [modifier()]}
          | {:paste, binary()}
          | {:rejected, rejection()}
          | {:resize, Size.t()}
          | :focus_gained
          | :focus_lost
          | {:mouse, mouse_kind(), mouse_button() | nil, non_neg_integer(), non_neg_integer(),
             [modifier()]}

  @spec key(key_code()) :: t()
  def key(code), do: key(:press, code, [])

  @spec key(key_code(), [modifier()]) :: t()
  def key(code, modifiers), do: key(:press, code, modifiers)

  @spec key(phase(), key_code(), [modifier()]) :: t()
  def key(phase, code, modifiers) do
    input = {:key, phase, code, modifiers}

    case validate(input) do
      {:ok, valid} -> valid
      {:error, :invalid_input} -> raise ArgumentError, "invalid key input"
    end
  end

  @spec text_fragment(phase(), binary(), [modifier()]) :: t()
  def text_fragment(phase, fragment, modifiers) do
    cond do
      not is_binary(fragment) ->
        {:rejected, :invalid_utf8}

      byte_size(fragment) > @max_fragment_bytes ->
        {:rejected, :text_fragment_too_large}

      not String.valid?(fragment) ->
        {:rejected, :invalid_utf8}

      true ->
        input = {:text_fragment, phase, fragment, modifiers}

        case validate(input) do
          {:ok, valid} -> valid
          {:error, :invalid_input} -> raise ArgumentError, "invalid text fragment input"
        end
    end
  end

  @spec paste(binary()) :: t()
  def paste(text) do
    cond do
      not is_binary(text) -> {:rejected, :invalid_utf8}
      byte_size(text) > @max_paste_bytes -> {:rejected, :paste_too_large}
      not String.valid?(text) -> {:rejected, :invalid_utf8}
      true -> {:paste, text}
    end
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_input}
  def validate({:key, phase, code, modifiers} = input) do
    valid_input(input, phase in @phases and valid_key_code?(code) and valid_modifiers?(modifiers))
  end

  def validate({:text_fragment, phase, fragment, modifiers} = input) do
    valid? =
      phase in @phases and is_binary(fragment) and byte_size(fragment) <= @max_fragment_bytes and
        String.valid?(fragment) and valid_modifiers?(modifiers)

    valid_input(input, valid?)
  end

  def validate({:paste, text} = input) do
    valid_input(
      input,
      is_binary(text) and byte_size(text) <= @max_paste_bytes and String.valid?(text)
    )
  end

  def validate({:rejected, reason} = input),
    do: valid_input(input, reason in @rejections)

  def validate({:resize, size} = input), do: valid_input(input, Size.valid?(size))
  def validate(:focus_gained), do: {:ok, :focus_gained}
  def validate(:focus_lost), do: {:ok, :focus_lost}

  def validate({:mouse, kind, button, column, row, modifiers} = input) do
    valid? =
      kind in @mouse_kinds and (is_nil(button) or button in @mouse_buttons) and
        is_integer(column) and column >= 0 and is_integer(row) and row >= 0 and
        valid_modifiers?(modifiers)

    valid_input(input, valid?)
  end

  def validate(_input), do: {:error, :invalid_input}

  @spec validate!(term()) :: t()
  def validate!(input) do
    case validate(input) do
      {:ok, valid} -> valid
      {:error, :invalid_input} -> raise ArgumentError, "invalid terminal input"
    end
  end

  @spec from_external_code(term()) :: {:ok, key_code()} | :ignore
  def from_external_code("Backspace"), do: {:ok, :backspace}
  def from_external_code("backspace"), do: {:ok, :backspace}
  def from_external_code("Enter"), do: {:ok, :enter}
  def from_external_code("enter"), do: {:ok, :enter}
  def from_external_code("Left"), do: {:ok, :left}
  def from_external_code("left"), do: {:ok, :left}
  def from_external_code("Right"), do: {:ok, :right}
  def from_external_code("right"), do: {:ok, :right}
  def from_external_code("Up"), do: {:ok, :up}
  def from_external_code("up"), do: {:ok, :up}
  def from_external_code("Down"), do: {:ok, :down}
  def from_external_code("down"), do: {:ok, :down}
  def from_external_code("Home"), do: {:ok, :home}
  def from_external_code("home"), do: {:ok, :home}
  def from_external_code("End"), do: {:ok, :end}
  def from_external_code("end"), do: {:ok, :end}
  def from_external_code("PageUp"), do: {:ok, :page_up}
  def from_external_code("page_up"), do: {:ok, :page_up}
  def from_external_code("PageDown"), do: {:ok, :page_down}
  def from_external_code("page_down"), do: {:ok, :page_down}
  def from_external_code("Tab"), do: {:ok, :tab}
  def from_external_code("tab"), do: {:ok, :tab}
  def from_external_code("BackTab"), do: {:ok, :back_tab}
  def from_external_code("back_tab"), do: {:ok, :back_tab}
  def from_external_code("Delete"), do: {:ok, :delete}
  def from_external_code("delete"), do: {:ok, :delete}
  def from_external_code("Insert"), do: {:ok, :insert}
  def from_external_code("insert"), do: {:ok, :insert}
  def from_external_code("Esc"), do: {:ok, :escape}
  def from_external_code("Escape"), do: {:ok, :escape}
  def from_external_code("escape"), do: {:ok, :escape}
  def from_external_code("Null"), do: {:ok, :null}
  def from_external_code("null"), do: {:ok, :null}
  def from_external_code("CapsLock"), do: {:ok, :caps_lock}
  def from_external_code("caps_lock"), do: {:ok, :caps_lock}
  def from_external_code("ScrollLock"), do: {:ok, :scroll_lock}
  def from_external_code("scroll_lock"), do: {:ok, :scroll_lock}
  def from_external_code("NumLock"), do: {:ok, :num_lock}
  def from_external_code("num_lock"), do: {:ok, :num_lock}
  def from_external_code("PrintScreen"), do: {:ok, :print_screen}
  def from_external_code("print_screen"), do: {:ok, :print_screen}
  def from_external_code("Pause"), do: {:ok, :pause}
  def from_external_code("pause"), do: {:ok, :pause}
  def from_external_code("Menu"), do: {:ok, :menu}
  def from_external_code("menu"), do: {:ok, :menu}
  def from_external_code("KeypadBegin"), do: {:ok, :keypad_begin}
  def from_external_code("keypad_begin"), do: {:ok, :keypad_begin}
  def from_external_code("F1"), do: {:ok, {:function, 1}}
  def from_external_code("F2"), do: {:ok, {:function, 2}}
  def from_external_code("F3"), do: {:ok, {:function, 3}}
  def from_external_code("F4"), do: {:ok, {:function, 4}}
  def from_external_code("F5"), do: {:ok, {:function, 5}}
  def from_external_code("F6"), do: {:ok, {:function, 6}}
  def from_external_code("F7"), do: {:ok, {:function, 7}}
  def from_external_code("F8"), do: {:ok, {:function, 8}}
  def from_external_code("F9"), do: {:ok, {:function, 9}}
  def from_external_code("F10"), do: {:ok, {:function, 10}}
  def from_external_code("F11"), do: {:ok, {:function, 11}}
  def from_external_code("F12"), do: {:ok, {:function, 12}}
  def from_external_code(_external), do: :ignore

  @spec from_external_modifier(term()) :: {:ok, modifier()} | :ignore
  def from_external_modifier("Shift"), do: {:ok, :shift}
  def from_external_modifier("shift"), do: {:ok, :shift}
  def from_external_modifier("Control"), do: {:ok, :control}
  def from_external_modifier("control"), do: {:ok, :control}
  def from_external_modifier("Alt"), do: {:ok, :alt}
  def from_external_modifier("alt"), do: {:ok, :alt}
  def from_external_modifier("Super"), do: {:ok, :super}
  def from_external_modifier("super"), do: {:ok, :super}
  def from_external_modifier("Hyper"), do: {:ok, :hyper}
  def from_external_modifier("hyper"), do: {:ok, :hyper}
  def from_external_modifier("Meta"), do: {:ok, :meta}
  def from_external_modifier("meta"), do: {:ok, :meta}
  def from_external_modifier(_external), do: :ignore

  @spec from_external_mouse_kind(term()) :: {:ok, mouse_kind()} | :ignore
  def from_external_mouse_kind("Down"), do: {:ok, :press}
  def from_external_mouse_kind("Press"), do: {:ok, :press}
  def from_external_mouse_kind("Up"), do: {:ok, :release}
  def from_external_mouse_kind("Release"), do: {:ok, :release}
  def from_external_mouse_kind("Drag"), do: {:ok, :drag}
  def from_external_mouse_kind("Moved"), do: {:ok, :moved}
  def from_external_mouse_kind("ScrollUp"), do: {:ok, :wheel_up}
  def from_external_mouse_kind("ScrollDown"), do: {:ok, :wheel_down}
  def from_external_mouse_kind("ScrollLeft"), do: {:ok, :wheel_left}
  def from_external_mouse_kind("ScrollRight"), do: {:ok, :wheel_right}
  def from_external_mouse_kind(_external), do: :ignore

  @spec from_external_mouse_button(term()) :: {:ok, mouse_button()} | :ignore
  def from_external_mouse_button("Left"), do: {:ok, :left}
  def from_external_mouse_button("Right"), do: {:ok, :right}
  def from_external_mouse_button("Middle"), do: {:ok, :middle}
  def from_external_mouse_button(_external), do: :ignore

  defp valid_key_code?({:function, number}), do: is_integer(number) and number in 1..12
  defp valid_key_code?(code), do: code in @special_keys

  defp valid_modifiers?(modifiers) when is_list(modifiers),
    do: bounded_unique_modifiers?(modifiers, MapSet.new(), 0)

  defp valid_modifiers?(_modifiers), do: false

  defp bounded_unique_modifiers?([], _seen, _count), do: true

  defp bounded_unique_modifiers?([modifier | rest], seen, count)
       when count < 6 and modifier in @modifiers do
    if MapSet.member?(seen, modifier),
      do: false,
      else: bounded_unique_modifiers?(rest, MapSet.put(seen, modifier), count + 1)
  end

  defp bounded_unique_modifiers?(_modifiers, _seen, _count), do: false

  defp valid_input(input, true), do: {:ok, input}
  defp valid_input(_input, false), do: {:error, :invalid_input}
end
