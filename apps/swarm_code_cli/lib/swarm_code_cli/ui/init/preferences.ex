defmodule SwarmCodeCLI.UI.Init.Preferences do
  @moduledoc """
  The CLI's preferences file (pass 72, P6): `cli.json` beside the database in
  the SwarmCode config directory, owner-only (0600).

  Since cli74 it is a thin wrapper over the core file layer
  `SwarmCode.Settings.CliFile` (spec §3.8.1), which knows every terminal
  setting from the registry, compares per key before it writes and keeps the
  keys it does not know. This module keeps the legacy API of the four
  settings the shell had before (`/panel`, `/diff`, `/theme`, `/mouse`:
  `read/1`, `write/2`, `valid?/1`, the `{:save_preferences, map}` effect) and
  runs the session runtime's preference jobs (`run/3`).

  A missing, unreadable, oversized or malformed file (or value) means the
  defaults, never a crash. `read/1` runs in the launcher before the session
  starts, `run/3` in work the session runtime owns; neither is ever called
  from a state owner's callback.
  """

  alias SwarmCode.Settings.CliFile

  # cli020 E5 (Q8): `auto` shows the panel only once two agents work or
  # something needs the user (`Projector.Panel.effective_mode/1`).
  @modes %{"auto" => :auto, "full" => :full, "compact" => :compact, "hidden" => :hidden}
  @themes %{"dark" => :dark, "light" => :light}

  @notify %{"auto" => :auto, "bell" => :bell, "osc9" => :osc9, "os" => :os, "off" => :off}
  # cli020 E27: a fixed map, never `String.to_atom/1`.
  @palettes Map.new(
              ~w(carbon aurora dusk ember fjord graphite obsidian paper)a,
              &{Atom.to_string(&1), &1}
            )

  # The five legacy preferences and, since cli020 E26 (§8.4), the launch's
  # terminal facts D, B and E read, with their json names.
  @keys %{
    panel_mode: "panel",
    show_diffs: "show_diffs",
    theme: "theme",
    mouse?: "mouse",
    agent_summaries?: "agent_summaries",
    notify: "notify",
    title?: "title",
    paste_collapse_lines: "paste_collapse_lines",
    wheel_lines: "wheel_lines",
    notice_seconds: "notice_seconds",
    hint_letters: "hint_letters",
    reduced_motion?: "reduced_motion",
    exit_transcript: "exit_transcript",
    palette: "palette"
  }

  # The registry's bounds (`core/settings/registry/terminal.ex`).
  @ranges %{
    paste_collapse_lines: 0..200,
    wheel_lines: 1..10,
    notice_seconds: 2..30,
    exit_transcript: 0..20
  }
  @hint_letters "sfghjklwertuiop"

  @typedoc """
  `theme` is nil when the file names none: the launcher then falls back to
  the desktop's settings (`SWARM_THEME` > cli.json > desktop > dark).
  """
  @type t :: %{
          panel_mode: :auto | :full | :compact | :hidden,
          show_diffs: boolean(),
          theme: :dark | :light | nil,
          mouse?: boolean(),
          agent_summaries?: boolean(),
          notify: :auto | :bell | :osc9 | :os | :off,
          title?: boolean(),
          paste_collapse_lines: 0..200,
          wheel_lines: 1..10,
          notice_seconds: 2..30,
          hint_letters: String.t(),
          reduced_motion?: boolean(),
          exit_transcript: 0..20,
          palette: atom()
        }

  @typedoc "One job of the session runtime's preference queue (§3.8.2)."
  @type job ::
          :boot
          | {:legacy, map()}
          | {:read, non_neg_integer()}
          | {:write, non_neg_integer(), term(), map(), map()}
          | {:write_text, non_neg_integer(), term(), String.t(), String.t() | nil}

  @doc """
  The defaults: the auto panel, diffs shown, no theme of its own, wheel
  reports off (cli020 E26: the wheel still scrolls), and the registry's
  defaults of the §8.4 keys.
  """
  @spec defaults() :: t()
  def defaults,
    do: %{
      panel_mode: :auto,
      show_diffs: true,
      theme: nil,
      mouse?: false,
      agent_summaries?: true,
      notify: :auto,
      title?: true,
      paste_collapse_lines: 8,
      wheel_lines: 3,
      notice_seconds: 6,
      hint_letters: @hint_letters,
      reduced_motion?: false,
      exit_transcript: 3,
      palette: :carbon
    }

  @doc "The json names of the preferences (the five legacy ones and E26's)."
  @spec legacy_names() :: %{atom() => String.t()}
  def legacy_names, do: @keys

  @doc "The legacy preferences in `path`, or the defaults (per key)."
  @spec read(Path.t() | nil) :: t()
  def read(path), do: path |> read_all() |> Map.fetch!(:values) |> legacy()

  @doc "The legacy preferences of a cli.json values map (json name => wire value)."
  @spec legacy(map()) :: t()
  def legacy(values) when is_map(values) do
    d = defaults()

    %{
      panel_mode: Map.get(@modes, Map.get(values, "panel"), :auto),
      show_diffs: boolean(Map.get(values, "show_diffs"), true),
      theme: Map.get(@themes, Map.get(values, "theme")),
      mouse?: boolean(Map.get(values, "mouse"), d.mouse?),
      agent_summaries?: boolean(Map.get(values, "agent_summaries"), true),
      notify: Map.get(@notify, Map.get(values, "notify"), d.notify),
      title?: boolean(Map.get(values, "title"), d.title?),
      paste_collapse_lines: ranged(values, :paste_collapse_lines, d),
      wheel_lines: ranged(values, :wheel_lines, d),
      notice_seconds: ranged(values, :notice_seconds, d),
      hint_letters: letters(Map.get(values, "hint_letters"), d.hint_letters),
      reduced_motion?: boolean(Map.get(values, "reduced_motion"), d.reduced_motion?),
      exit_transcript: ranged(values, :exit_transcript, d),
      palette: Map.get(@palettes, Map.get(values, "palette"), d.palette)
    }
  end

  defp ranged(values, key, defaults) do
    value = Map.get(values, Map.fetch!(@keys, key))

    if is_integer(value) and value in Map.fetch!(@ranges, key),
      do: value,
      else: Map.fetch!(defaults, key)
  end

  # Hint letters as the registry validates them (`Validate.hint_letters/1`).
  defp letters(value, default) do
    if letters?(value), do: value, else: default
  end

  defp letters?(value), do: SwarmCode.Settings.Validate.hint_letters(value) == :ok

  @doc """
  Whether `preferences` is a non-empty map of known keys with valid values:
  what `write/2` accepts (any subset of `t()`, `theme` not nil).
  """
  @spec valid?(term()) :: boolean()
  def valid?(preferences) when is_map(preferences) and map_size(preferences) > 0,
    do: Enum.all?(preferences, fn {key, value} -> valid_value?(key, value) end)

  def valid?(_preferences), do: false

  defp valid_value?(:panel_mode, mode), do: mode in [:auto, :full, :compact, :hidden]
  defp valid_value?(:show_diffs, value), do: is_boolean(value)
  defp valid_value?(:theme, value), do: value in [:dark, :light]
  defp valid_value?(:mouse?, value), do: is_boolean(value)
  defp valid_value?(:agent_summaries?, v), do: is_boolean(v)
  defp valid_value?(:notify, v), do: v in Map.values(@notify)
  defp valid_value?(:title?, v), do: is_boolean(v)
  defp valid_value?(:reduced_motion?, v), do: is_boolean(v)
  defp valid_value?(:hint_letters, v), do: letters?(v)
  defp valid_value?(:palette, v), do: v in Map.values(@palettes)

  defp valid_value?(key, v) when is_map_key(@ranges, key),
    do: is_integer(v) and v in Map.fetch!(@ranges, key)

  defp valid_value?(_key, _value), do: false

  @doc "The cli.json changes (json name => wire value) of legacy preferences."
  @spec changes(map()) :: %{String.t() => term()}
  def changes(preferences) when is_map(preferences),
    do: Map.new(preferences, fn {key, value} -> {Map.fetch!(@keys, key), encode(value)} end)

  defp boolean(value, _default) when is_boolean(value), do: value
  defp boolean(_value, default), do: default

  defp encode(value) when is_boolean(value), do: value
  defp encode(value) when is_atom(value), do: Atom.to_string(value)
  defp encode(value) when is_integer(value) or is_binary(value), do: value

  @doc """
  Writes the given preferences (any subset of `t()`) to `path`, keeping every
  other key, known or not. The legacy API: no expectation is compared.
  """
  @spec write(Path.t(), map()) :: :ok | {:error, term()}
  def write(path, preferences) when is_binary(path) do
    if valid?(preferences) do
      changes = changes(preferences)

      case write_changes(path, changes, Map.new(changes, fn {name, _} -> {name, :any} end)) do
        {:ok, _snapshot} -> :ok
        {:error, :invalid, _messages} -> {:error, :invalid}
        {:error, reason} -> {:error, reason}
        {:conflict, _current} -> {:error, :conflict}
      end
    else
      {:error, :invalid}
    end
  end

  def write(_path, _preferences), do: {:error, :invalid}

  @doc "Every cli.json value, with the file's status, fingerprint, mode and size."
  @spec read_all(Path.t() | nil) :: CliFile.snapshot()
  def read_all(path), do: CliFile.read_all(path)

  @doc "Per-key compare-and-set write (`CliFile.write_changes/3`)."
  def write_changes(path, changes, expected), do: CliFile.write_changes(path, changes, expected)

  @doc "The external edit's return, written when the fingerprint still holds."
  def write_text(path, text, fingerprint), do: CliFile.write_text(path, text, fingerprint)

  @doc """
  Runs one job of the runtime's preference queue against `path`, given the
  values the session last read (`known`). Returns what the job answers and
  the values the session knows afterwards.

    * `:boot` → `{:boot, snapshot}`
    * `{:legacy, wanted}` → `{:legacy, wanted, result}`: only the changed
      keys are written, each expected to still hold the value the session
      last read, so an external change of another key is never undone and
      an external change of the same key is a conflict, not an overwrite.
    * `{:read, generation}` → `{:cli_snapshot, generation, snapshot}`
    * `{:write, generation, ref, changes, expected}` and
      `{:write_text, generation, ref, text, fingerprint}` →
      `{:cli_result, generation, ref, result}`
  """
  @spec run(Path.t() | nil, job(), map()) :: {tuple(), map()}
  def run(nil, job, known), do: {unavailable(job), known}

  def run(path, :boot, known) do
    snapshot = read_all(path)
    {{:boot, snapshot}, known_after(snapshot, known)}
  end

  def run(path, {:read, generation}, known) do
    snapshot = read_all(path)
    {{:cli_snapshot, generation, snapshot}, known_after(snapshot, known)}
  end

  def run(path, {:legacy, wanted}, known) do
    changes = changes(wanted)
    expected = Map.new(changes, fn {name, _value} -> {name, Map.get(known, name, :absent)} end)
    result = write_changes(path, changes, expected)
    {{:legacy, wanted, result}, known_after(result, known)}
  end

  def run(path, {:write, generation, ref, changes, expected}, known) do
    result = write_changes(path, changes, expected)
    {{:cli_result, generation, ref, result}, known_after(result, known)}
  end

  def run(path, {:write_text, generation, ref, text, fingerprint}, known) do
    result = write_text(path, text, fingerprint)
    {{:cli_result, generation, ref, result}, known_after(result, known)}
  end

  @doc "What a job answers when this session keeps no cli.json (tests, fake demos) or is busy."
  @spec unavailable(job(), atom()) :: tuple()
  def unavailable(job, reason \\ :unavailable)
  def unavailable(:boot, _reason), do: {:boot, CliFile.empty()}
  def unavailable({:legacy, wanted}, reason), do: {:legacy, wanted, {:error, reason}}
  def unavailable({:read, generation}, reason), do: {:cli_snapshot, generation, {:error, reason}}

  def unavailable({:write, generation, ref, _changes, _expected}, reason),
    do: {:cli_result, generation, ref, {:error, reason}}

  def unavailable({:write_text, generation, ref, _text, _fingerprint}, reason),
    do: {:cli_result, generation, ref, {:error, reason}}

  defp known_after(%{status: status, values: values}, _known) when status in [:ok, :absent],
    do: values

  defp known_after({:ok, %{values: values}}, _known), do: values
  defp known_after({:ok, %{values: values}, _warnings}, _known), do: values

  # A conflict tells what the file holds now for the keys that moved.
  defp known_after({:conflict, current}, known) when is_map(current) do
    Enum.reduce(current, known, fn
      {name, :absent}, acc -> Map.delete(acc, name)
      {name, value}, acc -> Map.put(acc, name, value)
    end)
  end

  defp known_after(_result, known), do: known
end
