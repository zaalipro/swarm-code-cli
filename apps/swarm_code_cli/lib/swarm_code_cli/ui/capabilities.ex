defmodule SwarmCodeCLI.UI.Capabilities do
  @moduledoc """
  Closed, renderer-neutral terminal capability data.

  `explicit/2` consumes only caller-supplied values. It performs no terminal or
  process-environment detection.
  """

  alias SwarmCodeCLI.UI.Size

  @type color_mode :: :truecolor | :ansi256 | :ansi16 | :monochrome
  @type ambiguous_width :: :narrow | :wide
  @type feature_state :: :supported | :best_effort | :unavailable

  @enforce_keys [:size]
  defstruct size: nil,
            color_mode: :monochrome,
            ambiguous_width: :narrow,
            ascii?: false,
            reduced_motion?: false,
            tty?: false,
            controlling_tty?: false,
            stdin_tty?: false,
            stdout_tty?: false,
            full_screen?: false,
            enhanced_keys: :unavailable,
            focus: :unavailable,
            paste: :unavailable,
            mouse: :unavailable,
            alternate_screen: :unavailable,
            paste_preallocation_bound?: false

  @type t :: %__MODULE__{
          size: Size.t(),
          color_mode: color_mode(),
          ambiguous_width: ambiguous_width(),
          ascii?: boolean(),
          reduced_motion?: boolean(),
          tty?: boolean(),
          controlling_tty?: boolean(),
          stdin_tty?: boolean(),
          stdout_tty?: boolean(),
          full_screen?: boolean(),
          enhanced_keys: feature_state(),
          focus: feature_state(),
          paste: feature_state(),
          mouse: :unavailable,
          alternate_screen: feature_state(),
          paste_preallocation_bound?: boolean()
        }

  @defaults [
    color_mode: :monochrome,
    ambiguous_width: :narrow,
    ascii?: false,
    reduced_motion?: false,
    tty?: false,
    controlling_tty?: false,
    stdin_tty?: false,
    stdout_tty?: false,
    full_screen?: false,
    enhanced_keys: :unavailable,
    focus: :unavailable,
    paste: :unavailable,
    mouse: :unavailable,
    alternate_screen: :unavailable,
    paste_preallocation_bound?: false
  ]

  @boolean_options [
    :ascii?,
    :reduced_motion?,
    :tty?,
    :controlling_tty?,
    :stdin_tty?,
    :stdout_tty?,
    :full_screen?,
    :paste_preallocation_bound?
  ]
  @feature_options [:enhanced_keys, :focus, :paste, :alternate_screen]
  @feature_states [:supported, :best_effort, :unavailable]

  @spec explicit(Size.t(), keyword()) :: t()
  def explicit(%Size{columns: columns, rows: rows} = size, options)
      when is_integer(columns) and columns > 0 and is_integer(rows) and rows > 0 and
             is_list(options) do
    validate_options!(options)
    struct!(__MODULE__, [size: size] ++ Keyword.merge(@defaults, options))
  end

  def explicit(_size, _options), do: raise(ArgumentError, "invalid explicit capabilities")

  defp validate_options!(options) do
    unless Keyword.keyword?(options) do
      raise ArgumentError, "capability options must be a keyword list"
    end

    unknown = Keyword.keys(options) -- Keyword.keys(@defaults)

    if unknown != [] do
      raise ArgumentError, "unknown capability options: #{inspect(unknown)}"
    end

    validate_member!(options, :color_mode, [:truecolor, :ansi256, :ansi16, :monochrome])
    validate_member!(options, :ambiguous_width, [:narrow, :wide])
    validate_member!(options, :mouse, [:unavailable])

    Enum.each(@boolean_options, &validate_member!(options, &1, [true, false]))
    Enum.each(@feature_options, &validate_member!(options, &1, @feature_states))
  end

  defp validate_member!(options, key, allowed) do
    case Keyword.fetch(options, key) do
      :error ->
        :ok

      {:ok, value} ->
        unless value in allowed do
          raise ArgumentError, "invalid #{key} capability: #{inspect(value)}"
        end
    end
  end
end
