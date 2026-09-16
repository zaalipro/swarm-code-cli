defmodule SwarmCodeCLI.UI.Vim do
  @moduledoc """
  The composer's vim state: one mode, one pending operator, one count.

  Struct and validation only. The resolver and the mode transitions are Phase
  2C; nothing in Phase 1A reads `pending` or `count`, and `mode` is only read by
  `UI.Keymap.Context.of/1` to name the composer context.

  `pending` is the literal keys typed so far towards an operator (`"d"`, `"2d"`
  is spelled as `count: 2, pending: "d"`), bounded so a stuck prefix can never
  grow without limit. `count` is capped at 999, the same ceiling
  `Editor.Operation` puts on `{:times, n, op}`.
  """

  @modes [:insert, :normal, :visual]
  @max_count 999
  @max_pending_bytes 8

  defstruct mode: :insert, pending: nil, count: nil

  @type mode :: :insert | :normal | :visual
  @type t :: %__MODULE__{
          mode: mode(),
          pending: nil | binary(),
          count: nil | pos_integer()
        }

  @doc "The closed mode vocabulary."
  @spec modes() :: [mode()]
  def modes, do: @modes

  @doc "The count ceiling; a count may never grow past it."
  @spec max_count() :: pos_integer()
  def max_count, do: @max_count

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_vim_state}
  def validate(%__MODULE__{mode: mode, pending: pending, count: count} = vim)
      when map_size(vim) == 4 do
    valid? =
      mode in @modes and valid_pending?(pending) and
        (is_nil(count) or (is_integer(count) and count >= 1 and count <= @max_count))

    if valid?, do: {:ok, vim}, else: {:error, :invalid_vim_state}
  end

  def validate(_vim), do: {:error, :invalid_vim_state}

  @spec validate!(term()) :: t()
  def validate!(vim) do
    case validate(vim) do
      {:ok, valid} -> valid
      {:error, :invalid_vim_state} -> raise ArgumentError, "invalid vim state"
    end
  end

  defp valid_pending?(nil), do: true

  defp valid_pending?(pending) when is_binary(pending),
    do: pending != "" and byte_size(pending) <= @max_pending_bytes and String.valid?(pending)

  defp valid_pending?(_pending), do: false
end
