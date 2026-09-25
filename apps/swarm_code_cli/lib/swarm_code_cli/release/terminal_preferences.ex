defmodule SwarmCodeCLI.Release.TerminalPreferences do
  @moduledoc """
  pass74 (spec §3.8.4): what a launch's terminal looks and behaves like, from
  the environment, cli.json (`SwarmCode.Settings.CliFile.read_all/1`'s
  snapshot), the desktop app's `mode` and the launch flags. Pure: the caller
  reads the environment, the file and the database.

  Every rule is one env/flag layer of the terminal entries (§2.14–§2.17):

  - theme: `SWARM_THEME` > cli `theme` > the desktop's mode > dark;
  - colours: `NO_COLOR` present **and non-empty** (D21) → monochrome, else cli
    `colors` unless `auto`, else the `COLORTERM`/`TERM` probe;
  - glyphs: `SWARM_ASCII` in `1 true yes` → ascii, else cli `glyphs` unless
    `auto`, else `Capabilities.glyph_tier/4`;
  - wheel: `SWARM_MOUSE` > cli `mouse` > on;
  - keymap: `SWARM_KEYMAP=vim` > cli `keymap` > standard;
  - companion: `SWARM_COMPANION=0` > cli `companion` > on;
  - startup: a conversation flag or `SWARM_CONVERSATION` > cli
    `startup_conversation` > latest.

  An environment value outside the entry's value space (`SWARM_KEYMAP=emacs`,
  `SWARM_THEME=blue`, `SWARM_CONVERSATION=<id>`) never wins: it is reported in
  `env_overrides` with `ignored: true` and a `note` (D40), so the settings
  layer can show it in the provenance list.

  `flags` names the launch's own flags by their spelling:
  `%{"--new" => ""}`, `%{"--continue" => ""}`, `%{"--resume" => id}`.
  """

  alias SwarmCodeCLI.UI.Capabilities

  @type rgb :: {0..255, 0..255, 0..255}
  @type override :: %{
          required(:var) => String.t(),
          required(:value) => String.t(),
          optional(:ignored) => true,
          optional(:note) => String.t()
        }
  @type t :: %{
          theme: :dark | :light,
          theme_env: :dark | :light | nil,
          mouse?: boolean(),
          keymap: :default | :vim,
          color_mode: Capabilities.color_mode(),
          ascii?: boolean(),
          glyph_tier: Capabilities.glyph_tier(),
          ambiguous_width: :narrow | :wide,
          reduced_motion?: boolean(),
          accent: nil | rgb(),
          companion?: boolean(),
          startup_conversation: :latest | :new | :ask,
          prefs: %{String.t() => term()},
          env_overrides: %{String.t() => override()},
          flag_overrides: %{String.t() => %{flag: String.t(), value: String.t()}},
          warnings: [String.t()]
        }

  @yes ~w[1 true yes on]
  @no ~w[0 false no off]
  @conversation_flags ["--new", "--continue", "--resume"]

  @doc "The launch's terminal (see the moduledoc)."
  @spec launch(map(), map() | nil, String.t() | atom() | nil, map()) :: t()
  def launch(env, cli, desktop_mode, flags \\ %{}) when is_map(env) do
    prefs = cli_values(cli)
    flags = if is_map(flags), do: flags, else: %{}

    acc = %{env: %{}, flag: %{}, warnings: []}
    {theme, theme_env, acc} = theme(env, prefs, desktop_mode, acc)
    {color_mode, acc} = color_mode(env, prefs, acc)
    {ambiguous, acc} = {ambiguous_width(prefs), acc}
    {ascii?, glyph_tier, acc} = glyphs(env, prefs, color_mode, ambiguous, acc)
    {mouse?, acc} = mouse(env, prefs, acc)
    {keymap, acc} = keymap(env, prefs, acc)
    {companion?, acc} = companion(env, prefs, acc)
    {startup, acc} = startup(env, prefs, flags, acc)
    acc = editor(env, acc)

    %{
      theme: theme,
      theme_env: theme_env,
      mouse?: mouse?,
      keymap: keymap,
      color_mode: color_mode,
      ascii?: ascii?,
      glyph_tier: glyph_tier,
      ambiguous_width: ambiguous,
      reduced_motion?: Map.get(prefs, "reduced_motion") == true,
      accent: accent(prefs),
      companion?: companion?,
      startup_conversation: startup,
      prefs: prefs,
      env_overrides: acc.env,
      flag_overrides: acc.flag,
      warnings: Enum.reverse(acc.warnings)
    }
  end

  @doc """
  Parses an accent colour as the registry stores it (`#RRGGBB`) or as a user
  types it (`RRGGBB`, `#RGB`, any case). Returns the canonical upper-case
  `#RRGGBB` and its components.
  """
  @spec parse_accent(term()) :: {:ok, String.t(), rgb()} | :error
  def parse_accent(value) when is_binary(value) do
    hex = value |> String.trim() |> String.trim_leading("#")

    hex =
      case hex do
        <<r, g, b>> -> <<r, r, g, g, b, b>>
        other -> other
      end

    with 6 <- byte_size(hex),
         true <- String.match?(hex, ~r/\A[0-9A-Fa-f]{6}\z/),
         {int, ""} <- Integer.parse(hex, 16) do
      rgb = {div(int, 65_536), rem(div(int, 256), 256), rem(int, 256)}
      {:ok, "#" <> String.upcase(hex), rgb}
    else
      _ -> :error
    end
  end

  def parse_accent(_), do: :error

  # ------------------------------------------------------------------ rules

  defp cli_values(%{values: values}) when is_map(values), do: values
  defp cli_values(%{"values" => values}) when is_map(values), do: values
  defp cli_values(_), do: %{}

  defp theme(env, prefs, desktop_mode, acc) do
    case env_value(env, "SWARM_THEME") do
      nil ->
        {mode(Map.get(prefs, "theme")) || mode(desktop_mode) || :dark, nil, acc}

      raw ->
        case mode(raw) do
          nil ->
            acc = ignored(acc, "terminal.theme", "SWARM_THEME", raw, "not dark or light")
            {mode(Map.get(prefs, "theme")) || mode(desktop_mode) || :dark, nil, acc}

          forced ->
            {forced, forced, override(acc, "terminal.theme", "SWARM_THEME", raw)}
        end
    end
  end

  defp mode(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "dark" -> :dark
      "light" -> :light
      _ -> nil
    end
  end

  defp mode(value) when value in [:dark, :light], do: value
  defp mode(_), do: nil

  defp color_mode(env, prefs, acc) do
    case Map.get(env, "NO_COLOR") do
      value when is_binary(value) and value != "" ->
        {:monochrome, override(acc, "terminal.colors", "NO_COLOR", value)}

      _ ->
        case Map.get(prefs, "colors") do
          "truecolor" -> {:truecolor, acc}
          "256" -> {:ansi256, acc}
          256 -> {:ansi256, acc}
          "16" -> {:ansi16, acc}
          16 -> {:ansi16, acc}
          "none" -> {:monochrome, acc}
          _ -> {probe_color_mode(env), acc}
        end
    end
  end

  @doc "The `COLORTERM`/`TERM` probe (the colours' `auto`)."
  @spec probe_color_mode(map()) :: Capabilities.color_mode()
  def probe_color_mode(env) do
    cond do
      Map.get(env, "COLORTERM") in ["truecolor", "24bit"] -> :truecolor
      String.contains?(Map.get(env, "TERM") || "", "256color") -> :ansi256
      true -> :ansi16
    end
  end

  defp ambiguous_width(prefs) do
    if Map.get(prefs, "ambiguous_width") == "wide", do: :wide, else: :narrow
  end

  defp glyphs(env, prefs, color_mode, ambiguous, acc) do
    preference = Map.get(prefs, "glyphs", "auto")

    acc =
      if preference == "rich" and ambiguous == :wide,
        do: warn(acc, "rich glyphs under wide ambiguous width may misalign"),
        else: acc

    case env_value(env, "SWARM_ASCII") do
      nil ->
        ascii? = preference == "ascii"
        tier = Capabilities.glyph_tier(color_mode, ambiguous, ascii?, env["TERM"], preference)
        {ascii?, tier, acc}

      raw ->
        cond do
          String.downcase(raw) in ~w[1 true yes] ->
            acc = override(acc, "terminal.glyphs", "SWARM_ASCII", raw)
            {true, :measured, acc}

          String.downcase(raw) in ~w[0 false no] ->
            ascii? = preference == "ascii"
            tier = Capabilities.glyph_tier(color_mode, ambiguous, ascii?, env["TERM"], preference)
            {ascii?, tier, acc}

          true ->
            acc = ignored(acc, "terminal.glyphs", "SWARM_ASCII", raw, "not 1, true or yes")
            ascii? = preference == "ascii"
            tier = Capabilities.glyph_tier(color_mode, ambiguous, ascii?, env["TERM"], preference)
            {ascii?, tier, acc}
        end
    end
  end

  defp mouse(env, prefs, acc) do
    stored = Map.get(prefs, "mouse", true) != false

    case env_value(env, "SWARM_MOUSE") do
      nil ->
        {stored, acc}

      raw ->
        cond do
          String.downcase(raw) in @yes ->
            {true, override(acc, "terminal.mouse", "SWARM_MOUSE", raw)}

          String.downcase(raw) in @no ->
            {false, override(acc, "terminal.mouse", "SWARM_MOUSE", raw)}

          true ->
            {stored, ignored(acc, "terminal.mouse", "SWARM_MOUSE", raw, "not 0 or 1")}
        end
    end
  end

  defp keymap(env, prefs, acc) do
    stored = if Map.get(prefs, "keymap") == "vim", do: :vim, else: :default

    case env_value(env, "SWARM_KEYMAP") do
      nil ->
        {stored, acc}

      raw ->
        if String.downcase(raw) == "vim",
          do: {:vim, override(acc, "terminal.keymap", "SWARM_KEYMAP", raw)},
          else:
            {stored, ignored(acc, "terminal.keymap", "SWARM_KEYMAP", raw, "only vim changes it")}
    end
  end

  defp companion(env, prefs, acc) do
    stored = Map.get(prefs, "companion", true) != false

    case Map.get(env, "SWARM_COMPANION") do
      "0" -> {false, override(acc, "terminal.companion", "SWARM_COMPANION", "0")}
      _ -> {stored, acc}
    end
  end

  defp startup(env, prefs, flags, acc) do
    stored =
      case Map.get(prefs, "startup_conversation") do
        "new" -> :new
        "ask" -> :ask
        _ -> :latest
      end

    case Enum.find(@conversation_flags, &Map.has_key?(flags, &1)) do
      nil ->
        startup_env(env, stored, acc)

      "--new" ->
        {:new, flag(acc, "terminal.startup_conversation", "--new", "")}

      "--continue" ->
        {:latest, flag(acc, "terminal.startup_conversation", "--continue", "")}

      "--resume" ->
        value = flags |> Map.get("--resume") |> to_string()

        acc =
          flag(acc, "terminal.startup_conversation", "--resume", value, %{
            ignored: true,
            note: "this launch opened one named conversation"
          })

        {stored, acc}
    end
  end

  defp startup_env(env, stored, acc) do
    case env_value(env, "SWARM_CONVERSATION") do
      nil ->
        {stored, acc}

      raw ->
        case String.downcase(raw) do
          "latest" ->
            {:latest, override(acc, "terminal.startup_conversation", "SWARM_CONVERSATION", raw)}

          "new" ->
            {:new, override(acc, "terminal.startup_conversation", "SWARM_CONVERSATION", raw)}

          _ ->
            acc =
              ignored(
                acc,
                "terminal.startup_conversation",
                "SWARM_CONVERSATION",
                raw,
                "this launch opened one named conversation"
              )

            {stored, acc}
        end
    end
  end

  # `terminal.editor` is `C → E D`: the file wins, the environment is the
  # layer under it.
  defp editor(env, acc) do
    case Enum.find(["VISUAL", "EDITOR"], &env_value(env, &1)) do
      nil -> acc
      var -> override(acc, "terminal.editor", var, env_value(env, var))
    end
  end

  defp accent(prefs) do
    case parse_accent(Map.get(prefs, "accent")) do
      {:ok, _hex, rgb} -> rgb
      :error -> nil
    end
  end

  defp env_value(env, name) do
    case Map.get(env, name) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp override(acc, key, var, value),
    do: %{acc | env: Map.put(acc.env, key, %{var: var, value: value})}

  defp ignored(acc, key, var, value, note),
    do: %{
      acc
      | env: Map.put(acc.env, key, %{var: var, value: value, ignored: true, note: note})
    }

  defp flag(acc, key, flag, value, extra \\ %{}),
    do: %{acc | flag: Map.put(acc.flag, key, Map.merge(%{flag: flag, value: value}, extra))}

  defp warn(acc, words), do: %{acc | warnings: [words | acc.warnings]}
end
