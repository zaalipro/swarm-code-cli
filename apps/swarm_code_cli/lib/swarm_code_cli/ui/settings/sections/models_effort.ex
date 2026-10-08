defmodule SwarmCodeCLI.UI.Settings.Sections.ModelsEffort do
  @moduledoc """
  pass74 U3-4 (spec §2.2, F3 with §4.1 item 13): Models & effort. Four
  groups: the models of new conversations (and `▸ Fetch every provider's
  models`), the default efforts, this conversation (its model, effort,
  worker pair, the one Mode row — build, plan, consensus, ultra, writing a
  workflow — title, pinned, `▸ Apply a profile`), and the consensus
  settings of this conversation as a sub-page listed while the mode is
  consensus (its rows stay reachable through search and `:set`). Two link
  rows close the page: the project file's keys SwarmCode ignores → Project
  file, and the environment variables feeding the page → Files &
  environment.

  Model rows use U2's `ModelPicker` when it is loaded, else U1's
  `ModelFallback`. Session and global rows write to their own layers (D17);
  effort choices follow the chosen model after the `--model` overlay (the
  service computes them). A session without a conversation shows one info
  row instead of its group.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :models_effort

  alias SwarmCodeCLI.UI.Settings.{Page, Picker, Row, Rows}
  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R
  alias SwarmCodeCLI.UI.Settings.Sections.{Pricing, Providers}

  @consensus "consensus · this conversation"
  @session "this conversation"
  @sub :consensus
  @env_feeds ~w[SWARM_MODEL SWARM_MODEL_OVERRIDE SWARM_EFFORT SWARM_PROVIDER SWARM_BASE_URL]

  @impl true
  def loads(ctx) do
    # QA #2 P0-2, P1-1: the model rows name their provider and open the picker.
    # cli021 U3: the price rows carry the models' context windows.
    base =
      [{:values, [:models_effort]} | SwarmCodeCLI.UI.Settings.ModelPicker.loads()] ++
        [{:records, "pricing_rows", %{}}]

    if project_id(ctx), do: base ++ [{:record, "project_config", project_id(ctx)}], else: base
  end

  @impl true
  def rows(ctx) do
    rows = ctx |> Rows.registry(:models_effort) |> Enum.map(&decorate(&1, ctx))

    {main, consensus} = split_consensus(rows)

    main =
      if conversation?(ctx),
        do: main,
        else: drop_group(main, @session) ++ [no_conversation()]

    dedupe_headings(main) ++ windows(ctx) ++ consensus_link(ctx, consensus) ++ links(ctx)
  end

  # The registry lists `▸ Apply a profile` after the consensus group; with
  # that group on its own page it joins the conversation's rows.
  defp dedupe_headings(rows) do
    {kept, _seen} =
      Enum.reduce(rows, {[], MapSet.new()}, fn
        %Row{kind: :heading, label: label} = row, {acc, seen} ->
          if MapSet.member?(seen, label),
            do: {acc, seen},
            else: {[row | acc], MapSet.put(seen, label)}

        row, {acc, seen} ->
          {[row | acc], seen}
      end)

    Enum.reverse(kept)
  end

  @impl true
  def sub_rows(ctx, @sub) do
    {_main, consensus} =
      ctx |> Rows.registry(:models_effort) |> Enum.map(&decorate(&1, ctx)) |> split_consensus()

    note =
      if mode(ctx) == "consensus",
        do: [],
        else: [Row.info("consensus-note", "used only in consensus mode", role: :text_faint)]

    note ++ Enum.reject(consensus, &(&1.kind == :heading))
  end

  def sub_rows(_ctx, _sub), do: []

  @impl true
  def title(%{page: %Page{sub: @sub}}), do: "Models & effort › Consensus"
  def title(_ctx), do: "Models & effort"

  @impl true
  def act(_ctx, %Row{id: "act:consensus"}, verb) when verb in [:open, :enter, :open_row],
    do: [{:open, %Page{section: :models_effort, sub: @sub}}]

  def act(_ctx, %Row{id: "link:project_file"}, verb)
      when verb in [:open, :enter, :open_row, :goto],
      do: [{:section, :project_file}]

  def act(_ctx, %Row{id: "link:files_env"}, verb) when verb in [:open, :enter, :open_row, :goto],
    do: [{:section, :files_env}]

  # cli021 U3: a model's context window (`windows/1`).
  def act(ctx, %Row{target: {:context_window, model}}, :reset) do
    case Pricing.window_ops(ctx, model, nil) do
      {:ok, ops} -> ops
      {:error, _words} -> []
    end
  end

  def act(_ctx, %Row{target: {:context_window_unpriced, model}}, verb)
      when verb in [:open, :enter, :open_row],
      do: window_ops_for_unpriced(model)

  def act(_ctx, %Row{key: "models.fetch_all"}, verb)
      when verb in [:open, :enter, :open_row, :fetch],
      do: [{:task, "provider.fetch_all", nil, %{}}]

  def act(ctx, %Row{key: "session.profile"}, verb) when verb in [:enter, :open_row] do
    case profiles(ctx) do
      [] ->
        [{:toast, "This project's file has no profiles · Project file adds them", :info}]

      names ->
        [
          {:picker,
           %Picker{
             id: "session-profile",
             title: "Apply a profile",
             options:
               Enum.map(names, fn {name, hint} -> %{value: name, label: name, hint: hint} end),
             on_pick: {:section, :models_effort, :profile},
             opener: "key:session.profile"
           }}
        ]
    end
  end

  def act(_ctx, _row, _verb), do: :default

  @impl true
  def commit(ctx, %Row{target: {:context_window, model}} = row, value) do
    case Pricing.window_ops(ctx, model, value) do
      {:ok, ops} -> ops
      {:error, words} -> [{:row_error, row.id, words}]
    end
  end

  def commit(_ctx, _row, _value), do: :default

  @doc """
  A model without a price row opens its price draft: the desktop stores the
  window on the price row (Settings → Pricing), so it is set with the prices.
  """
  def window_ops_for_unpriced(model), do: Pricing.draft_ops(model, %{})

  @doc false
  @impl true
  def picked(ctx, :profile, name) when is_binary(name) do
    [
      {:command, "profile.apply", %{"conversation_id" => conversation_id(ctx)}, %{"name" => name},
       %{toast: "Applied profile #{name} to this conversation"}}
    ]
  end

  def picked(_ctx, _tag, _value), do: []

  defp profiles(ctx) do
    case project_config(ctx) |> get(:profiles) do
      map when is_map(map) ->
        map
        |> Enum.map(fn {name, fields} -> {to_string(name), profile_hint(fields)} end)
        |> Enum.sort()

      list when is_list(list) ->
        for p <- list, is_binary(get(p, :name)), do: {get(p, :name), profile_hint(p)}

      _ ->
        []
    end
  end

  defp profile_hint(fields) when is_map(fields) do
    [:model, :effort, :swarm_model, :swarm_effort]
    |> Enum.map(&get(fields, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp profile_hint(_), do: nil

  # ------------------------------------------------------------------ rows

  # cli021 U3: `▸ Fetch every provider's models` says its result here too.
  defp decorate(%Row{key: "models.fetch_all"} = row, ctx) do
    case Providers.fetch_all_view(ctx) do
      {_value, _tag, _lines, nil} -> row
      {value, tag, lines, _task} -> %{row | value: value, tag: tag, lines: lines}
    end
  end

  defp decorate(row, _ctx), do: row

  # cli021 U3 (owner point 6): one row per model this conversation uses (the
  # chat, worker and validator slots; the new conversations' defaults when
  # there is none) with its context window, 1M unless its price row sets one.
  # A priced model edits in place (8 000 to 2 000 000, `r` back to 1M); an
  # unpriced one opens its price draft.
  @slots [
    {"session.model", "models.chat", "chat"},
    {"session.sub_agent_model", "models.sub_agent", "worker"},
    {"session.validator_model", "models.validator", "validator"}
  ]

  defp windows(ctx) do
    used =
      @slots
      |> Enum.flat_map(fn {session, global, word} ->
        model =
          if conversation?(ctx),
            do: model_name(ctx, session) || model_name(ctx, global),
            else: model_name(ctx, global)

        if model, do: [{model, word}], else: []
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.sort_by(fn {_model, [word | _]} ->
        Enum.find_index(@slots, &(elem(&1, 2) == word))
      end)

    case used do
      [] -> []
      _ -> [Row.heading("context windows") | Enum.map(used, &window_row(ctx, &1))]
    end
  end

  defp window_row(ctx, {model, words}) do
    tag = [{Enum.join(words, " · "), :text_faint}]

    case R.loaded?(ctx, "pricing_rows") && Pricing.window(ctx, model) do
      false ->
        %Row{
          id: "ctx:" <> model,
          kind: :info,
          label: model,
          value: [{"…", :text_faint}],
          tag: tag
        }

      {:priced, window} ->
        %Row{
          id: "ctx:" <> model,
          kind: :field,
          label: model,
          value: [window_words(window)],
          tag: tag,
          editor:
            {SwarmCodeCLI.UI.Settings.Editors.Number,
             %{
               value: window,
               min: 8_000,
               max: 2_000_000,
               step: 1_000,
               big_step: 100_000,
               nullable: true,
               null_label: "1M default"
             }},
          keys: [{"Enter", :open_row, "edit"}, {"r", :reset, "back to 1M"}],
          target: {:context_window, model}
        }

      {:unpriced, _} ->
        %Row{
          id: "ctx:" <> model,
          kind: :link,
          label: model,
          value: [window_words(nil), {" · set it with the model's price", :text_faint}],
          tag: tag,
          keys: [{"Enter", :open_row, "price it"}],
          target: {:context_window_unpriced, model}
        }
    end
  end

  defp window_words(nil), do: {R.context(nil), :text_faint}
  defp window_words(n), do: {R.context(n), :text_primary}

  # A model value as the service sends it: `%{"provider_id", "model"}`.
  defp model_name(ctx, key) do
    case ctx.data |> Map.get(:values, %{}) |> Map.get(key) do
      nil ->
        nil

      setting ->
        case get(setting, :value) do
          %{} = value -> present(get(value, :model))
          value when is_binary(value) -> value |> String.split("|") |> List.last() |> present()
          _ -> nil
        end
    end
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp split_consensus(rows) do
    {consensus, main, _in?} =
      Enum.reduce(rows, {[], [], false}, fn
        %Row{kind: :heading, label: @consensus} = row, {c, m, _} -> {[row | c], m, true}
        %Row{kind: :heading} = row, {c, m, _} -> {c, [row | m], false}
        row, {c, m, true} -> {[row | c], m, true}
        row, {c, m, false} -> {c, [row | m], false}
      end)

    {Enum.reverse(main), Enum.reverse(consensus)}
  end

  defp drop_group(rows, group) do
    {kept, _in?} =
      Enum.reduce(rows, {[], false}, fn
        %Row{kind: :heading, label: ^group}, {acc, _} -> {acc, true}
        %Row{kind: :heading} = row, {acc, _} -> {[row | acc], false}
        _row, {acc, true} -> {acc, true}
        row, {acc, false} -> {[row | acc], false}
      end)

    Enum.reverse(kept)
  end

  defp no_conversation,
    do:
      Row.info("no-conversation", "There is no conversation in this session.", role: :text_muted)

  defp consensus_link(ctx, consensus) do
    if mode(ctx) == "consensus" and conversation?(ctx) and consensus != [] do
      count = Enum.count(consensus, &(&1.kind != :heading))
      changed = Enum.count(consensus, &(:changed in &1.marks))

      [
        Row.heading(@consensus),
        %Row{
          id: "act:consensus",
          kind: :link,
          label: "Consensus",
          value: [
            {"#{count} settings · #{changed} changed · rounds, judge, implementer, checks",
             :text_muted}
          ],
          tag: [{"Enter open", :text_faint}],
          keys: [{"Enter", :enter, "open"}]
        }
      ]
    else
      []
    end
  end

  defp links(ctx) do
    ignored = ignored_keys(ctx)
    env = env_set(ctx)

    file =
      case ignored do
        [] ->
          []

        keys ->
          n = length(keys)

          [
            %Row{
              id: "link:project_file",
              kind: :link,
              label: "This project's file",
              value: [
                {"#{n} #{if n == 1, do: "key", else: "keys"} ncode ignores: #{Enum.join(keys, ", ")}",
                 :text_muted}
              ],
              tag: [{"→ Project file", :text_faint}],
              keys: [{"Enter", :enter, "open Project file"}]
            }
          ]
      end

    environment =
      case env do
        [] ->
          []

        names ->
          [
            %Row{
              id: "link:files_env",
              kind: :link,
              label: "From the environment",
              value: [{Enum.join(names, ", "), :text_muted}],
              tag: [{"→ Files & environment", :text_faint}],
              keys: [{"Enter", :enter, "open Files & environment"}]
            }
          ]
      end

    case file ++ environment do
      [] -> []
      rows -> [Row.heading("elsewhere") | rows]
    end
  end

  # ---------------------------------------------------------------- facts

  defp ignored_keys(ctx) do
    case project_config(ctx) do
      nil ->
        []

      fields ->
        case get(fields, :top_level) do
          map when is_map(map) -> map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
          list when is_list(list) -> Enum.map(list, &to_string/1)
          _ -> []
        end
    end
  end

  defp env_set(ctx) do
    facts_env =
      case ctx.data |> Map.get(:facts) |> get(:env) do
        list when is_list(list) ->
          for item <- list,
              get(item, :set) == true,
              get(item, :name) in @env_feeds,
              do: get(item, :name)

        _ ->
          []
      end

    flags =
      if ctx.launch_facts |> get(:flag_overrides) |> is_map_with_model?(),
        do: ["--model"],
        else: []

    Enum.uniq(facts_env ++ flags)
  end

  defp is_map_with_model?(map) when is_map(map),
    do: Enum.any?(map, fn {key, _} -> key in ["session.model", "session.sub_agent_model"] end)

  defp is_map_with_model?(_), do: false

  defp project_config(ctx) do
    case project_id(ctx) do
      nil ->
        nil

      id ->
        case ctx.data |> Map.get(:record, %{}) |> Map.get({"project_config", id}) do
          nil -> nil
          %{fields: fields} -> fields
          fields -> fields
        end
    end
  end

  # The page's project: the picker's choice, else the session's (§2.10, D12).
  defp project(ctx) do
    items = projects(ctx)
    chosen = ctx.layer && Map.get(ctx.layer, :page_project_id)
    session = ctx.data && Map.get(ctx.data, :project_id)

    Enum.find(items, &(chosen != nil and get(&1, :id) == chosen)) ||
      Enum.find(items, &(get(&1, :current) == true)) ||
      Enum.find(items, &(session != nil and get(&1, :id) == session)) ||
      Enum.find(items, &(ctx.project != nil and ctx.project in [get(&1, :name), get(&1, :root)]))
  end

  defp project_id(ctx) do
    case project(ctx) do
      nil ->
        chosen = ctx.layer && Map.get(ctx.layer, :page_project_id)
        chosen || (ctx.data && Map.get(ctx.data, :project_id))

      p ->
        get(p, :id)
    end
  end

  defp projects(ctx) do
    case ctx.data && Map.get(ctx.data, :projects) do
      %{items: items} when is_list(items) -> Enum.map(items, &record_fields/1)
      items when is_list(items) -> Enum.map(items, &record_fields/1)
      _ -> []
    end
  end

  defp record_fields(%{fields: fields}) when is_map(fields), do: fields
  defp record_fields(other), do: other

  defp conversation?(ctx), do: not is_nil(conversation_id(ctx))

  defp conversation_id(ctx) do
    case ctx.conversation do
      id when is_binary(id) -> id
      %{} = conversation -> get(conversation, :id)
      _ -> nil
    end
  end

  defp mode(ctx) do
    case ctx.data |> Map.get(:values, %{}) |> Map.get("session.mode") do
      nil -> "build"
      value -> get(value, :value) || "build"
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
