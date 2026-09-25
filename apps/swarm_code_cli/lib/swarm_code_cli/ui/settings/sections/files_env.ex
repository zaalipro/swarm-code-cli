defmodule SwarmCodeCLI.UI.Settings.Sections.FilesEnv do
  @moduledoc """
  pass74 U3-12 (spec §2.21, §2.25): Files & environment — facts and checks.
  cli.json (its mode — `0600 ✓` or `✗ 0644: others can read it` with
  `▸ Make it private` —, its size against 64 KB, the keys this CLI does not
  know, kept on every write; `e` edits it in the editor through a private
  copy), the database, the config and research folders, the log, this
  project's `.swarm_code/`, your agent definitions, the environment
  variables that feed a setting (secret values only say `set`; Enter goes to
  the setting), this launch, this terminal, the versions, and `▸ Check
  everything`.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :files_env

  alias SwarmCodeCLI.UI.Settings.{Row, Rows}

  @max_bytes 65_536
  @secret ~r/(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)/i
  @developer ~w[SWARM_TEST_EXPECTED SWARM_SCENE_DUMP SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT
                SWARM_CODE_DEMO_AUDIT_FD SWARM_RELEASE_TUI SWARM_RELEASE_MODE SWARM_PERSISTED
                SWARM_CODE_UPSTREAM SWARM_TERMINAL_PORT SWARM_USER_UMASK SWARM_PLAIN_FORMAT
                SWARM_SETTINGS_OPEN SWARM_SETTINGS_ONLY]

  @paths %{
    "files.database" => :database,
    "files.config_dir" => :config_dir,
    "files.project_dir" => :project_dir,
    "files.research" => :research_root,
    "files.user_agents" => :user_agents
  }

  @impl true
  def loads(_ctx), do: [:facts]

  @impl true
  def rows(ctx) do
    ctx
    |> Rows.registry(:files_env)
    |> Enum.flat_map(fn row -> expand(row, ctx) end)
  end

  @impl true
  def attention(ctx) do
    cli = cli(ctx)

    cond do
      is_nil(cli) ->
        []

      get(cli, :status) in [:unreadable, :not_json, "unreadable", "not_json"] ->
        [at13(:error, "cli.json could not be read")]

      get(cli, :status) in [:too_large, "too_large"] ->
        [at13(:error, "cli.json is larger than 64 KB")]

      private?(cli) == false ->
        [at13(:warning, "cli.json is readable by other users (#{octal(get(cli, :mode))})")]

      true ->
        []
    end
  end

  defp at13(severity, title),
    do: %SwarmCodeCLI.UI.Settings.Attention{
      id: "AT13",
      severity: severity,
      section: :files_env,
      target: {:key, "files.cli_json"},
      title: title,
      reason: "Files & environment"
    }

  # --------------------------------------------------------------- actions

  @impl true
  def act(_ctx, %Row{target: {:path, path}}, :copy),
    do: [{:copy, path}, {:toast, "Copied #{path}", :success}]

  def act(_ctx, %Row{target: {:path, path}}, :open_related),
    do: [{:open_folder, Path.dirname(path)}]

  def act(_ctx, %Row{target: {:folder, path}}, :open_related), do: [{:open_folder, path}]

  def act(_ctx, %Row{target: {:folder, path}}, :copy),
    do: [{:copy, path}, {:toast, "Copied #{path}", :success}]

  def act(_ctx, %Row{id: "act:make_private"}, verb) when verb in [:open, :enter, :open_row],
    do: [{:cli_write, %{}}]

  def act(ctx, %Row{key: "files.cli_json"}, verb) when verb in [:edit_external, :external] do
    cli = cli(ctx) || %{}

    [
      {:external_edit,
       %{
         ref: "cli.json",
         content: get(cli, :text),
         fingerprint: get(cli, :fingerprint),
         suffix: ".json"
       }}
    ]
  end

  def act(_ctx, %Row{target: {:setting, key}}, verb) when verb in [:open, :enter, :open_row] do
    case section_of(key) do
      nil -> :default
      section -> [{:section, section}]
    end
  end

  def act(ctx, %Row{key: "files.versions"}, :copy),
    do: [{:copy, versions_text(ctx)}, {:toast, "Copied the versions", :success}]

  def act(_ctx, %Row{key: "files.doctor"}, verb) when verb in [:open, :enter, :open_row],
    do: [{:task, "doctor", nil, %{}}]

  def act(_ctx, _row, _verb), do: :default

  # ------------------------------------------------------------------ rows

  defp expand(%Row{key: "files.cli_json"} = row, ctx), do: cli_rows(row, ctx)

  defp expand(%Row{key: key} = row, ctx) when is_map_key(@paths, key) do
    case path(ctx, Map.fetch!(@paths, key)) do
      nil ->
        [%Row{row | value: [{"…", :text_faint}], state: :readonly}]

      path ->
        size =
          if key == "files.database",
            do: [{"  " <> bytes(get(facts(ctx), :database_bytes)), :text_faint}],
            else: []

        [
          %Row{
            row
            | value: [{path, :text_muted} | size],
              state: :readonly,
              target: {:folder, if(key == "files.database", do: Path.dirname(path), else: path)},
              keys: [{"y", :copy, "copy the path"}, {"o", :open_related, "open the folder"}]
          }
        ]
    end
  end

  defp expand(%Row{key: "files.log"} = row, ctx) do
    case get(ctx.launch_facts, :log_path) do
      path when is_binary(path) ->
        [
          %Row{
            row
            | value: [{path, :text_muted}],
              state: :readonly,
              target: {:path, path},
              keys: [{"y", :copy, "copy the path"}, {"o", :open_related, "open the folder"}]
          }
        ]

      _ ->
        [%Row{row | value: [{"not kept by this session", :text_ghost}], state: :readonly}]
    end
  end

  defp expand(%Row{key: "env.variables"} = row, ctx), do: env_rows(row, ctx)
  defp expand(%Row{key: "launch.summary"} = row, ctx), do: [launch_row(row, ctx)]
  defp expand(%Row{key: "terminal.this_terminal"} = row, ctx), do: [terminal_row(row, ctx)]

  defp expand(%Row{key: "files.versions"} = row, ctx),
    do: [
      %Row{
        row
        | value: [{versions_text(ctx), :text_muted}],
          state: :readonly,
          keys: [{"y", :copy, "copy them"}]
      }
    ]

  defp expand(row, _ctx), do: [row]

  defp cli_rows(row, ctx) do
    cli = cli(ctx)
    path = get(ctx.launch_facts, :cli_path) || get(cli, :path)

    cond do
      is_nil(cli) and is_nil(path) ->
        [
          %Row{
            row
            | value: [
                {"This session does not keep terminal preferences (no cli.json).", :text_ghost}
              ],
              state: :readonly
          }
        ]

      is_nil(cli) ->
        [%Row{row | value: [{path, :text_muted}, {"  …", :text_faint}], state: :readonly}]

      true ->
        status = get(cli, :status)
        mode = get(cli, :mode)
        size = get(cli, :size) || 0

        {mode_words, mode_role} =
          case private?(cli) do
            true -> {"0600 ✓", :success}
            false -> {"✗ #{octal(mode)}: others can read it", :error}
            nil -> {"no file yet", :text_ghost}
          end

        lines =
          [
            [{"#{bytes(size)} of 64 KB", if(size > @max_bytes, do: :error, else: :text_faint)}]
          ] ++
            status_lines(status) ++
            unknown_lines(get(cli, :unknown)) ++ invalid_lines(get(cli, :invalid))

        main = %Row{
          row
          | value: [
              {path || "cli.json", :text_muted},
              {"  ", :text_faint},
              {mode_words, mode_role}
            ],
            lines: lines,
            target: {:path, path},
            keys: [
              {"e", :edit_external, "edit in your editor"},
              {"y", :copy, "copy the path"},
              {"o", :open_related, "open the folder"}
            ]
        }

        fix =
          if private?(cli) == false,
            do: [
              %Row{
                id: "act:make_private",
                kind: :action,
                label: "Make it private",
                value: [{"rewrites cli.json as it is, readable by you only (0600)", :text_muted}],
                keys: [{"Enter", :enter, "make it private"}]
              }
            ],
            else: []

        [main | fix]
    end
  end

  defp status_lines(status) when status in [:not_json, "not_json"],
    do: [[{"✗ cli.json is not valid JSON · the defaults are used · e edit it", :error}]]

  defp status_lines(status) when status in [:too_large, "too_large"],
    do: [[{"✗ cli.json is larger than 64 KB · the defaults are used", :error}]]

  defp status_lines(status) when status in [:symlink, "symlink"],
    do: [[{"✗ cli.json is a symbolic link; SwarmCode will not replace it", :error}]]

  defp status_lines(status) when status in [:unreadable, "unreadable"],
    do: [[{"✗ cli.json could not be read", :error}]]

  defp status_lines(_), do: []

  defp unknown_lines([_ | _] = keys),
    do: [[{"kept, not used here: " <> Enum.join(keys, ", "), :text_faint}]]

  defp unknown_lines(_), do: []

  defp invalid_lines([_ | _] = keys),
    do: [[{"! not understood, the default is used: " <> Enum.join(keys, ", "), :warning}]]

  defp invalid_lines(_), do: []

  @doc false
  def env_rows(row, ctx) do
    items = env_items(ctx)
    {developer, normal} = Enum.split_with(items, &(&1.name in @developer))

    head = %Row{row | kind: :heading, value: [], label: "environment"}

    body =
      case normal do
        [] ->
          [
            Row.info("env-none", "none of the variables SwarmCode reads is set",
              role: :text_ghost
            )
          ]

        list ->
          Enum.map(list, &env_row/1)
      end

    dev =
      case developer do
        [] -> []
        list -> [Row.heading("developer") | Enum.map(list, &env_row/1)]
      end

    [head | body] ++ dev
  end

  defp env_row(item) do
    value =
      cond do
        item.secret -> [{"set", :text_muted}]
        is_binary(item.value) -> [{String.slice(item.value, 0, 200), :text_primary}]
        true -> [{"set", :text_muted}]
      end

    %Row{
      id: "env:" <> item.name,
      kind: :info,
      label: item.name,
      value: value,
      tag: if(item.feeds, do: [{"→ " <> item.feeds, :text_faint}], else: []),
      target: if(item.feeds, do: {:setting, item.feeds}),
      keys: if(item.feeds, do: [{"Enter", :enter, "go to the setting"}], else: [])
    }
  end

  @doc """
  The set variables of §2.25 list B from the service's facts and this
  launch's overrides, each `%{name, value, secret, feeds}`; a secret value is
  never carried (`value: nil`).
  """
  @spec env_items(map()) :: [map()]
  def env_items(ctx) do
    from_facts =
      case get(facts(ctx), :env) do
        list when is_list(list) ->
          for item <- list, get(item, :set) == true do
            name = to_string(get(item, :name))
            secret = get(item, :secret) == true or secret_name?(name)

            %{
              name: name,
              value: if(secret, do: nil, else: get(item, :value)),
              secret: secret,
              feeds: get(item, :feeds)
            }
          end

        _ ->
          []
      end

    from_launch =
      for {key, %{} = o} <- get(ctx.launch_facts, :env_overrides) || %{},
          is_binary(get(o, :var)) do
        name = get(o, :var)
        secret = secret_name?(name)

        %{
          name: name,
          value: if(secret, do: nil, else: get(o, :value)),
          secret: secret,
          feeds: key
        }
      end

    (from_facts ++ from_launch)
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(& &1.name)
  end

  defp secret_name?(name), do: Regex.match?(@secret, name)

  defp launch_row(row, ctx) do
    lf = ctx.launch_facts || %{}

    flags =
      case get(lf, :flags) do
        map when is_map(map) and map_size(map) > 0 ->
          map |> Enum.sort() |> Enum.map_join(" ", fn {f, v} -> String.trim("#{f} #{v}") end)

        _ ->
          "no flags"
      end

    conversation = if ctx.conversation, do: "a conversation", else: "no conversation"
    project = get(lf, :project_root) || "?"

    %Row{
      row
      | value: [{"#{flags} · #{conversation} · #{project}", :text_muted}],
        state: :readonly
    }
  end

  defp terminal_row(row, ctx) do
    caps = ctx.caps || %{}
    size = ctx.size || Map.get(caps, :size)
    cols = size && Map.get(size, :columns)
    rows = size && Map.get(size, :rows)

    words =
      [
        if(cols, do: "#{cols}×#{rows}"),
        "colour #{Map.get(caps, :color_mode) || "?"}",
        "glyphs #{if Map.get(caps, :ascii?), do: "ascii", else: Map.get(caps, :glyph_tier) || "measured"}",
        "ambiguous #{Map.get(caps, :ambiguous_width) || "narrow"}",
        "paste #{Map.get(caps, :paste) || "unavailable"}",
        "focus #{Map.get(caps, :focus) || "unavailable"}",
        "wheel #{Map.get(caps, :mouse) || "unavailable"}",
        "enhanced keys never",
        term(ctx)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    %Row{row | value: [{words, :text_muted}], state: :readonly}
  end

  defp term(ctx) do
    env = env_items(ctx)
    term = Enum.find_value(env, &(&1.name == "TERM" && &1.value))
    program = Enum.find_value(env, &(&1.name == "TERM_PROGRAM" && &1.value))

    [if(term, do: "TERM #{term}"), if(program, do: "TERM_PROGRAM #{program}")]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      words -> Enum.join(words, " · ")
    end
  end

  defp versions_text(ctx) do
    v = get(facts(ctx), :versions) || %{}
    cli = get(ctx.launch_facts, :cli_version)

    [
      if(cli, do: "CLI #{cli}"),
      if(get(v, :service), do: "service #{get(v, :service)}"),
      if(get(v, :protocol), do: "protocol #{get(v, :protocol)}"),
      if(get(v, :otp), do: "OTP #{get(v, :otp)}"),
      if(get(v, :elixir), do: "Elixir #{get(v, :elixir)}")
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "…"
      words -> Enum.join(words, " · ")
    end
  end

  # ---------------------------------------------------------------- helpers

  @doc "Whether cli.json is private (mode 0600 or tighter); nil when absent."
  @spec private?(map() | nil) :: boolean() | nil
  def private?(cli) do
    case get(cli, :mode) do
      mode when is_integer(mode) -> Bitwise.band(mode, 0o077) == 0
      _ -> nil
    end
  end

  defp octal(mode) when is_integer(mode),
    do: "0" <> Integer.to_string(Bitwise.band(mode, 0o777), 8)

  defp octal(_), do: "?"

  @doc "Bytes in words: `812 B`, `41.2 KB`, `1.8 GB`."
  @spec bytes(term()) :: String.t()
  def bytes(n) when is_integer(n) and n < 1024, do: "#{n} B"
  def bytes(n) when is_integer(n) and n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"

  def bytes(n) when is_integer(n) and n < 1024 * 1024 * 1024,
    do: "#{Float.round(n / 1024 / 1024, 1)} MB"

  def bytes(n) when is_integer(n), do: "#{Float.round(n / 1024 / 1024 / 1024, 1)} GB"
  def bytes(_), do: ""

  defp section_of(key) do
    case SwarmCode.Settings.Registry.fetch(key) do
      {:ok, entry} -> entry.section
      _ -> nil
    end
  end

  defp path(ctx, name), do: facts(ctx) |> get(:paths) |> get(name)
  defp facts(ctx), do: ctx.data |> Map.get(:facts)
  defp cli(ctx), do: ctx.data |> Map.get(:cli)

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
