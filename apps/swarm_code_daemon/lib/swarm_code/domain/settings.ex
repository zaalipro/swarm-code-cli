defmodule SwarmCode.Domain.Settings do
  @moduledoc """
  Singleton application settings.
  """
  import Ecto.Query, warn: false

  alias SwarmCode.Domain.{Repo, Settings.Setting}

  def get do
    Repo.one(from(s in Setting, limit: 1, order_by: s.inserted_at)) || Repo.insert!(%Setting{})
  end

  @doc """
  `get/0` through `SwarmCode.Domain.Cache` (spec 54 §1.3, 54a A2).

  For the engine's hot path only — once per tool batch (spec 51 §6.11) and
  three times per run start, 12 083 of 152 224 queries under eight lanes. Both
  writers below drop the key, so a `command_timeout_ms` raised mid-run still
  applies to the next batch. The Settings LiveView keeps reading the row.
  """
  def get_cached, do: SwarmCode.Domain.Cache.fetch(:settings, &get/0)

  def update(attrs) do
    case get() |> Setting.changeset(attrs) |> Repo.update() do
      {:ok, setting} ->
        SwarmCode.Domain.Cache.delete(:settings)

        SwarmCode.Domain.PubSub.broadcast(
          SwarmCode.Domain.PubSub,
          "settings",
          {:settings_updated, setting}
        )

        {:ok, setting}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Writes without telling anyone (spec 43 §2.2): for per-window state that is
  persisted only to come back after a restart — a scroll offset, a column
  width mid-drag. `update/1`'s broadcast made every open LiveView re-assign
  its settings, push `set-theme` and re-render for each of them.
  """
  def update_quiet(attrs) do
    result = get() |> Setting.changeset(attrs) |> Repo.update()
    # Spec 54 §1.3: the row is the same singleton the engine reads.
    SwarmCode.Domain.Cache.delete(:settings)
    result
  end

  def change(%Setting{} = setting, attrs \\ %{}), do: Setting.changeset(setting, attrs)

  @doc ~S'`"reduce"` when animations should be off, `"auto"` otherwise.'
  def motion(%{reduce_motion: true}), do: "reduce"
  def motion(_settings), do: "auto"

  # spec 58 T26
  def themes,
    do: [
      {"carbon", "Carbon"},
      {"obsidian", "Obsidian"},
      {"graphite", "Graphite & Amber"},
      {"aurora", "Aurora Glass"},
      {"ember", "Ember"},
      {"fjord", "Fjord"},
      {"dusk", "Dusk"},
      {"paper", "Paper"}
    ]

  @doc """
  The four classic reasoning effort levels, with the one-line hints the
  model chooser shows — the settings-level defaults and the research tiers
  list these; a picker lists `efforts/2` of its row's model (spec 45 §3.3).
  """
  def efforts,
    do: [
      {"low", "Low", "fastest"},
      {"medium", "Medium", "balanced"},
      {"high", "High", "deeper reasoning"},
      {"max", "Max", "maximum thinking"}
    ]

  @doc "The `{key, label, hint}` tuples of `Efforts.levels/2` for a provider and model (spec 45 §3.3)."
  def efforts(provider, model) do
    for l <- SwarmCode.Domain.LLM.Efforts.levels(provider, model),
        do: {l["key"], l["label"], l["hint"] || ""}
  end

  def effort_label(value) do
    case Enum.find(efforts(), fn {v, _label, _hint} -> v == value end) do
      {_v, label, _hint} -> label
      # Spec 45 §3.2: a custom key reads as its capitalised form.
      nil -> SwarmCode.Domain.LLM.Efforts.label(value)
    end
  end

  def modes, do: [{"dark", "Dark"}, {"light", "Light"}]

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "settings")

  # spec 70 E3: default keybindings map
  @default_keybindings %{
    "sidebar" => "meta+b",
    "new" => "meta+n",
    "search" => "meta+k",
    "settings" => "meta+,",
    "quit" => "meta+q",
    "side" => "meta+shift+s",
    "nudge_left" => "shift+alt+ArrowLeft",
    "nudge_right" => "shift+alt+ArrowRight",
    "file_finder" => "meta+p"
  }

  def default_keybindings, do: @default_keybindings

  @doc "Merges the user's overrides onto the defaults; user overrides win."
  def effective_keybindings(%{keybindings: overrides}) when is_map(overrides) do
    Map.merge(@default_keybindings, overrides)
  end

  def effective_keybindings(_settings), do: @default_keybindings
end
