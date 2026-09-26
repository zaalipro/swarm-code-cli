defmodule SwarmCodeCLI.UI.Settings.Sections.Overview do
  @moduledoc """
  The Overview page (spec §2.1, §4.14, frame F1): where `/settings` lands.
  Pure: every row is built from the `Settings.Ctx`.

    * *needs attention* — the service's items (`overview.attention`) and
      the client's (AT13 cli.json, AT14 key overrides), errors first then
      rail order, at most 8; Enter goes where the item points (a row, a
      record, a section). The strip on every page counts the same list, so
      it is built from data alone (no section module is asked).
    * *at a glance* — one line per `overview.glance` fragment; Enter opens
      its section.
    * *changed from default* — the first 9 values whose winning layer is not
      the default (the strongest layers first), as ordinary setting rows
      (Enter edits, `r` resets), then `… N more`, which opens the search on
      `@modified`.
    * *where values come from* — how many values each layer supplies now,
      with the names or the words that say what the layer is.
    * *changed in this session* — the newest 6 entries of
      `State.settings_history` (so it survives closing the layer, D38).

  `summary/1` is the strip on the search row: changed, attention, from env.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :overview

  alias SwarmCode.Settings.{CliFile, Entry, Registry}

  alias SwarmCodeCLI.UI.Settings.{
    Attention,
    Ctx,
    DeepLink,
    Detail,
    Display,
    Provenance,
    Row,
    Rows
  }

  alias SwarmCodeCLI.UI.Settings.{Sections, Undo}

  @attention_shown 8
  @changed_shown 9
  @history_shown 6
  @names_shown 3
  @gauge_cells 16

  @glance_order ~w(providers search mcp agents approvals storage budget)
  @glance_sections %{
    "providers" => :providers,
    "search" => :search_web,
    "mcp" => :mcp,
    "agents" => :agents_limits,
    "approvals" => :approvals,
    "storage" => :storage,
    "budget" => :budget
  }
  @glance_labels %{"mcp" => "MCP"}

  @layers [:flag, :env, :session, :project, :cli, :global, :project_file, :default]
  @layer_words %{
    flag: "flag",
    env: "env",
    session: "session",
    project: "project",
    cli: "cli.json",
    global: "global",
    project_file: "project file",
    default: "default"
  }

  @cli_errors [:unreadable, :not_json, :symlink]

  @impl true
  def loads(_ctx), do: [:overview]

  @impl true
  def rows(%Ctx{} = ctx) do
    values = values(ctx)

    attention_rows(ctx) ++
      glance_rows(ctx) ++
      changed_rows(ctx, values) ++ source_rows(ctx, values) ++ history_rows(ctx)
  end

  @impl true
  def act(_ctx, %Row{target: {:overview, target}}, :open_row), do: [{:goto, target}]
  def act(_ctx, %Row{target: {:overview_search, query}}, :open_row), do: [{:search, query}]
  def act(_ctx, _row, _action), do: :default

  @impl true
  def attention(%Ctx{} = ctx), do: cli_attention(ctx) ++ key_attention(ctx)

  @doc """
  What the search row's strip counts on every page: values changed from
  their defaults, attention items and values an environment variable sets.
  """
  @spec summary(Ctx.t()) :: %{
          changed: non_neg_integer(),
          attention: non_neg_integer(),
          env: non_neg_integer()
        }
  def summary(%Ctx{} = ctx) do
    winners = ctx |> values() |> Enum.map(fn {_entry, setting} -> winner(setting) end)

    %{
      changed: Enum.count(winners, &changed?/1),
      attention: length(items(ctx)),
      env: Enum.count(winners, &(&1 == :env))
    }
  end

  @doc "Every attention item the page lists, sorted (errors first, then rail order)."
  @spec items(Ctx.t()) :: [Attention.t()]
  def items(%Ctx{} = ctx) do
    service = ctx |> overview() |> Map.get(:attention, []) |> Enum.map(&from_service/1)

    # One per source and target: two failed servers are two AT1 items (QA F-9).
    (service ++ attention(ctx))
    |> Enum.filter(&match?(%Attention{}, &1))
    |> Enum.uniq_by(&{&1.id, &1.target})
    |> Attention.sort(Sections.order())
  end

  # ---------------------------------------------------------- attention

  defp attention_rows(ctx) do
    items = items(ctx)
    count = length(items)
    shown = Enum.take(items, @attention_shown)
    tag = if count > 0, do: [{Integer.to_string(count), :warning}], else: []

    body =
      cond do
        shown != [] ->
          Enum.map(shown, &attention_row/1) ++ more_attention(count)

        overview(ctx) == %{} ->
          [Row.info("attention_loading", "Looking for what needs you…")]

        true ->
          [Row.info("attention_none", "Nothing needs your attention.")]
      end

    [Row.heading("needs attention", tag) | body]
  end

  defp attention_row(%Attention{} = item) do
    %Row{
      id: "att:" <> item.id,
      kind: :link,
      label: "",
      value: [{item.title, :text_primary}],
      tag: if(item.target, do: [{"Enter", {:info, [:bold]}}, {" open", :text_faint}], else: []),
      marks: [:attention],
      lines: if(blank?(item.reason), do: [], else: [[{item.reason, :text_muted}]]),
      keys: if(item.target, do: [{"Enter", :enter, "open"}], else: []),
      detail: attention_detail(item),
      target: if(item.target, do: {:overview, item.target}, else: nil)
    }
  end

  defp attention_detail(%Attention{} = item) do
    %Detail{
      title: item.title,
      description: item.reason || "",
      facts: [
        {"severity", Atom.to_string(item.severity)},
        {"section", Sections.title(item.section)}
      ],
      actions: if(item.target, do: [{"Enter", "open #{where(item.target)}"}], else: [])
    }
  end

  defp where({:section, id}), do: Sections.title(id)

  defp where({:key, key}) do
    case Registry.fetch(key) do
      {:ok, entry} -> "#{entry.label} in #{Sections.title(entry.section)}"
      :error -> key
    end
  end

  defp where({:record, kind, _id}),
    do: "it in " <> Sections.title(DeepLink.record_section(kind) || :overview)

  defp more_attention(count) when count > @attention_shown,
    do: [Row.info("attention_more", [{"… #{count - @attention_shown} more", :text_faint}])]

  defp more_attention(_count), do: []

  defp from_service(%{} = item) do
    section = Map.get(item, :section) || :overview

    %Attention{
      id: to_string(Map.get(item, :id) || Map.get(item, :title)),
      severity: if(Map.get(item, :severity) == :error, do: :error, else: :warning),
      section: section,
      target: target(Map.get(item, :target), section),
      title: Map.get(item, :title) || "",
      reason: Map.get(item, :reason) || ""
    }
  end

  defp target(%{key: key}, _section) when is_binary(key), do: {:key, key}

  defp target(%{kind: kind, id: id}, section) when is_binary(kind) and is_binary(id) do
    if DeepLink.record_section(kind), do: {:record, kind, id}, else: section_target(section)
  end

  defp target(_target, section), do: section_target(section)

  defp section_target(section) when is_atom(section) and section not in [nil, :overview],
    do: {:section, section}

  defp section_target(_section), do: nil

  # AT13: what the runtime's read of cli.json found.
  defp cli_attention(%Ctx{data: %{cli: cli}}), do: cli_items(cli)
  defp cli_attention(_ctx), do: []

  # A session that keeps no cli.json (the demo, a test) has nothing to fix.
  defp cli_items({:error, :unavailable}), do: []

  defp cli_items({:error, _reason}),
    do: [cli_item("cli:unreadable", :error, CliFile.words(:unreadable), reset_words())]

  defp cli_items(%{status: status}) when status in @cli_errors,
    do: [cli_item("cli:#{status}", :error, CliFile.words(status), reset_words())]

  defp cli_items(%{status: :too_large}),
    do: [cli_item("cli:too_large", :warning, CliFile.words(:too_large), reset_words())]

  defp cli_items(%{} = cli) do
    mode = Map.get(cli, :mode)
    invalid = Map.get(cli, :invalid) || []

    open =
      if is_integer(mode) and Bitwise.band(mode, 0o077) != 0,
        do: [
          cli_item(
            "cli:mode",
            :warning,
            "cli.json is readable by other users (#{octal(mode)})",
            "only you should read it · chmod 600"
          )
        ]

    bad =
      if invalid != [],
        do: [
          cli_item(
            "cli:invalid",
            :warning,
            "#{count(length(invalid), "value", "values")} in cli.json #{if length(invalid) == 1, do: "is", else: "are"} not understood",
            names(invalid) <> " · the defaults answer instead"
          )
        ]

    List.wrap(open) ++ List.wrap(bad)
  end

  defp cli_items(_cli), do: []

  defp reset_words, do: "the terminal uses its defaults until it is fixed"

  defp cli_item(id, severity, title, reason),
    do: %Attention{
      id: id,
      severity: severity,
      section: :files_env,
      target: {:section, :files_env},
      title: title,
      reason: reason
    }

  defp octal(mode),
    do: "0" <> String.pad_leading(Integer.to_string(Bitwise.band(mode, 0o777), 8), 3, "0")

  # AT14: key overrides the keymap could not use.
  defp key_attention(%Ctx{overrides: %{errors: [_ | _] = errors}}) do
    n = length(errors)
    {id, reason} = hd(errors)

    [
      %Attention{
        id: "keys:ignored",
        severity: :warning,
        section: :keys,
        target: {:section, :keys},
        title:
          if(n == 1,
            do: "1 key override in cli.json was ignored",
            else: "#{n} key overrides in cli.json were ignored"
          ),
        reason: "#{id}: #{reason}"
      }
    ]
  end

  defp key_attention(_ctx), do: []

  # ------------------------------------------------------------- glance

  defp glance_rows(ctx) do
    glance = Map.get(overview(ctx), :glance) || %{}
    names = @glance_order ++ (glance |> Map.keys() |> Enum.sort() |> Kernel.--(@glance_order))

    rows =
      for name <- names,
          %{} = fragment <- [Map.get(glance, name)],
          words = glance_words(name, fragment, ctx),
          words != [] do
        section = Map.get(@glance_sections, name)

        %Row{
          id: "info:glance:" <> name,
          kind: :info,
          label: Map.get(@glance_labels, name, name),
          value: words,
          state: :readonly,
          keys: if(section, do: [{"Enter", :enter, "open #{Sections.title(section)}"}], else: []),
          target: if(section, do: {:overview, {:section, section}}, else: nil)
        }
      end

    if rows == [], do: [], else: [Row.heading("at a glance") | rows]
  end

  defp glance_words("providers", g, _ctx) do
    parts([
      number(g["count"]),
      counted(g["answered"], "answered their last test"),
      counted(g["never_tested"], "never tested"),
      counted(g["usable"], "usable"),
      text(g["chat"], &"chat #{&1}")
    ])
  end

  defp glance_words("search", g, _ctx) do
    on =
      cond do
        is_list(g["names"]) and g["names"] != [] ->
          Enum.join(g["names"], " and ") <> " on"

        is_integer(g["enabled"]) and is_integer(g["total"]) ->
          "#{g["enabled"]} of #{g["total"]} engines on"

        is_integer(g["enabled"]) ->
          "#{g["enabled"]} on"

        true ->
          nil
      end

    parts([
      on,
      # QA #2 P2-4: the engines by their labels, not their ids
      text(g["first"], &"#{SwarmCodeCLI.UI.Settings.Sections.SearchWeb.label(&1)} first"),
      text(
        g["reader"],
        &"pages through #{SwarmCodeCLI.UI.Settings.Sections.SearchWeb.label(&1)}"
      ),
      counted(g["off"], "off")
    ])
  end

  defp glance_words("mcp", g, _ctx) do
    tools =
      case {g["tools"], g["tools_off"]} do
        {n, off} when is_integer(n) and is_integer(off) and off > 0 ->
          "#{n} tools, #{off} switched off"

        {n, _} when is_integer(n) ->
          count(n, "tool", "tools")

        _ ->
          nil
      end

    parts([
      if(is_integer(g["servers"]), do: count(g["servers"], "server", "servers")),
      counted(g["connected"], "connected"),
      counted(g["failed"], "failed"),
      tools
    ])
  end

  defp glance_words("agents", g, _ctx) do
    parts([
      text(g["max_concurrent"], &"#{&1} at once"),
      text(g["max_depth"], &"depth #{&1}"),
      text(g["max_turns"], &"#{&1} turns"),
      text(g["each"], &"#{&1} each")
    ])
  end

  defp glance_words("approvals", g, ctx) do
    project = g["project"] || (ctx.project && ctx.project["name"])

    # The mode in words (`read-only`, `auto`, `full access`), never the column value.
    mode =
      cond do
        is_binary(g["mode"]) and is_binary(project) -> "#{project}: #{mode_words(g["mode"])}"
        is_binary(g["mode"]) -> mode_words(g["mode"])
        true -> nil
      end

    trusted =
      case g["trusted"] do
        true -> "trusted"
        false -> "not trusted"
        _ -> nil
      end

    parts([
      mode,
      trusted,
      if(is_integer(g["allowed"]),
        do: count(g["allowed"], "always-allowed command", "always-allowed commands")
      )
    ])
  end

  defp glance_words("storage", g, _ctx) do
    parts([
      if(is_integer(g["database_bytes"]), do: bytes(g["database_bytes"])),
      if(is_integer(g["sessions"]), do: count(g["sessions"], "session", "sessions")),
      cleanup(g)
    ])
  end

  defp glance_words("budget", g, _ctx) do
    spent = g["spend_usd"]
    budget = g["budget_usd"]

    cond do
      is_number(spent) and is_number(budget) and budget > 0 ->
        filled = min(@gauge_cells, round(@gauge_cells * spent / budget))

        [
          {"#{money(spent)} of #{money(budget)} this month    ", :text_primary},
          {String.duplicate("▰", filled), if(spent > budget, do: :warning, else: :text_muted)},
          {String.duplicate("▱", @gauge_cells - filled), :text_ghost}
        ]

      is_number(spent) ->
        [{"#{money(spent)} this month · no budget set", :text_primary}]

      true ->
        []
    end
  end

  defp glance_words(_name, g, _ctx) do
    g
    |> Enum.sort()
    |> Enum.map(fn {key, value} -> "#{String.replace(key, "_", " ")} #{Display.words(value)}" end)
    |> parts()
  end

  defp cleanup(%{"cleanup_days" => 0}), do: "last cleanup today"
  defp cleanup(%{"cleanup_days" => 1}), do: "last cleanup yesterday"

  defp cleanup(%{"cleanup_days" => days}) when is_integer(days),
    do: "last cleanup #{days} days ago"

  defp cleanup(%{"last_sweep" => sweep}) when is_binary(sweep), do: "last sweep #{sweep}"
  defp cleanup(%{"cleanup_days" => nil}), do: "never cleaned up"
  defp cleanup(_g), do: nil

  defp parts(list) do
    case Enum.reject(list, &(&1 in [nil, ""])) do
      [] -> []
      words -> [{Enum.join(words, " · "), :text_primary}]
    end
  end

  defp number(n) when is_integer(n), do: Integer.to_string(n)
  defp number(_n), do: nil

  defp counted(n, words) when is_integer(n) and n > 0, do: "#{n} #{words}"
  defp counted(_n, _words), do: nil

  defp text(value, fun) when is_binary(value) and value != "", do: fun.(value)
  defp text(value, fun) when is_number(value), do: fun.(Display.words(value))
  defp text(_value, _fun), do: nil

  defp money(value) when is_number(value),
    do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp bytes(n) when n >= 1_000_000_000, do: one_decimal(n / 1_000_000_000) <> " GB"
  defp bytes(n) when n >= 1_000_000, do: one_decimal(n / 1_000_000) <> " MB"
  defp bytes(n) when n >= 1_000, do: one_decimal(n / 1_000) <> " KB"
  defp bytes(n), do: "#{n} B"

  defp one_decimal(x) do
    rounded = Float.round(x, 1)

    if rounded == Float.round(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: :erlang.float_to_binary(rounded, decimals: 1)
  end

  # ------------------------------------------------ changed from default

  # The values most likely to surprise first: what one launch, the
  # environment, this conversation or this project set, then cli.json and
  # the global rows; rail order inside a layer.
  defp changed_rows(ctx, values) do
    strength = @layers |> Enum.with_index() |> Map.new()

    changed =
      values
      |> Enum.filter(fn {_entry, setting} -> changed?(winner(setting)) end)
      |> Enum.with_index()
      |> Enum.sort_by(fn {{_entry, setting}, n} ->
        {Map.get(strength, winner(setting), 99), n}
      end)
      |> Enum.map(&elem(&1, 0))

    total = length(changed)

    rows =
      changed
      |> Enum.take(@changed_shown)
      |> Enum.map(fn {entry, setting} -> changed_row(ctx, entry, setting) end)

    more =
      if total > @changed_shown,
        do: [
          Row.info("changed_more", [{"… #{total - @changed_shown} more", :text_faint}],
            target: {:overview_search, "@modified"},
            keys: [{"Enter", :enter, "list every one"}]
          )
        ],
        else: []

    body =
      if total == 0,
        do: [Row.info("changed_none", "Every value is its default.")],
        else: rows ++ more

    tag =
      if total > 0,
        do: [
          {"#{total} · ", :text_faint},
          {"@modified", :text_muted},
          {" lists every one", :text_faint}
        ],
        else: []

    [Row.heading("changed from default", tag) | body]
  end

  defp changed_row(ctx, entry, setting) do
    row = Rows.scalar(ctx, entry)
    keep = Enum.any?(row.marks, &(&1 in [:invalid, :conflict]))

    %{
      row
      | value: row.value ++ home_says(ctx, entry, setting),
        lines: if(keep, do: row.lines, else: [])
    }
  end

  # `· cli.json says dark` when an env or flag value wins over the home layer.
  defp home_says(ctx, %Entry{} = entry, setting) do
    home = Enum.find(Map.get(setting, :layers, []), &(Map.get(&1, :layer) == entry.home))

    case {Provenance.overrides(setting, entry), home} do
      {[_ | _], %{set: true, value: value}} ->
        words =
          entry
          |> Display.value(value, nil, Rows.lookups(ctx))
          |> Enum.map_join("", &elem(&1, 0))

        [{" · #{Map.fetch!(@layer_words, entry.home || :global)} says #{words}", :text_faint}]

      _ ->
        []
    end
  end

  # ---------------------------------------------- where values come from

  defp source_rows(ctx, values) do
    by_layer = Enum.group_by(values, fn {_entry, setting} -> winner(setting) end)

    rows =
      Enum.map(@layers, fn layer ->
        won = Map.get(by_layer, layer, [])

        %Row{
          id: "info:source:#{layer}",
          kind: :info,
          label: Map.fetch!(@layer_words, layer),
          value: [
            {String.pad_leading(Integer.to_string(length(won)), 3), :text_primary},
            {"  " <> source_words(ctx, layer, won, values), :text_faint}
          ],
          state: :readonly
        }
      end)

    [
      Row.heading("where values come from", [{"values each layer supplies now", :text_faint}])
      | rows
    ]
  end

  defp source_words(_ctx, :flag, won, _values),
    do: join([listed(won, &source_name/1), "this launch only"])

  defp source_words(_ctx, :env, won, _values), do: listed(won, &source_name/1)

  defp source_words(_ctx, :session, won, _values),
    do: join([listed(won, &short_name/1), "this conversation"])

  defp source_words(ctx, :project, won, _values),
    do: join([listed(won, &short_name/1), ctx.project && ctx.project["name"]])

  defp source_words(_ctx, :cli, won, _values),
    do: join([listed(won, &short_name/1), "this machine's terminal"])

  defp source_words(_ctx, :global, _won, _values), do: "shared with the desktop app"

  defp source_words(_ctx, :project_file, [], values) do
    shadowed =
      Enum.filter(values, fn {_entry, setting} ->
        Enum.any?(Map.get(setting, :layers, []), fn layer ->
          Map.get(layer, :layer) == :project_file and Map.get(layer, :set) == true
        end)
      end)

    case shadowed do
      [] -> ""
      _ -> listed(shadowed, &short_name/1) <> " set there, shadowed"
    end
  end

  defp source_words(_ctx, :project_file, won, _values), do: listed(won, &short_name/1)
  defp source_words(_ctx, :default, _won, _values), do: "built in"

  defp listed([], _fun), do: ""

  defp listed(won, fun) do
    names = won |> Enum.map(fun) |> Enum.uniq()
    shown = Enum.take(names, @names_shown)
    rest = length(names) - length(shown)
    Enum.join(shown, ", ") <> if(rest > 0, do: " +#{rest}", else: "")
  end

  defp join(parts), do: parts |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")

  # `SWARM_THEME`; a flag with the words it was given (`--model deepseek-v4-pro`).
  defp source_name({entry, setting}) do
    case Provenance.winner(setting) do
      %{layer: :flag, source: source, raw: raw}
      when is_binary(source) and is_binary(raw) and raw != "" ->
        source <> " " <> raw

      %{source: source} when is_binary(source) and source != "" ->
        source

      _ ->
        short_name({entry, setting})
    end
  end

  # A cli.json key by its json name; the others by their label without the
  # scope words (`Effort · this conversation` → `effort`).
  defp short_name({%Entry{storage: {:cli, name}}, _setting}), do: name

  defp short_name({%Entry{label: label}, _setting}),
    do: label |> String.split(" · ") |> hd() |> String.downcase()

  # --------------------------------------------- changed in this session

  defp history_rows(%Ctx{state_view: view}) do
    case Map.get(view || %{}, :history) do
      %Undo{changelog: [_ | _] = changelog} = history ->
        tag =
          if Undo.undo?(history),
            do: [{"u", {:info, [:bold]}}, {" undoes the newest", :text_faint}],
            else: []

        rows =
          changelog
          |> Enum.take(@history_shown)
          |> Enum.with_index()
          |> Enum.map(fn {entry, n} ->
            clock = clock(entry.at)

            Row.info(
              "history:#{n}",
              [{if(clock, do: clock <> "  ", else: ""), :text_faint}, {entry.text, :text_muted}]
            )
          end)

        [Row.heading("changed in this session", tag) | rows]

      _ ->
        []
    end
  end

  # A unix-millisecond stamp as the local wall clock, `HH:MM`.
  defp clock(ms) when is_integer(ms) and ms > 0 do
    {{_y, _mo, _d}, {hour, minute, _s}} =
      ms
      |> div(1000)
      |> Kernel.+(62_167_219_200)
      |> :calendar.gregorian_seconds_to_datetime()
      |> :calendar.universal_time_to_local_time()

    pad(hour) <> ":" <> pad(minute)
  end

  defp clock(_ms), do: nil

  defp pad(n), do: String.pad_leading(Integer.to_string(n), 2, "0")

  # ------------------------------------------------------------- shared

  # Every scalar entry with its SettingValue, in rail order (entries whose
  # values have not arrived are left out).
  defp values(ctx) do
    for section <- Sections.ids(),
        %Entry{} = entry <- Registry.for_section(section),
        Entry.scalar?(entry),
        entry.type not in [:fact, :action, :link],
        %{} = setting <- [Rows.setting(ctx, entry)],
        do: {entry, setting}
  end

  defp winner(setting), do: Map.get(setting, :winner)

  defp changed?(winner), do: winner not in [nil, :default]

  defp overview(%Ctx{data: %{overview: %{} = overview}}), do: overview
  defp overview(_ctx), do: %{}

  defp names(list) do
    shown = Enum.take(list, @names_shown)
    rest = length(list) - length(shown)
    Enum.join(shown, ", ") <> if(rest > 0, do: " +#{rest}", else: "")
  end

  defp count(1, one, _many), do: "1 #{one}"
  defp count(n, _one, many), do: "#{n} #{many}"

  defp blank?(text), do: text in [nil, ""]

  defp mode_words(mode) when mode in ["read_only", "auto", "full_access"],
    do: SwarmCodeCLI.UI.Settings.Sections.Approvals.mode_words(mode)

  defp mode_words(mode), do: mode
end
