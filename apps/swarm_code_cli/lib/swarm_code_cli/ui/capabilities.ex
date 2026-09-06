defmodule SwarmCodeCLI.UI.Capabilities do
  @moduledoc """
  Closed, renderer-neutral terminal capability data.

  `explicit/2` consumes only caller-supplied values. It performs no terminal or
  process-environment detection.
  """

  alias SwarmCodeCLI.UI.Size
  alias SwarmCodeCLI.UI.Capabilities.Probe

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

  @doc """
  Selects terminal capabilities from inert observations, without OS calls.

  `no_color?` combines the explicit flag and presence of NO_COLOR. A probe owner
  supplies these observations; this function never reads the process environment.
  Full-screen features fail closed unless both streams and /dev/tty are usable.
  The candidate renderer cannot bound paste before allocation or provide live mouse.
  """
  @spec from_probe(Probe.t()) :: t()
  def from_probe(%Probe{} = probe) do
    validate_probe!(probe)

    width =
      case probe.ambiguous_width do
        nil -> :narrow
        :narrow -> :narrow
        "narrow" -> :narrow
        :wide -> :wide
        "wide" -> :wide
        _ -> raise ArgumentError, "ambiguous width must be narrow or wide"
      end

    terminal = is_binary(probe.term) and probe.term not in ["", "dumb"]

    full_screen =
      probe.stdin_tty? and probe.stdout_tty? and probe.controlling_tty? and terminal and
        not probe.plain?

    mode =
      cond do
        probe.no_color? or probe.monochrome? or not probe.stdout_tty? or not terminal ->
          :monochrome

        probe.colorterm in ["truecolor", "24bit"] ->
          :truecolor

        String.contains?(probe.term, "256color") ->
          :ansi256

        true ->
          :ansi16
      end

    features =
      Enum.map(@feature_options, fn feature ->
        {feature, if(full_screen, do: Map.fetch!(probe, feature), else: :unavailable)}
      end)

    explicit(
      probe.size,
      features ++
        [
          color_mode: mode,
          ambiguous_width: width,
          ascii?: probe.ascii?,
          reduced_motion?: probe.reduced_motion?,
          tty?: probe.stdin_tty? and probe.stdout_tty?,
          stdin_tty?: probe.stdin_tty?,
          stdout_tty?: probe.stdout_tty?,
          controlling_tty?: probe.controlling_tty?,
          full_screen?: full_screen,
          mouse: :unavailable,
          paste_preallocation_bound?: false
        ]
    )
  end

  def from_probe(_), do: raise(ArgumentError, "invalid capability probe")

  defp validate_probe!(probe) do
    unless Map.keys(probe) |> Enum.sort() == Map.keys(%Probe{}) |> Enum.sort(),
      do: raise(ArgumentError, "invalid capability probe shape")

    for key <- [
          :stdin_tty?,
          :stdout_tty?,
          :controlling_tty?,
          :no_color?,
          :monochrome?,
          :plain?,
          :ascii?,
          :reduced_motion?,
          :paste_preallocation_bound?
        ] do
      unless is_boolean(Map.fetch!(probe, key)),
        do: raise(ArgumentError, "invalid boolean probe observation")
    end

    for key <- [:term, :colorterm] do
      value = Map.fetch!(probe, key)

      unless is_nil(value) or is_binary(value),
        do: raise(ArgumentError, "invalid terminal probe observation")
    end

    for key <- @feature_options do
      unless Map.fetch!(probe, key) in @feature_states,
        do: raise(ArgumentError, "invalid feature probe observation")
    end
  end

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
