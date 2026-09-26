defmodule SwarmCodeCLI.UI.Settings.KeyValueSecrets do
  @moduledoc """
  The environment / headers sub-page of an MCP server (spec §2.23 *mcp_server* `env` and
  `headers`, T§9.8): one row per entry, `NAME  value`. An entry is secret when the service
  masked it, when `SecretPattern.secret_kv?/2` says so, or after `s` *treat as secret* (this
  session only): its value is never drawn and Enter opens a paste target that saves it
  with `mcp.set_secret` (a secret travels once, in `secrets`). Plain entries are staged
  with the other connection fields (D8) as the full desired list the service expects:
  `[%{"name", "value"}]` for a new or changed value, `[%{"name", "keep" => true}]` for a
  stored one; a name missing from the list is deleted.

  Pure: rows for the sub-page and the ops of its keys.
  """

  alias SwarmCode.Settings.SecretPattern
  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @env_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @header_name ~r/^[A-Za-z0-9-]+$/

  @doc "The staged key of a map: `\"env\"` or `\"headers\"`."
  def field(:env), do: "env"
  def field(:headers), do: "headers"

  @doc """
  The entries as the page shows them: the staged list when one is staged, else the
  record's. Each `%{name, secret, value, hint, stored?, changed?}`.
  """
  def entries(ctx, id, map, record_fields) do
    stored = Map.new(R.field(record_fields, field(map)) || [], &{R.field(&1, "name"), &1})
    staged = ctx |> R.staged("mcp_server", id) |> Map.get(field(map))
    treat = treat_secret(ctx)

    list =
      case staged do
        nil ->
          for e <- R.field(record_fields, field(map)) || [] do
            %{
              name: R.field(e, "name"),
              secret: R.field(e, "secret") == true,
              value: R.field(e, "value"),
              hint: R.field(e, "hint"),
              stored?: true,
              changed?: false
            }
          end

        staged ->
          for e <- staged do
            name = R.field(e, "name")

            if R.field(e, "keep") == true do
              s = Map.get(stored, name, %{})

              %{
                name: name,
                secret: R.field(s, "secret") == true,
                value: R.field(s, "value"),
                hint: R.field(s, "hint"),
                stored?: true,
                changed?: false
              }
            else
              %{
                name: name,
                secret: false,
                value: R.field(e, "value"),
                hint: nil,
                stored?: Map.has_key?(stored, name),
                changed?: true
              }
            end
          end
      end

    Enum.map(list, fn e ->
      secret =
        e.secret or secret?(e.name, e.value) or
          MapSet.member?(treat, {"mcp_server", id, field(map), e.name})

      if secret and not e.secret, do: %{e | secret: true, value: nil}, else: e
    end)
  end

  defp treat_secret(ctx) do
    case Map.get(R.layer(ctx), :treat_secret) do
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
      _ -> MapSet.new()
    end
  end

  @doc """
  Whether typed `NAME=value` text holds a secret already: a `=` after a
  secret-looking name, or a value that starts like a token.
  """
  @spec secret_entry?(String.t()) :: boolean()
  def secret_entry?(text) when is_binary(text) do
    case String.split(text, "=", parts: 2) do
      [name, value] -> String.trim(name) != "" and secret?(String.trim(name), value)
      _ -> false
    end
  end

  def secret_entry?(_text), do: false

  @doc "Whether a name/value pair is a secret (`SecretPattern.secret_kv?/2`)."
  def secret?(name, value),
    do: SecretPattern.secret_kv?(to_string(name), if(is_binary(value), do: value, else: ""))

  @doc "The entries as one line: `2 variables · GITHUB_PERSONAL_ACCESS_TOKEN, GITHUB_TOOLSETS`."
  def summary(entries, map) do
    noun = if map == :env, do: "variable", else: "header"

    case entries do
      [] ->
        "none"

      list ->
        "#{R.count(length(list), noun)} · #{Enum.map_join(Enum.take(list, 3), ", ", & &1.name)}#{if length(list) > 3, do: " +#{length(list) - 3}", else: ""}"
    end
  end

  @doc "One continuation line per entry (values of secrets masked)."
  def lines(ctx, entries) do
    dots = if R.tier(ctx) == :ascii, do: "********", else: "●●●●●●●●"

    for e <- entries do
      value =
        if e.secret,
          do: [
            {dots, :text_muted},
            {" secret · #{if e.stored?, do: "set", else: "not set"}", :text_faint}
          ],
          else: [{to_string(e.value), :text_primary}]

      [{"    #{String.pad_trailing(e.name, 30)}", :text_muted} | value]
    end
  end

  # ------------------------------------------------------------ the sub-page

  @doc "The rows of the `env`/`headers` sub-page of server `id`."
  def rows(ctx, id, map, record_fields) do
    entries = entries(ctx, id, map, record_fields)
    noun = if map == :env, do: "Environment", else: "Headers"
    staged? = ctx |> R.staged("mcp_server", id) |> Map.has_key?(field(map))

    head =
      R.row(
        id: "info:kv:head",
        kind: :info,
        label: "#{R.field(record_fields, "name")} › #{noun}",
        value: [
          {if(staged?, do: "changed · restarts when you leave this page · R now", else: "saved"),
           if(staged?, do: :warning, else: :text_faint)}
        ],
        tag: [{"a", :key}, {" add", :text_faint}],
        state: :readonly
      )

    note =
      if map == :env,
        do: [
          R.info(
            "kv:scrub",
            "MCP servers get the default secret scrub, not yours: put the keys a server needs in its own environment.",
            :text_faint
          )
        ],
        else: []

    items =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {e, i} -> entry_row(ctx, id, map, e, i) end)

    empty =
      if entries == [],
        do: [R.info("kv:none", "No #{String.downcase(noun)} yet · a adds one")],
        else: []

    add =
      R.row(
        id: "act:kv.add",
        kind: :action,
        label: "▸ Add #{if map == :env, do: "a variable", else: "a header"}",
        value: [
          {"NAME=value · a secret's value is pasted: = opens the paste", :text_faint}
        ],
        # QA F-6: the typed text is committed the moment it reads as a secret
        # (`NAME=` for a secret-looking name, or a token prefix after `=`), so
        # the value is never drawn; the paste target takes it instead.
        editor:
          {SwarmCodeCLI.UI.Settings.Editors.Text,
           %{value: "", max: 4_096, commit_when: &__MODULE__.secret_entry?/1}},
        keys: [{"Enter", :open_row, "add"}, {"a", :add, "add"}],
        target: {:kv_add, id, map}
      )

    [head] ++ note ++ empty ++ items ++ [add]
  end

  defp entry_row(ctx, id, map, e, i) do
    dots = if R.tier(ctx) == :ascii, do: "********", else: "●●●●●●●●"
    row_id = "kv:#{field(map)}:#{i}"

    value =
      cond do
        e.secret and e.stored? and is_binary(e.hint) ->
          [{dots, :text_muted}, {" secret · set · ends #{e.hint}", :text_faint}]

        e.secret and e.stored? ->
          [{dots, :text_muted}, {" secret · set", :text_faint}]

        e.secret ->
          [{"secret · not set · Enter pastes it", :warning}]

        true ->
          [{to_string(e.value), :text_primary}]
      end

    R.row(
      id: row_id,
      kind: :kv_item,
      label: e.name,
      value: value,
      marks: if(e.changed?, do: [:pending], else: []),
      lines: error_lines(ctx, row_id),
      editor:
        if(e.secret,
          do: nil,
          else:
            {SwarmCodeCLI.UI.Settings.Editors.Text,
             %{value: to_string(e.value || ""), max: 4_096}}
        ),
      keys:
        [
          {"Enter", :open_row, if(e.secret, do: "paste a new value", else: "edit")},
          {"x", :delete, "remove"}
        ] ++
          if(e.secret, do: [], else: [{"s", :alt, "treat as secret"}]),
      target: {:kv, id, map, e.name, e.secret}
    )
  end

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      m -> [[{R.glyph(ctx, :error) <> " " <> m, :error}]]
    end
  end

  # --------------------------------------------------------------- the ops

  @doc "The ops of a key on the sub-page."
  def act(ctx, row, verb, record_fields) do
    case {Map.get(row, :target), verb} do
      {{:kv, id, map, name, true}, :open_row} ->
        [{:paste, secret_target(record_fields, id, map, name)}]

      {{:kv, id, map, name, _}, :delete} ->
        stage(
          ctx,
          id,
          map,
          record_fields,
          &Enum.reject(&1, fn e -> R.field(e, "name") == name end)
        )

      {{:kv, id, map, name, false}, :alt} ->
        [
          {:treat_secret, {"mcp_server", id, field(map), name}},
          {:toast, "#{name} is treated as a secret for this session · Enter pastes its value",
           :info}
        ]

      {{:kv_add, _id, _map}, :add} ->
        [{:edit, "act:kv.add"}]

      {{:kv, _id, _map, _name, _}, :add} ->
        [{:edit, "act:kv.add"}]

      _ ->
        :default
    end
  end

  @doc "A committed value: an edited plain value, or `NAME=value` on the add row."
  def commit(ctx, row, value, record_fields) do
    case Map.get(row, :target) do
      {:kv, id, map, name, false} ->
        text = to_string(value || "")

        if secret?(name, text),
          do: [
            {:treat_secret, {"mcp_server", id, field(map), name}},
            {:toast, "That value looks like a secret · paste it instead (Enter)", :warning}
          ],
          else: stage(ctx, id, map, record_fields, &put_entry(&1, name, text))

      {:kv_add, id, map} ->
        add(ctx, id, map, record_fields, to_string(value || ""), row.id)

      _ ->
        :default
    end
  end

  defp add(ctx, id, map, record_fields, text, row_id) do
    {name, value} =
      case String.split(text, "=", parts: 2) do
        [n, v] -> {String.trim(n), v}
        [n] -> {String.trim(n), ""}
      end

    rule = if map == :env, do: @env_name, else: @header_name
    words = if map == :env, do: "use a variable name: A–Z, 0–9 and _", else: "not a header name"
    names = entries(ctx, id, map, record_fields) |> Enum.map(& &1.name)

    cond do
      not Regex.match?(rule, name) ->
        [{:row_error, row_id, words}]

      name in names ->
        [{:row_error, row_id, "already in the list"}]

      secret?(name, value) ->
        [{:paste, secret_target(record_fields, id, map, name)}]

      true ->
        stage(ctx, id, map, record_fields, &(&1 ++ [%{"name" => name, "value" => value}]))
    end
  end

  defp put_entry(list, name, value) do
    Enum.map(list, fn e ->
      if R.field(e, "name") == name, do: %{"name" => name, "value" => value}, else: e
    end)
  end

  @doc "The desired list in the command form, from the staged list or the record."
  def desired(ctx, id, map, record_fields) do
    case ctx |> R.staged("mcp_server", id) |> Map.get(field(map)) do
      nil ->
        for e <- R.field(record_fields, field(map)) || [] do
          if R.field(e, "secret") == true,
            do: %{"name" => R.field(e, "name"), "keep" => true},
            else: %{"name" => R.field(e, "name"), "value" => R.field(e, "value")}
        end

      staged ->
        staged
    end
  end

  defp stage(ctx, id, map, record_fields, fun) do
    [{:stage, {"mcp_server", id}, %{field(map) => fun.(desired(ctx, id, map, record_fields))}}]
  end

  defp secret_target(record_fields, id, map, name) do
    slot = if map == :env, do: "env:#{name}", else: "header:#{name}"
    entry = Enum.find(R.field(record_fields, field(map)) || [], &(R.field(&1, "name") == name))
    set = entry != nil and R.field(entry, "secret") == true

    %{
      row_id: "kv:#{field(map)}:#{name}",
      action: "mcp.set_secret",
      target: %{"id" => id, "map" => field(map), "name" => name},
      attributes: %{},
      slot: slot,
      label: "#{name} of #{R.field(record_fields, "name")}",
      set?: set,
      kind: "mcp_server",
      expected: %{
        "key" =>
          if(set,
            do: %{"set" => true, "hint" => R.field(entry, "hint")},
            else: %{"set" => false, "hint" => nil}
          )
      },
      then: []
    }
  end
end
