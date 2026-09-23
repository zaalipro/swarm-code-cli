defmodule SwarmCode.Domain.Settings.Setting do
  @moduledoc """
  Singleton application settings row.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "settings" do
    field(:theme, :string, default: "carbon")
    field(:mode, :string, default: "dark")
    field(:sidebar_collapsed, :boolean, default: false)
    field(:sidebar_width, :integer, default: 280)
    field(:reduce_motion, :boolean, default: false)
    field(:default_effort, :string, default: "medium")
    field(:default_swarm_effort, :string, default: "medium")
    field(:monthly_budget_usd, :float)
    field(:show_reasoning, :boolean, default: false)
    field(:pane_view, :string, default: "cards")
    field(:agents_view, :string, default: "tree")
    # Spec 17 §3.1: the dragged widths, per layout.
    field(:side_w_2col, :integer, default: 440)
    field(:side_w_3col, :integer, default: 380)
    field(:pane_w, :integer, default: 420)
    # Spec 22 §1.5: null means auto-grow; a number is a height the user dragged.
    field(:composer_h, :integer)
    field(:side_composer_h, :integer)
    # Spec 22 §5.3: how much of an agent's prompt the Prompt drawer shows.
    field(:prompt_size, :string, default: "md")
    field(:tavily_api_key, :string)
    field(:max_concurrent_agents, :integer, default: 4)
    field(:max_agent_depth, :integer, default: 2)
    field(:max_agent_turns, :integer, default: 60)
    # spec 67 T29 (G38): a sub-agent's wall clock. 0 = wait for ever, which is
    # what `spawn_agent` did before this task — one stalled child held its lead,
    # and the lead's own awaiting parent, for the life of the run.
    field(:sub_agent_timeout_s, :integer, default: 1800)
    field(:command_timeout_ms, :integer, default: 120_000)
    field(:tool_timeout_ms, :integer, default: 120_000)
    field(:worktrees_enabled, :boolean, default: true)
    field(:default_chat_provider_id, :binary_id)
    field(:default_chat_model, :string)
    field(:default_swarm_provider_id, :binary_id)
    field(:default_swarm_model, :string)
    field(:pricing, :map, default: %{})
    # Which sidebar sections are folded away, e.g. %{"tasks" => true} (§22).
    field(:sidebar_sections, :map, default: %{})
    field(:sidebar_show_global_tasks, :boolean, default: true)
    field(:agents_density, :string, default: "full")
    field(:default_scheduled_provider_id, :binary_id)
    field(:default_scheduled_model, :string)
    field(:default_scheduled_effort, :string)
    field(:workflow_budget, :integer, default: 128)
    field(:workflow_max_live, :integer, default: 16)
    field(:default_workflow_provider_id, :binary_id)
    field(:default_workflow_model, :string)
    field(:default_workflow_effort, :string)
    # Spec 10 §14: only with this on does a finished run raise the window.
    field(:focus_on_finish, :boolean, default: false)
    # Spec 24 §5.3: deep research.
    field(:research_level, :string, default: "medium")
    # Spec 48 §5: ten is Ultra's whole fan-out. At 6 every Ultra round ran in two
    # waves — twice the wall time of a High round for no extra depth — and the
    # HTTP side carries it: Req's Finch pools are 50 connections per host.
    field(:research_max_live, :integer, default: 10)
    field(:research_max_sources, :integer, default: 5)
    field(:research_recency_days, :integer)
    field(:research_include_domains, {:array, :string}, default: [])
    field(:research_exclude_domains, {:array, :string}, default: [])
    field(:research_reader, :string, default: "web_fetch")
    # Spec 48 §2: when the designed HTML report is built. "deep" = automatically
    # on medium/high/ultra (Fastest stays manual), "all" = Fastest too, "never" =
    # only from the button. It always runs *after* the research is done.
    field(:research_auto_design, :string, default: "deep")
    field(:research_lead_provider_id, :binary_id)
    field(:research_lead_model, :string)
    field(:research_lead_effort, :string)
    field(:research_worker_provider_id, :binary_id)
    field(:research_worker_model, :string)
    field(:research_worker_effort, :string)
    field(:research_reporter_provider_id, :binary_id)
    field(:research_reporter_model, :string)
    field(:research_reporter_effort, :string)
    # Spec 39 §2.3: the per-round headline agent can be turned off.
    field(:research_headlines, :boolean, default: true)
    # Spec 40 §2.4: the consensus card's panes — plan above the verdict, or
    # beside it. §3.3: where the sidebar was scrolled to.
    field(:consensus_layout, :string, default: "stacked")
    # Spec 57 §7: the pane's consensus card layout — scales | rail | spine | scorecard.
    field(:bench_layout, :string, default: "scales")
    field(:sidebar_scroll, :integer, default: 0)
    # Spec 40 §1.6: a research agent's wall clock, and what happens past it.
    field(:research_agent_timeout_s, :integer, default: 600)
    field(:research_retry_timeouts, :boolean, default: true)
    field(:research_max_retries, :integer, default: 1)
    # Spec 45 §4.1: the consensus implementer's defaults — nil = the planner
    # implements.
    field(:default_implementer_provider_id, :binary_id)
    field(:default_implementer_model, :string)
    field(:default_implementer_effort, :string)
    # Spec 49 §2: the retention policy the Scheduler applies once a day. nil is
    # off for both; `storage_last_cleanup_at` is when the sweep last ran.
    field(:storage_retention_days, :integer)
    field(:storage_prune_days, :integer)
    field(:storage_last_cleanup_at, :utc_datetime_usec)
    # spec 66 T6: Erlang's `{env, …}` extends the BEAM's environment, so every
    # key the app was launched with reached `env` in the model's shell.
    field(:shell_env_scrub, :boolean, default: true)
    field(:shell_env_keep, {:array, :string}, default: ["GITHUB_TOKEN", "GH_TOKEN"])
    # spec 66 T7: nil = detect the user's `$SHELL`; a login shell is what has
    # mise/asdf/nvm/brew on `PATH` inside a packaged `.app`.
    field(:shell_path, :string)
    field(:shell_login, :boolean, default: true)
    # spec 70 B4: per-language LSP server command overrides.
    field(:lsp_servers, :map, default: %{})

    # spec 70 E3: user-configurable keybindings. JSON-encoded map where keys
    # are action names and values are key-combo strings.
    field(:keybindings, :map, default: %{})

    # spec 72 D1: isolation backend for sub-agents.
    field(:isolation_backend, :string, default: "auto")

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(theme mode sidebar_collapsed sidebar_width reduce_motion default_effort
             default_swarm_effort
             monthly_budget_usd show_reasoning pane_view agents_view
             side_w_2col side_w_3col pane_w composer_h side_composer_h prompt_size
             tavily_api_key
             max_concurrent_agents
             max_agent_depth max_agent_turns sub_agent_timeout_s
             command_timeout_ms tool_timeout_ms worktrees_enabled
             default_chat_provider_id
             default_chat_model default_swarm_provider_id default_swarm_model pricing
             sidebar_sections sidebar_show_global_tasks agents_density
             default_scheduled_provider_id default_scheduled_model default_scheduled_effort
             workflow_budget workflow_max_live default_workflow_provider_id
             default_workflow_model default_workflow_effort focus_on_finish
             research_level research_max_live research_max_sources research_recency_days
             research_include_domains research_exclude_domains research_reader
             research_auto_design
             research_lead_provider_id research_lead_model research_lead_effort
             research_worker_provider_id research_worker_model research_worker_effort
             research_reporter_provider_id research_reporter_model research_reporter_effort
             research_headlines consensus_layout bench_layout sidebar_scroll
             research_agent_timeout_s research_retry_timeouts research_max_retries
             default_implementer_provider_id default_implementer_model
             default_implementer_effort
             storage_retention_days storage_prune_days storage_last_cleanup_at
             shell_env_scrub shell_env_keep shell_path shell_login
             lsp_servers keybindings isolation_backend)a

  # Spec 45 §3.6: a default effort can be a custom key of the default chat
  # provider's list, so the columns take any well-formed key.
  @effort_fields ~w(default_effort default_swarm_effort default_scheduled_effort
                    default_workflow_effort research_lead_effort research_worker_effort
                    research_reporter_effort default_implementer_effort)a

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, @fields)
    |> validate_inclusion(:theme, ~w(carbon obsidian graphite aurora ember fjord dusk paper))
    |> validate_efforts()
    |> validate_inclusion(:agents_density, ["full", "compact"])
    |> validate_inclusion(:research_level, ["low", "medium", "high", "ultra"])
    |> validate_inclusion(:research_reader, ["web_fetch", "jina", "firecrawl"])
    |> validate_inclusion(:research_auto_design, ["deep", "all", "never"])
    # spec 72 D1: isolation backend for sub-agents.
    |> validate_inclusion(:isolation_backend, ~w(auto clone worktree))
    # spec 66 T7: blank means "detect"; a path that is not a file would silently
    # fall back to /bin/sh, so it is refused where the user can still see it.
    |> update_change(:shell_path, fn path ->
      case String.trim(to_string(path || "")) do
        "" -> nil
        trimmed -> trimmed
      end
    end)
    # spec 67 B26: `File.regular?/1` also says yes to `/etc/hosts`, and a shell
    # that cannot be executed made `Port.open/2` raise `:eacces` on every single
    # command of the run. The execute bit is part of "is this a shell".
    |> validate_change(:shell_path, fn :shell_path, path ->
      cond do
        SwarmCode.Domain.Tools.RunCommand.executable?(path) -> []
        File.regular?(path) -> [shell_path: "is not an executable file"]
        true -> [shell_path: "is not a file on this machine"]
      end
    end)
    # spec 66 T6: names only, no values — `["GITHUB_TOKEN", "GH_TOKEN"]`.
    |> update_change(:shell_env_keep, fn names ->
      names
      |> List.wrap()
      |> Enum.flat_map(&String.split(to_string(&1), ","))
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    end)
    |> validate_inclusion(:consensus_layout, ["stacked", "side"])
    |> validate_inclusion(:bench_layout, ["scales", "rail", "spine", "scorecard"])
    |> validate_number(:research_agent_timeout_s,
      greater_than_or_equal_to: 60,
      less_than_or_equal_to: 3600,
      message: "must be between 60 and 3600"
    )
    # spec 67 T29: 0 is "wait for ever"; anything else is at least a minute,
    # because a shorter clock kills a sub-agent that is only thinking, and at
    # most a day.
    |> validate_number(:sub_agent_timeout_s,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 86_400,
      message: "must be 0 (no limit) or between 60 and 86400"
    )
    |> validate_change(:sub_agent_timeout_s, fn :sub_agent_timeout_s, seconds ->
      if seconds == 0 or seconds >= 60,
        do: [],
        else: [sub_agent_timeout_s: "must be 0 (no limit) or between 60 and 86400"]
    end)
    |> validate_number(:research_max_retries,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 3,
      message: "must be between 0 and 3"
    )
    |> validate_number(:sidebar_scroll, greater_than_or_equal_to: 0)
    # Spec 49 §2: a retention window is a whole number of days, at least a week
    # (nothing shorter is a policy — it is a mistake).
    |> validate_number(:storage_retention_days,
      greater_than_or_equal_to: 7,
      less_than_or_equal_to: 3650,
      message: "must be between 7 and 3650"
    )
    |> validate_number(:storage_prune_days,
      greater_than_or_equal_to: 7,
      less_than_or_equal_to: 3650,
      message: "must be between 7 and 3650"
    )
    |> validate_number(:research_max_live,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 32,
      message: "must be between 1 and 32"
    )
    |> validate_number(:research_max_sources,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 20,
      message: "must be between 1 and 20"
    )
    |> validate_number(:research_recency_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3650,
      message: "must be between 1 and 3650"
    )
    |> validate_number(:workflow_budget,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 1024,
      message: "must be between 1 and 1024"
    )
    |> validate_number(:workflow_max_live,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 64,
      message: "must be between 1 and 64"
    )
    |> validate_number(:sidebar_width,
      greater_than_or_equal_to: 280,
      less_than_or_equal_to: 440,
      message: "must be between 280 and 440"
    )
    |> validate_number(:monthly_budget_usd,
      greater_than_or_equal_to: 0,
      message: "must be zero or more"
    )
    |> validate_inclusion(:mode, ["dark", "light"])
    |> validate_inclusion(:pane_view, ["cards", "timeline", "changes"])
    |> validate_inclusion(:agents_view, ["tree", "grid"])
    |> validate_number(:side_w_2col, greater_than_or_equal_to: 320, less_than_or_equal_to: 1200)
    |> validate_number(:side_w_3col, greater_than_or_equal_to: 320, less_than_or_equal_to: 1200)
    |> validate_number(:pane_w, greater_than_or_equal_to: 300, less_than_or_equal_to: 1200)
    |> validate_inclusion(:prompt_size, ["sm", "md", "lg"])
    |> validate_number(:composer_h, greater_than_or_equal_to: 44, less_than_or_equal_to: 900)
    |> validate_number(:side_composer_h, greater_than_or_equal_to: 44, less_than_or_equal_to: 900)
    |> validate_number(:max_concurrent_agents,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 16,
      message: "must be between 1 and 16"
    )
    |> validate_number(:max_agent_depth,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 3,
      message: "must be between 1 and 3"
    )
    |> validate_number(:max_agent_turns,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 200,
      message: "must be between 1 and 200"
    )
    |> validate_number(:command_timeout_ms,
      greater_than_or_equal_to: 1000,
      less_than_or_equal_to: 600_000,
      message: "must be between 1000 and 600000"
    )
    |> validate_number(:tool_timeout_ms,
      greater_than_or_equal_to: 1000,
      less_than_or_equal_to: 600_000,
      message: "must be between 1000 and 600000"
    )
    |> validate_change(:pricing, fn :pricing, map ->
      rates? =
        is_map(map) and
          Enum.all?(map, fn
            {_model, %{"input" => input, "output" => output}} ->
              is_number(input) and is_number(output)

            _ ->
              false
          end)

      cond do
        not rates? ->
          [pricing: "must be a number"]

        # spec 66 T13
        not Enum.all?(map, fn {_model, row} -> context_window?(row) end) ->
          [pricing: "context_window must be a whole number between 8000 and 2000000"]

        true ->
          []
      end
    end)
    # spec 70 B4: lsp_servers must be a map of string keys to string values.
    |> validate_change(:lsp_servers, fn :lsp_servers, map ->
      cond do
        not is_map(map) ->
          [lsp_servers: "must be a map"]

        not Enum.all?(map, fn {k, v} -> is_binary(k) and is_binary(v) end) ->
          [lsp_servers: "every key and value must be a string"]

        true ->
          []
      end
    end)
    # spec 70 E3: validate keybindings map
    |> validate_keybindings()
  end

  # spec 70 E3: the actions the keybindings map may contain.
  @keybind_actions ~w(sidebar new search settings quit side nudge_left nudge_right file_finder)

  @combo_re ~r"^(meta|ctrl|shift|alt)(\+(meta|ctrl|shift|alt))*\+[a-zA-Z0-9,.;=\-]$"

  defp validate_keybindings(changeset) do
    validate_change(changeset, :keybindings, fn :keybindings, bindings ->
      cond do
        not is_map(bindings) ->
          [keybindings: "must be a map"]

        not Enum.all?(Map.keys(bindings), &(&1 in @keybind_actions)) ->
          unknown = Enum.reject(Map.keys(bindings), &(&1 in @keybind_actions))
          [keybindings: "unknown action: #{Enum.join(unknown, ", ")}"]

        not Enum.all?(Map.values(bindings), &valid_combo?/1) ->
          [keybindings: "invalid key combo"]

        true ->
          check_duplicate_combos(bindings)
      end
    end)
  end

  defp valid_combo?("Escape"), do: true

  defp valid_combo?(combo) when is_binary(combo) do
    # Allow Arrow keys and single-char keys with modifiers
    Regex.match?(@combo_re, combo) or
      Regex.match?(
        ~r/^(meta|ctrl|shift|alt)(\+(meta|ctrl|shift|alt))*\+Arrow(Left|Right|Up|Down)$/,
        combo
      )
  end

  defp valid_combo?(_), do: false

  defp check_duplicate_combos(bindings) do
    # Merge with defaults to detect cross-map conflicts
    defaults = SwarmCode.Domain.Settings.default_keybindings()
    effective = Map.merge(defaults, bindings)

    effective
    |> Enum.group_by(fn {_action, combo} -> combo end, fn {action, _combo} -> action end)
    |> Enum.find(fn {_combo, actions} -> length(actions) > 1 end)
    |> case do
      {combo, [a1, a2 | _]} ->
        [keybindings: "conflict: #{a1} and #{a2} are both bound to #{combo}"]

      nil ->
        []
    end
  end

  defp validate_efforts(changeset) do
    Enum.reduce(@effort_fields, changeset, fn field, cs ->
      validate_format(cs, field, SwarmCode.Domain.LLM.Efforts.key_format())
    end)
  end

  # spec 66 T13: a pricing row may carry the model's real context window beside
  # its rates. Optional; when it is there it is a whole number of tokens in a
  # range no real model is outside of (`SwarmCode.Domain.Engine.Context.budget/2`
  # spends 75 % of it).
  defp context_window?(%{"context_window" => v}),
    do: is_integer(v) and v >= 8_000 and v <= 2_000_000

  defp context_window?(_row), do: true
end
