defmodule SwarmCode.Settings.Registry.Desktop do
  @moduledoc false
  # §2.20 Desktop app: settings-row columns only the desktop app reads.
  import SwarmCode.Settings.Registry.Build

  @themes [
    {"carbon", "Carbon", "#ff6a1a"},
    {"obsidian", "Obsidian", "#6366f1"},
    {"graphite", "Graphite & Amber", "#f5c26b"},
    {"aurora", "Aurora Glass", "#2dd4bf"},
    {"ember", "Ember", "#c9662f"},
    {"fjord", "Fjord", "#0e9aa8"},
    {"dusk", "Dusk", "#f2604e"},
    {"paper", "Paper", "#d9664a"}
  ]

  @keys [
    {"file_finder", "File finder", "meta+p"},
    {"new", "New chat", "meta+n"},
    {"nudge_left", "Resize panes left", "shift+alt+ArrowLeft"},
    {"nudge_right", "Resize panes right", "shift+alt+ArrowRight"},
    {"quit", "Quit", "meta+q"},
    {"search", "Search", "meta+k"},
    {"settings", "Settings", "meta+,"},
    {"side", "Toggle side chat", "meta+shift+s"},
    {"sidebar", "Toggle panel", "meta+b"}
  ]

  @doc false
  def themes, do: Enum.map(@themes, &elem(&1, 0))

  @doc false
  def default_keybindings, do: Map.new(@keys, fn {action, _label, combo} -> {action, combo} end)

  @px_between %{
    min: "must be greater than or equal to {n}",
    max: "must be less than or equal to {n}"
  }

  defp desk(key, label, opts) do
    global(
      key,
      :desktop,
      label,
      [applies: :desktop, desktop_only: true, shared: true, parity: "D§3"] ++ opts
    )
  end

  @look [
    global("desktop.theme", :desktop, "Theme",
      group: "look",
      storage: {:setting, :theme},
      type: :enum,
      choices: choices(@themes),
      default: "carbon",
      applies: :desktop,
      desktop_only: true,
      shared: true,
      synonyms: ["desktop theme"],
      parity: "D§3"
    ),
    global("desktop.mode", :desktop, "Mode",
      group: "look",
      description: "Also the terminal's theme when Theme follows the desktop app.",
      storage: {:setting, :mode},
      type: :enum,
      choices: choices([{"dark", "Dark"}, {"light", "Light"}]),
      default: "dark",
      applies: :desktop,
      shared: true,
      synonyms: ["desktop mode", "light mode"],
      parity: "D§3"
    ),
    global("desktop.reduce_motion", :desktop, "Reduce motion",
      group: "look",
      storage: {:setting, :reduce_motion},
      type: :toggle,
      default: false,
      applies: :desktop,
      desktop_only: true,
      shared: true,
      parity: "D§3"
    ),
    global("desktop.bench_layout", :desktop, "Consensus card",
      group: "look",
      storage: {:setting, :bench_layout},
      type: :enum,
      choices:
        choices([
          {"scales", "Scales"},
          {"rail", "Rail — the checks on a rail"},
          {"spine", "Spine — one node per phase"},
          {"scorecard", "Scorecard — checks × rounds"}
        ]),
      default: "scales",
      applies: :desktop,
      desktop_only: true,
      shared: true,
      parity: "D§3"
    ),
    global("desktop.consensus_layout", :desktop, "Consensus panes",
      group: "look",
      storage: {:setting, :consensus_layout},
      type: :enum,
      choices: choices([{"stacked", "plan above the verdict"}, {"side", "beside it"}]),
      default: "stacked",
      applies: :desktop,
      desktop_only: true,
      shared: true,
      parity: "D§14"
    ),
    global("desktop.focus_on_finish", :desktop, "Bring the window to front when a run finishes",
      group: "look",
      storage: {:setting, :focus_on_finish},
      type: :toggle,
      default: false,
      applies: :desktop,
      desktop_only: true,
      shared: true,
      parity: "D§3"
    ),
    global("desktop.show_global_tasks", :desktop, "Show global scheduled tasks",
      group: "look",
      storage: {:setting, :sidebar_show_global_tasks},
      type: :toggle,
      default: true,
      applies: :desktop,
      desktop_only: true,
      shared: true,
      parity: "D§3"
    ),
    global("desktop.show_reasoning", :desktop, "Expand activity & reasoning by default",
      group: "look",
      storage: {:setting, :show_reasoning},
      type: :toggle,
      default: false,
      applies: :desktop,
      desktop_only: true,
      shared: true,
      parity: "D§3"
    )
  ]

  @key_entries (for {action, label, combo} <- @keys do
                  global("desktop.keys.#{action}", :desktop, "Key · #{label}",
                    group: "keys",
                    storage: {:setting_map, :keybindings, action},
                    type: :combo,
                    nullable: true,
                    null_label: "default (#{combo})",
                    validate: [{:svc, :combo_conflict}],
                    messages: %{
                      combo: "invalid key combo",
                      combo_conflict: "conflict: {a} and {b} are both bound to {combo}"
                    },
                    applies: :desktop,
                    desktop_only: true,
                    shared: true,
                    parity: "D§10"
                  )
                end)

  def entries do
    @look ++
      @key_entries ++
      [
        desk("desktop.sidebar_collapsed", "Sidebar hidden",
          group: "window state",
          storage: {:setting, :sidebar_collapsed},
          type: :toggle,
          default: false,
          parity: "D§14"
        ),
        desk("desktop.sidebar_width", "Sidebar width (px)",
          group: "window state",
          storage: {:setting, :sidebar_width},
          type: :integer,
          unit: :px,
          min: 280,
          max: 440,
          step: 10,
          big_step: 40,
          default: 280,
          parity: "D§14"
        ),
        desk("desktop.sidebar_sections", "Folded sidebar groups",
          group: "window state",
          storage: {:setting, :sidebar_sections},
          type: :map_readonly,
          default: %{},
          parity: "D§14"
        ),
        desk("desktop.sidebar_scroll", "Sidebar scroll (px)",
          group: "window state",
          storage: {:setting, :sidebar_scroll},
          type: :integer,
          unit: :px,
          min: 0,
          step: 10,
          big_step: 100,
          default: 0,
          validate: [{:min, 0}],
          parity: "D§14"
        ),
        desk("desktop.pane_view", "Agents pane tab",
          group: "window state",
          storage: {:setting, :pane_view},
          type: :enum,
          choices: choices(["cards", "timeline", "changes"]),
          default: "cards",
          parity: "D§14"
        ),
        desk("desktop.agents_view", "Agents layout",
          group: "window state",
          storage: {:setting, :agents_view},
          type: :enum,
          choices: choices(["tree", "grid"]),
          default: "tree",
          parity: "D§14"
        ),
        desk("desktop.agents_density", "Agent card density",
          group: "window state",
          storage: {:setting, :agents_density},
          type: :enum,
          choices: choices(["full", "compact"]),
          default: "full",
          parity: "D§14"
        ),
        px(
          "desktop.side_w_2col",
          "Side chat width, two columns (px)",
          :side_w_2col,
          320,
          1200,
          440
        ),
        px(
          "desktop.side_w_3col",
          "Side chat width, three columns (px)",
          :side_w_3col,
          320,
          1200,
          380
        ),
        px("desktop.pane_w", "Agents pane width (px)", :pane_w, 300, 1200, 420),
        px_nullable(
          "desktop.composer_h",
          "Composer height (px)",
          :composer_h,
          "grows with the text"
        ),
        px_nullable(
          "desktop.side_composer_h",
          "Side composer height (px)",
          :side_composer_h,
          "grows with the text"
        ),
        desk("desktop.prompt_size", "Prompt drawer size",
          group: "window state",
          storage: {:setting, :prompt_size},
          type: :enum,
          choices: choices(["sm", "md", "lg"]),
          default: "md",
          parity: "D§14"
        )
      ]
  end

  defp px(key, label, field, min, max, default) do
    desk(key, label,
      group: "window state",
      storage: {:setting, field},
      type: :integer,
      unit: :px,
      min: min,
      max: max,
      step: 10,
      big_step: 100,
      default: default,
      validate: [{:min, min}, {:max, max}],
      messages: @px_between,
      parity: "D§14"
    )
  end

  defp px_nullable(key, label, field, null_label) do
    desk(key, label,
      group: "window state",
      storage: {:setting, field},
      type: :integer,
      unit: :px,
      min: 44,
      max: 900,
      step: 10,
      big_step: 100,
      nullable: true,
      null_label: null_label,
      validate: [{:min, 44}, {:max, 900}],
      parity: "D§14"
    )
  end
end
