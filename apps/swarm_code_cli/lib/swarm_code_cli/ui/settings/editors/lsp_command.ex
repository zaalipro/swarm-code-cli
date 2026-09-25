defmodule SwarmCodeCLI.UI.Settings.Editors.LspCommand do
  @moduledoc """
  A language server's command (spec §3.7.8): ←/→ choose `default`, `off`
  or `custom`; with custom, typing edits the command line. Enter writes
  nil (the default), `"off"`, or the command. Opts: `value`, `default` (the
  default command, shown), `max`.
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCodeCLI.UI.Settings.Buffer

  @modes [:default, :off, :custom]

  @impl true
  def init(_row, opts, _ctx) do
    value = Map.get(opts, :value)

    mode =
      case value do
        nil -> :default
        "off" -> :off
        _ -> :custom
      end

    text = if mode == :custom, do: value, else: ""

    {:ok,
     %{
       opts: opts,
       mode: mode,
       buffer: Buffer.new(text, max: Map.get(opts, :max, 1_024)),
       error: nil
     }}
  end

  @impl true
  def handle(state, {:key, :enter}, _ctx) do
    case state.mode do
      :default ->
        {:commit, nil, state}

      :off ->
        {:commit, "off", state}

      :custom ->
        text = String.trim(state.buffer.text)

        if text == "",
          do: {:cont, %{state | error: "type the command, or choose default"}},
          else: {:commit, text, state}
    end
  end

  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(%{mode: :custom} = state, {:key, key}, _ctx)
      when key in [:left, :right] and state.buffer.text != "",
      do: {:cont, %{state | buffer: Buffer.key(state.buffer, key)}}

  def handle(state, {:key, :left}, _ctx), do: {:cont, cycle(state, -1)}
  def handle(state, {:key, :right}, _ctx), do: {:cont, cycle(state, 1)}
  def handle(state, {:key, :up}, _ctx), do: {:cont, cycle(state, -1)}
  def handle(state, {:key, :down}, _ctx), do: {:cont, cycle(state, 1)}

  def handle(state, {event, text}, _ctx) when event in [:text, :paste] and is_binary(text) do
    case Buffer.insert(state.buffer, String.trim_trailing(text, "\n")) do
      {:ok, buffer} -> {:cont, %{state | buffer: buffer, mode: :custom, error: nil}}
      {:error, _} -> {:cont, %{state | error: "one line, at most #{state.buffer.max} bytes"}}
    end
  end

  def handle(%{mode: :custom} = state, {:key, key}, _ctx),
    do: {:cont, %{state | buffer: Buffer.key(state.buffer, key)}}

  def handle(state, _event, _ctx), do: {:cont, state}

  defp cycle(state, delta) do
    index = Enum.find_index(@modes, &(&1 == state.mode))
    %{state | mode: Enum.at(@modes, Integer.mod(index + delta, 3)), error: nil}
  end

  @impl true
  def display(state, _ctx) do
    default = Map.get(state.opts, :default)

    segments =
      Enum.flat_map(@modes, fn mode ->
        label = Atom.to_string(mode)
        text = if mode == state.mode, do: "[#{label}]", else: " #{label} "
        [{text, if(mode == state.mode, do: :selection, else: :text_muted)}, {" ", :text_primary}]
      end)

    line =
      case state.mode do
        :custom -> [[{state.buffer.text, :text_primary}, {"▏", :focus}]]
        :default when is_binary(default) -> [[{default, :text_faint}]]
        _ -> []
      end

    error = if state.error, do: [[{"✗ " <> state.error, :error}]], else: []

    %{
      value: segments,
      lines: line ++ error,
      popover: nil,
      context: :settings_edit,
      footer: [{"←→", "choose"}, {"Enter", "save"}, {"Esc", "cancel"}]
    }
  end
end
