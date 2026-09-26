defmodule SwarmCodeCLI.UI.Settings.ModelPicker do
  @moduledoc """
  The model picker editor (F4, §3.7.8 type `:model`): every provider's models grouped by
  provider, with context and price columns from Pricing, `not in the last fetch` marks, the
  null choice of a nullable entry, a filter over provider and model (`provider/model` works
  too), a typed model when nothing matches, and `f` to fetch the focused provider's list.

  An Editor (§3.7.2): `init/3`, `handle/3`, `display/3`. Pure; the options come from the
  layer's `records:model_options` page (and `records:providers` for the fetch state), read
  from the context on every call so data that arrives while the picker is open shows up.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  defstruct key: nil,
            title: "Model",
            subtitle: nil,
            current: nil,
            nullable: false,
            null_label: nil,
            provider_id: nil,
            query: "",
            filtering: false,
            cursor: 0,
            placed: false

  @type t :: %__MODULE__{}

  @doc """
  Opens the picker for a row. `opts`: `:current` (the wire value), `:nullable`,
  `:null_label` (`the chat model`), `:provider_id` (limit to one provider — a provider's
  *Default model* row), `:title`, `:subtitle` (`new conversations`).
  """
  def init(row, opts, ctx) do
    opts = Map.new(opts)
    key = Map.get(row, :key)

    current =
      case Map.fetch(opts, :current) do
        {:ok, v} -> v
        :error -> if key, do: R.value_of(ctx, key), else: nil
      end

    {:ok,
     %__MODULE__{
       key: key,
       title: Map.get(opts, :title) || Map.get(row, :label) || "Model",
       subtitle: Map.get(opts, :subtitle),
       current: current,
       nullable: Map.get(opts, :nullable, false),
       null_label: Map.get(opts, :null_label),
       provider_id: Map.get(opts, :provider_id)
     }}
  end

  # ------------------------------------------------------------------ keys

  def handle(%__MODULE__{} = s, event, ctx) do
    s = place(s, ctx)
    choices = choices(s, ctx)
    count = length(choices)

    case event do
      {:key, :up} ->
        {:cont, %{s | cursor: clamp(s.cursor - 1, count)}}

      {:key, :down} ->
        {:cont, %{s | cursor: clamp(s.cursor + 1, count)}}

      {:key, :page_up} ->
        {:cont, %{s | cursor: clamp(s.cursor - 10, count)}}

      {:key, :page_down} ->
        {:cont, %{s | cursor: clamp(s.cursor + 10, count)}}

      {:key, :home} ->
        {:cont, %{s | cursor: 0}}

      {:key, :end} ->
        {:cont, %{s | cursor: max(count - 1, 0)}}

      {:key, :tab} ->
        {:cont, %{s | cursor: next_group(choices, s.cursor, 1)}}

      {:key, :backtab} ->
        {:cont, %{s | cursor: next_group(choices, s.cursor, -1)}}

      {:key, :enter} ->
        choose(s, choices, ctx)

      {:key, :escape} when s.query != "" or s.filtering ->
        {:cont, %{s | query: "", filtering: false, cursor: 0}}

      {:key, :escape} ->
        {:cancel, s}

      {:key, :backspace} ->
        {:cont, reset_query(s, drop_last(s.query), ctx)}

      {:key, {:ctrl, "u"}} ->
        {:cont, reset_query(s, "", ctx)}

      {:text, "/"} when not s.filtering and s.query == "" ->
        {:cont, %{s | filtering: true}}

      {:text, "f"} when not s.filtering and s.query == "" ->
        fetch(s, choices)

      {:text, text} ->
        {:cont, reset_query(%{s | filtering: true}, s.query <> one_line(text), ctx)}

      {:paste, text} ->
        {:cont, reset_query(%{s | filtering: true}, s.query <> one_line(text), ctx)}

      _ ->
        {:cont, s}
    end
  end

  # QA #2 P0-2: while the options are on their way (or no provider lists a
  # model) the list holds only the null choice, which the popover does not
  # draw; Enter there erased the model. It waits for the options instead.
  defp choose(s, choices, ctx) do
    case Enum.at(choices, s.cursor) do
      nil ->
        {:cont, s}

      {:null, _} ->
        if R.loaded?(ctx, "model_options") and groups(s, ctx) != [],
          do: {:commit, nil, s},
          else: {:cont, s}

      {:model, pid, _name, model, _fields} ->
        {:commit, %{"provider_id" => pid, "model" => model}, s}

      {:typed, pid, _name, model} ->
        {:commit, %{"provider_id" => pid, "model" => model}, s}
    end
  end

  defp fetch(s, choices) do
    case provider_of(Enum.at(choices, s.cursor)) || first_provider(choices) do
      nil -> {:cont, s}
      pid -> {:ops, [{:task, "provider.fetch_models", %{"id" => pid}, %{}}], s}
    end
  end

  defp provider_of({:model, pid, _, _, _}), do: pid
  defp provider_of({:typed, pid, _, _}), do: pid
  defp provider_of(_), do: nil

  defp first_provider(choices), do: Enum.find_value(choices, &provider_of/1)

  defp reset_query(s, query, _ctx), do: %{s | query: query, cursor: 0}

  defp drop_last(""), do: ""
  defp drop_last(q), do: String.slice(q, 0, String.length(q) - 1)

  defp one_line(text), do: text |> String.replace(~r/[\r\n\t]+/, " ")

  defp clamp(_i, 0), do: 0
  defp clamp(i, count), do: i |> max(0) |> min(count - 1)

  defp next_group(choices, cursor, dir) do
    here = provider_of(Enum.at(choices, cursor))
    indexed = Enum.with_index(choices)
    ordered = if dir == 1, do: indexed, else: Enum.reverse(indexed)

    starts =
      ordered
      |> Enum.filter(fn {c, i} ->
        pid = provider_of(c)
        prev = if i > 0, do: provider_of(Enum.at(choices, i - 1))
        pid != nil and pid != prev
      end)
      |> Enum.map(&elem(&1, 1))

    target =
      if dir == 1,
        do: Enum.find(starts, &(&1 > cursor and provider_of(Enum.at(choices, &1)) != here)),
        else: Enum.find(starts, &(&1 < cursor and provider_of(Enum.at(choices, &1)) != here))

    target || List.first(if dir == 1, do: Enum.sort(starts), else: Enum.sort(starts, :desc)) ||
      cursor
  end

  # Every page of the options is in (QA #2 P0-2: they arrive page by page).
  defp complete?(ctx) do
    case R.records_page(ctx, "model_options") do
      nil -> false
      page -> (Map.get(page, :next_cursor) || Map.get(page, "next_cursor")) == nil
    end
  end

  @doc """
  What the picker reads from the service (QA #2 P0-2): the options, asked
  again each time the picker opens so a provider created or fetched in this
  session is offered, and the providers for the fetch state and the names.
  """
  @spec loads() :: [{:records, String.t(), map()}]
  def loads, do: [{:records, "model_options", %{}}, {:records, "providers", %{}}]

  # the cursor starts on the current value once the options have arrived
  # (QA #2 P0-2: not before; the null choice alone placed it for good)
  defp place(%__MODULE__{placed: true} = s, _ctx), do: s

  defp place(s, ctx) do
    choices = choices(s, ctx)

    if choices == [] or not complete?(ctx) do
      s
    else
      index =
        Enum.find_index(choices, fn
          {:null, _} -> s.current == nil
          {:model, pid, _, m, _} -> current?(s, pid, m)
          _ -> false
        end)

      %{s | cursor: index || 0, placed: true}
    end
  end

  defp current?(s, pid, model) do
    is_map(s.current) and R.field(s.current, "provider_id") == pid and
      R.field(s.current, "model") == model
  end

  # --------------------------------------------------------------- choices

  @doc "The providers and their options, filtered: `[{pid, name, kind, [option fields]}]`."
  def groups(s, ctx) do
    ctx
    |> R.items("model_options")
    |> Enum.map(&R.fields/1)
    |> Enum.filter(&(s.provider_id in [nil, R.field(&1, "provider_id")]))
    |> Enum.chunk_by(&R.field(&1, "provider_id"))
    |> Enum.map(fn [first | _] = options ->
      {R.field(first, "provider_id"), R.field(first, "provider_name"),
       R.field(first, "provider_kind"), options}
    end)
  end

  @doc "The choosable items in order (null, models, typed)."
  def choices(s, ctx) do
    groups = groups(s, ctx)
    {prov_q, model_q} = split_query(s.query)

    matched =
      for {pid, name, _kind, options} <- groups,
          opt <- options,
          matches?(name, R.field(opt, "model"), prov_q, model_q) do
        {:model, pid, name, R.field(opt, "model"), opt}
      end

    null = if s.nullable and s.query == "", do: [{:null, s.null_label || "not set"}], else: []

    typed =
      if s.query != "" and matched == [] and model_q != "" do
        typed_targets(s, groups, prov_q)
        |> Enum.map(fn {pid, name} -> {:typed, pid, name, model_q} end)
      else
        []
      end

    null ++ matched ++ typed
  end

  defp typed_targets(s, groups, prov_q) do
    named =
      if prov_q != "",
        do: for({pid, name, _, _} <- groups, prefix?(name, prov_q), do: {pid, name}),
        else: []

    cond do
      named != [] ->
        named

      is_map(s.current) ->
        pid = R.field(s.current, "provider_id")
        Enum.find_value(groups, [], fn {id, name, _, _} -> if id == pid, do: [{id, name}] end)

      true ->
        groups |> Enum.take(1) |> Enum.map(fn {pid, name, _, _} -> {pid, name} end)
    end
  end

  defp split_query(query) do
    q = String.trim(query)

    case String.split(q, "/", parts: 2) do
      [prov, model] -> {String.trim(prov), String.trim(model)}
      [only] -> {"", only}
    end
  end

  defp matches?(_name, _model, "", ""), do: true

  defp matches?(name, model, prov_q, model_q) do
    prov_ok = prov_q == "" or prefix?(name, prov_q)
    words = String.split(String.downcase(model_q))
    hay = String.downcase("#{name} #{model}")
    prov_ok and Enum.all?(words, &String.contains?(hay, &1))
  end

  defp prefix?(name, q), do: String.starts_with?(String.downcase(name || ""), String.downcase(q))

  # --------------------------------------------------------------- display

  @doc """
  The picker's drawing: `%{value, lines, popover, context, footer}`. `popover` is
  `%{kind: :picker, title, meta, query, rows, position, footer}`; each row is
  `%{id, kind, segments, focused?}` with `kind` `:group | :model | :null | :typed | :info`.
  """
  def display(%__MODULE__{} = s, ctx) do
    s = place(s, ctx)
    choices = choices(s, ctx)
    groups = groups(s, ctx)
    providers = R.items(ctx, "providers")
    focused = Enum.at(choices, s.cursor)
    models = Enum.sum(for {_, _, _, opts} <- groups, do: length(opts))

    rows =
      cond do
        not R.loaded?(ctx, "model_options") ->
          [%{id: "loading", kind: :info, segments: [{"…", :text_faint}], focused?: false}]

        groups == [] ->
          [
            %{
              id: "empty",
              kind: :info,
              segments: [{"No provider lists a model yet · add one on Providers", :text_muted}],
              focused?: false
            }
          ]

        true ->
          picker_rows(s, ctx, choices, providers, focused)
      end

    footer = [
      {"↑↓", "move"},
      {"Enter", "choose"},
      {"Tab", "next provider"},
      {"f", "fetch"},
      {"Esc", "close"}
    ]

    popover = %{
      kind: :picker,
      title: s.title,
      subtitle: s.subtitle,
      meta: "#{R.count(length(groups), "provider")} · #{R.count(models, "model")}",
      query:
        if(s.query == "" and not s.filtering,
          do: [{"/ ", :text_muted}, {"type to filter · provider/model works too", :text_ghost}],
          else: [{"/ ", :text_muted}, {s.query, :text_primary}]
        ),
      rows: rows,
      position: if(choices == [], do: "0 of 0", else: "#{s.cursor + 1} of #{length(choices)}"),
      footer: footer
    }

    %{
      value: value_segments(focused, s),
      lines: [],
      popover: popover,
      context: :settings_picker,
      footer: footer
    }
  end

  defp value_segments({:model, _pid, name, model, _}, _s),
    do: [{model, :text_primary}, {" · #{name}", :text_faint}]

  defp value_segments({:typed, _pid, name, model}, _s),
    do: [{model, :text_primary}, {" · #{name}", :text_faint}]

  defp value_segments({:null, label}, _s), do: [{label, :text_muted}]
  defp value_segments(_, _s), do: []

  defp picker_rows(s, ctx, choices, providers, focused) do
    null_rows =
      for {:null, label} = c <- choices do
        %{
          id: "null",
          kind: :null,
          segments: [{"  ", :text_faint}, {label, :text_muted}],
          focused?: c == focused
        }
      end

    by_provider =
      Enum.group_by(Enum.filter(choices, &match?({:model, _, _, _, _}, &1)), &provider_of/1)

    typed = Enum.filter(choices, &match?({:typed, _, _, _}, &1))

    group_rows =
      for {pid, name, kind, _options} <- groups(s, ctx), Map.has_key?(by_provider, pid) do
        header = %{
          id: "group:#{pid}",
          kind: :group,
          segments: group_header(ctx, pid, name, kind, providers),
          focused?: false
        }

        items =
          for {:model, ^pid, _n, model, opt} = c <- Map.fetch!(by_provider, pid) do
            %{
              id: "model:#{pid}:#{model}",
              kind: :model,
              segments: model_segments(ctx, s, pid, model, opt),
              focused?: c == focused
            }
          end

        [header | items]
      end
      |> List.flatten()

    typed_rows =
      for {:typed, pid, name, model} = c <- typed do
        %{
          id: "typed:#{pid}",
          kind: :typed,
          segments: [
            {"use “#{model}” with #{name} as typed", :text_primary},
            {" · not in its list", :text_faint}
          ],
          focused?: c == focused
        }
      end

    null_rows ++ group_rows ++ typed_rows
  end

  defp group_header(ctx, pid, name, kind, providers) do
    provider = Enum.find(providers, &(R.record_id(&1) == pid))
    last = provider && R.field(provider, "last_fetch")
    task = R.task(ctx, "provider.fetch_models", %{"id" => pid})

    state =
      cond do
        R.running?(task) ->
          {_id, t} = task

          [
            {"  " <> R.glyph(ctx, :running) <> " ", :info},
            {"fetching the model list · #{R.elapsed_s(ctx, t)} s", :text_muted}
          ]

        match?({_, _}, task) and R.field(elem(task, 1), "state") in ["failed", "timeout"] ->
          {_id, t} = task

          [
            {"  " <> R.glyph(ctx, :error) <> " ", :error},
            {to_string(R.field(t, "message")), :text_muted},
            {"   f fetch again", :text_faint}
          ]

        is_map(last) and R.field(last, "state") == "done" ->
          [
            {"  #{kind_label(kind)} · fetched this session #{R.hhmm(R.field(last, "at"))}",
             :text_faint}
          ]

        true ->
          [{"  #{kind_label(kind)} · not fetched this session", :text_faint}]
      end

    [{name, :text_muted} | state]
  end

  defp model_segments(ctx, s, pid, model, opt) do
    current = current?(s, pid, model)
    price = R.field(opt, "price")
    fetched = R.field(opt, "in_last_fetch")

    price_seg =
      if is_map(price) and R.field(price, "input") != nil,
        do:
          {pad("#{R.money(R.field(price, "input"))} · #{R.money(R.field(price, "output"))}", 16),
           :text_muted},
        else: {pad("no price", 16), :warning}

    [
      {if(current, do: R.glyph(ctx, :ok) <> " ", else: "  "), :success},
      {pad(model, 34), :text_primary},
      {pad(R.context(R.field(opt, "context_window")), 16), :text_muted},
      price_seg
    ] ++
      if(fetched == false, do: [{"not in the last fetch", :text_faint}], else: []) ++
      if(current, do: [{"  current", :text_faint}], else: []) ++
      if(R.field(opt, "provider_default") == true and not current,
        do: [{"  provider default", :text_faint}],
        else: []
      )
  end

  defp pad(text, n), do: String.pad_trailing(to_string(text), n)

  @doc "The provider kind in words."
  def kind_label("anthropic"), do: "Anthropic"
  def kind_label("openai_compatible"), do: "OpenAI-compatible"
  def kind_label(other), do: to_string(other || "")

  @doc "A model wire value in words: `deepseek-v4-pro · DeepSeek`."
  def describe(nil, _ctx, null_label), do: [{null_label || "not set", :text_muted}]

  def describe(value, ctx, _null_label) do
    pid = R.field(value, "provider_id")
    model = R.field(value, "model")

    case Enum.find(R.items(ctx, "providers"), &(R.record_id(&1) == pid)) do
      nil ->
        if R.loaded?(ctx, "providers"),
          do: [{"! the provider was deleted; pick another", :warning}],
          else: [{model || "", :text_primary}]

      p ->
        [{model || "", :text_primary}, {" · #{R.field(p, "name")}", :text_faint}]
    end
  end
end
