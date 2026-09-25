defmodule SwarmCodeCLI.UI.Settings.Sections.LanguageServers do
  @moduledoc """
  The Language servers section (spec §2.8, §3.5.6): one row per language (13),
  `language · extensions · command · state`, with the LspCommand editor (`default · off ·
  custom`). A write is `{:patch, "lsp.<language>", nil | "off" | command}`; `Space` switches
  between off and the default, `r` goes back to the default. `lsp.check` runs when the page
  opens and its rows give each language `✓ installed` / `✗ not installed: <exe>` / `no
  default` / `off` and `N running in <project>`. Keys of `lsp_servers` that are not one of
  the 13 languages follow, each with `x remove` (`lsp.remove_key`, CAS on the value as read).
  `▸ Stop running servers` for the page project or every project (`lsp.stop`). Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @languages [
    {"elixir", "Elixir", ".ex .exs", "elixir-ls --stdio"},
    {"erlang", "Erlang", ".erl .hrl", nil},
    {"typescript", "TypeScript", ".ts .tsx", "typescript-language-server --stdio"},
    {"javascript", "JavaScript", ".js .jsx .mjs .cjs", "typescript-language-server --stdio"},
    {"python", "Python", ".py", "pyright-langserver --stdio"},
    {"rust", "Rust", ".rs", "rust-analyzer"},
    {"go", "Go", ".go", "gopls serve"},
    {"c", "C", ".c .h", "clangd --log=error"},
    {"cpp", "C++", ".cpp .cxx .cc .hpp", "clangd --log=error"},
    {"ruby", "Ruby", ".rb .rake", "solargraph stdio"},
    {"java", "Java", ".java", "jdtls"},
    {"swift", "Swift", ".swift", "sourcekit-lsp"},
    {"zig", "Zig", ".zig", "zls"}
  ]

  @max 1_024

  def id, do: :language_servers

  @doc "The 13 languages: `{id, name, extensions, built-in command | nil}`."
  def languages, do: @languages

  def loads(_ctx), do: [{:values, [:language_servers]}, {:auto_task, "lsp.check", nil}]

  def title(_ctx), do: "Language servers"

  def counts(_ctx), do: %{records: nil}

  def attention(_ctx), do: []

  def record_rows(_ctx, _kind, _id), do: []
  def sub_rows(_ctx, _sub), do: []

  # ------------------------------------------------------------------ rows

  def rows(ctx) do
    check = R.task(ctx, "lsp.check")
    results = check_rows(ctx, check)

    intro =
      R.info(
        "lsp:intro",
        "The command each language's server starts with · a change reaches new clients; a running server keeps its command until it idles out (300 s) or you stop it",
        :text_faint
      )

    language_rows = Enum.map(@languages, &language_row(ctx, &1, Map.get(results, elem(&1, 0))))

    unknown = unknown_rows(ctx, check)

    [intro, R.heading("languages", "languages")] ++
      language_rows ++
      unknown ++
      [R.heading("actions", "actions"), check_row(ctx, check)] ++ stop_rows(ctx)
  end

  defp check_rows(ctx, {id, task}) do
    if R.field(task, "state") == "done",
      do: Map.new(R.task_rows(ctx, id), &{R.field(&1, "language"), &1}),
      else: %{}
  end

  defp check_rows(_ctx, nil), do: %{}

  defp language_row(ctx, {lang, name, exts, default}, result) do
    key = "lsp.#{lang}"
    override = R.value_of(ctx, key)
    row_id = "key:#{key}"

    {command, command_role, tag} =
      cond do
        override == "off" -> {"off", :text_faint, "off"}
        is_binary(override) -> {override, :text_primary, "custom"}
        default == nil -> {"no default: set a command", :text_faint, "no default"}
        true -> {default, :text_muted, "default"}
      end

    running =
      for r <- R.field(result, "running") || [],
          do: "#{R.field(r, "count")} running in #{R.field(r, "project")}"

    state = state_segments(ctx, override, default, result)

    lines =
      error_lines(ctx, row_id) ++
        if(is_binary(override) and override != "off",
          do: [
            [
              {"split on spaces · a path with spaces cannot be written · built-in: #{default || "none"}",
               :text_faint}
            ]
          ],
          else: []
        ) ++ if(running != [], do: [[{Enum.join(running, " · "), :info}]], else: [])

    R.row(
      id: row_id,
      kind: :setting,
      key: key,
      label: name,
      value: [{String.pad_trailing(exts, 20), :text_faint}, {command, command_role}],
      tag: state ++ [{"  " <> tag, :text_muted}],
      lines: lines,
      columns: [
        {name, :text_primary, 1},
        {exts, :text_faint, 4},
        {command, command_role, 2}
      ],
      editor:
        {SwarmCodeCLI.UI.Settings.Editors.LspCommand,
         %{value: override, default: default, max: @max}},
      keys: [
        {"Enter", :open_row, "edit"},
        {"Space", :toggle, if(override == "off", do: "back on", else: "turn off")},
        {"r", :reset, "default"}
      ],
      target: {:lsp, lang, override}
    )
  end

  defp state_segments(ctx, override, default, result) do
    cond do
      override == "off" ->
        [{"off", :text_faint}]

      override == nil and default == nil ->
        [{"no default", :text_faint}]

      result == nil ->
        []

      R.field(result, "installed") == true ->
        [{R.glyph(ctx, :ok) <> " installed", :success}]

      R.field(result, "installed") == false ->
        [{R.glyph(ctx, :error) <> " not installed: #{R.field(result, "executable")}", :error}]

      true ->
        []
    end
  end

  defp unknown_rows(ctx, {id, task}) do
    summary = R.task_summary(ctx, id) || R.field(task, "summary") || %{}

    case R.field(summary, "unknown_keys") || [] do
      [] ->
        []

      keys ->
        [R.heading("unknown", "not a known language")] ++
          for k <- keys do
            key = R.field(k, "key")

            R.row(
              id: "lsp:unknown:#{key}",
              kind: :record,
              label: key,
              value: [
                {to_string(R.field(k, "value")), :text_muted},
                {" · not a known language · ", :text_faint},
                {"x", :key},
                {" remove", :text_faint}
              ],
              tag: [{"kept on every write", :text_faint}],
              keys: [{"x", :delete, "remove"}],
              target: {:unknown, key, R.field(k, "value")}
            )
          end
    end
  end

  defp unknown_rows(_ctx, nil), do: []

  defp check_row(ctx, check) do
    {value, tag} =
      case check do
        nil ->
          {[{"runs when this page opens", :text_faint}], []}

        task ->
          R.task_words(ctx, task, "looking for the servers", fn _s -> "checked" end)
      end

    R.row(
      id: "act:lsp.check",
      kind: :action,
      label: "▸ Check which are installed",
      value: value,
      tag: tag,
      state: if(R.running?(check), do: :running, else: :normal),
      keys: [{"Enter", :open_row, "check"}, {"t", :test, "check"}],
      target: {:check}
    )
  end

  defp stop_rows(ctx) do
    project = R.project_id(ctx)

    this =
      if project,
        do: [
          R.row(
            id: "act:lsp.stop",
            kind: :action,
            label: "▸ Stop running language servers of #{R.project_name(ctx)}",
            value: [{"they restart with the saved commands on the next call", :text_faint}],
            keys: [{"Enter", :open_row, "stop"}],
            target: {:stop, %{"project_id" => project}}
          )
        ],
        else: []

    this ++
      [
        R.row(
          id: "act:lsp.stop_all",
          kind: :action,
          label: "▸ Stop running language servers of every project",
          value: [{"applies the commands now", :text_faint}],
          keys: [{"Enter", :open_row, "stop"}],
          target: {:stop, %{"all" => true}}
        )
      ]
  end

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      m -> [[{R.glyph(ctx, :error) <> " " <> m, :error}]]
    end
  end

  # ------------------------------------------------------------------- act

  def act(_ctx, row, verb) do
    case {Map.get(row, :target), verb} do
      {{:lsp, lang, "off"}, :toggle} -> [{:patch, "lsp.#{lang}", nil}]
      {{:lsp, lang, _}, :toggle} -> [{:patch, "lsp.#{lang}", "off"}]
      {{:lsp, _lang, nil}, :reset} -> [{:toast, "Already the default", :info}]
      {{:lsp, lang, _}, :reset} -> [{:patch, "lsp.#{lang}", nil}]
      {{:unknown, key, value}, :delete} -> remove_ops(key, value)
      {{:check}, v} when v in [:open_row, :test] -> [{:task, "lsp.check", nil, %{}}]
      {{:stop, target}, :open_row} -> [{:command, "lsp.stop", target, %{}, %{undo: false}}]
      _ -> :default
    end
  end

  defp remove_ops(key, value) do
    [
      {:command, "lsp.remove_key", %{"key" => key}, %{},
       %{
         expected: %{"value" => value},
         write_key: {:setting, "lsp_servers", key},
         undo: false,
         toast: "Removed #{key}",
         after: {:task, "lsp.check", nil, %{}}
       }}
    ]
  end

  # ---------------------------------------------------------------- commit

  @doc "An LspCommand result: nil (default), `\"off\"`, or a custom command line."
  def commit(_ctx, row, value) do
    case Map.get(row, :target) do
      {:lsp, lang, current} ->
        case validate(value) do
          {:ok, ^current} -> []
          {:ok, v} -> [{:patch, "lsp.#{lang}", v}]
          {:error, m} -> [{:row_error, row.id, m}]
        end

      _ ->
        :default
    end
  end

  @doc "Validates an LspCommand value (§2.8 cli rules)."
  def validate(nil), do: {:ok, nil}
  def validate(:default), do: {:ok, nil}
  def validate(:off), do: {:ok, "off"}

  def validate(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.contains?(value, ["\n", "\r"]) -> {:error, "one line only"}
      trimmed == "" -> {:error, "can't be blank"}
      String.length(trimmed) > @max -> {:error, "should be at most #{@max} character(s)"}
      true -> {:ok, trimmed}
    end
  end

  def validate(_), do: {:error, "is invalid"}
end
