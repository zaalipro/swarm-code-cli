defmodule SwarmCodeCLI.UI.Settings.Sections.KeysInput do
  @moduledoc """
  pass74 U3-10 (spec §2.16, F11, sketch §4.15): Keys & input. The keymap
  (standard or vim), wheel scrolling and its lines per notch (disabled while
  the wheel is off), the editor for Ctrl-X, the hint letters, what this
  terminal reports, and the Key bindings sub-page: every binding grouped as
  the help sheet groups them, with its effective keys (cli.json overrides
  applied), the contexts it works in, and where the keys come from (`·
  default`, `· changed`, `fixed`). Enter captures a new key (replaces), `+`
  adds one (≤ 4), `x` removes the last of several, `X` unbinds (asks), `r`
  resets one binding, `▸ Reset every key binding…` asks first. `/ctrl-j`
  filters to what Ctrl-J does everywhere (the keys column carries the
  names). Overrides cli.json could not honour are attention AT14.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :keys

  alias SwarmCodeCLI.UI.Keymap.{Bindings, KeyName, Overrides}
  alias SwarmCodeCLI.UI.Settings.{Attention, Confirm, Page, Picker, Row, Rows}
  alias SwarmCodeCLI.UI.Settings.Editors.KeyCapture

  @sub :key_bindings
  @group_words %{
    session: "session",
    layers: "palette and layers",
    runs: "runs and approvals",
    focus: "focus",
    navigate: "moving around",
    act: "acting on a row",
    edit: "the composer",
    vim: "vim (NORMAL and VISUAL)"
  }

  @impl true
  def loads(_ctx), do: []

  @impl true
  def rows(ctx) do
    rows = Rows.registry(ctx, :keys)
    mouse? = pref(ctx, "mouse", true) != false

    Enum.map(rows, fn
      %Row{key: "terminal.wheel_lines"} = row when not mouse? ->
        %Row{
          row
          | state: :disabled,
            lines: row.lines ++ [[{"only when Wheel scrolling is on", :text_faint}]]
        }

      %Row{key: "terminal.keys"} = row ->
        bindings_link(row, ctx)

      %Row{key: "terminal.terminal_facts"} = row ->
        %Row{row | value: [{terminal_facts(ctx), :text_muted}], state: :readonly}

      row ->
        row
    end)
  end

  @impl true
  def sub_rows(ctx, {@sub, context}), do: binding_rows(ctx, context)
  def sub_rows(ctx, @sub), do: binding_rows(ctx, nil)
  def sub_rows(_ctx, _sub), do: []

  @impl true
  def title(%{page: %Page{sub: {@sub, _}}}), do: "Keys & input › Key bindings"
  def title(%{page: %Page{sub: @sub}}), do: "Keys & input › Key bindings"
  def title(_ctx), do: "Keys & input"

  @impl true
  def attention(ctx) do
    case Overrides.attention(ctx.overrides) do
      nil ->
        []

      {title, reason} ->
        [
          %Attention{
            id: "AT14",
            severity: :warning,
            section: :keys,
            target: {:key, "terminal.keys"},
            title: title,
            reason: reason
          }
        ]
    end
  end

  # ---------------------------------------------------------------- actions

  @impl true
  def act(_ctx, %Row{id: "key:terminal.keys"}, verb) when verb in [:open, :enter, :open_row],
    do: [{:open, %Page{section: :keys, sub: {@sub, nil}}}]

  def act(ctx, %Row{id: "bind:context"}, verb) when verb in [:open, :enter, :open_row] do
    current = current_context(ctx)

    options =
      [%{value: nil, label: "all", hint: "every binding"}] ++
        Enum.map(contexts(), &%{value: &1, label: context_words(&1), hint: nil})

    [
      {:picker,
       %Picker{
         id: "keys-context",
         title: "Context",
         options: options,
         current: current,
         on_pick: {:section, :keys, :context},
         opener: "bind:context",
         filter?: false
       }}
    ]
  end

  def act(ctx, %Row{id: "act:reset_bindings"}, verb) when verb in [:open, :enter, :open_row] do
    count = map_size(keys_source(ctx))

    if count == 0 do
      [{:toast, "Every key binding is already its default", :info}]
    else
      [
        {:confirm,
         %Confirm{
           id: "reset-bindings",
           title: "Reset #{count} key #{plural(count, "binding")}?",
           lines: ["Every binding goes back to its default keys. u undoes it."],
           safe: "Cancel",
           danger: "R  Reset",
           letter: "R",
           opener: "act:reset_bindings"
         }, then: [{:reset, ["terminal.keys"]}]}
      ]
    end
  end

  def act(ctx, %Row{target: {:binding, sid, id}} = row, verb) do
    binding_act(ctx, row, sid, id, verb)
  end

  def act(_ctx, _row, _verb), do: :default

  @doc false
  def picked(_ctx, :context, context) when is_atom(context),
    do: [:back, {:open, %Page{section: :keys, sub: {@sub, context}}}]

  def picked(_ctx, _tag, _value), do: []

  defp binding_act(ctx, row, sid, id, verb) do
    cond do
      Overrides.fixed?(id) and verb in [:add_key, :delete, :remove_all, :reset, :open, :enter] ->
        [{:toast, ~s("#{row.label}" is fixed), :warning}]

      verb == :add_key ->
        [{:edit, row.id, %{add?: true}}]

      verb == :reset ->
        source = keys_source(ctx)

        if Map.has_key?(source, sid),
          do: [{:patch, "terminal.keys", Map.delete(source, sid)}],
          else: [{:toast, "#{row.label} already has its default keys", :info}]

      verb == :delete ->
        keys = Overrides.effective_keys(ctx.overrides, id) |> Enum.map(&KeyName.name/1)

        case keys do
          [_, _ | _] ->
            [{:patch, "terminal.keys", Map.put(keys_source(ctx), sid, Enum.drop(keys, -1))}]

          _ ->
            [{:toast, "x removes one of several keys · X unbinds", :info}]
        end

      verb == :remove_all ->
        [
          {:confirm,
           %Confirm{
             id: "unbind-" <> sid,
             title: "Unbind #{row.label}?",
             lines: ["Its keys do nothing until you give it one; r puts the default back."],
             safe: "Keep it",
             danger: "U  Unbind",
             letter: "U",
             opener: row.id
           }, then: [{:patch, "terminal.keys", Map.put(keys_source(ctx), sid, [])}]}
        ]

      true ->
        :default
    end
  end

  # ------------------------------------------------------------------- rows

  defp bindings_link(row, ctx) do
    changed = map_size(keys_source(ctx))
    ignored = length((ctx.overrides && ctx.overrides.errors) || [])

    words =
      [
        "#{length(Bindings.all())} actions",
        if(changed > 0, do: "#{changed} changed"),
        if(ignored > 0, do: "#{ignored} ignored")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    marks = if ignored > 0, do: Enum.uniq([:attention | row.marks]), else: row.marks

    %Row{
      row
      | kind: :link,
        value: [{words, :text_muted}],
        tag: [{"Enter open", :text_faint}],
        marks: marks,
        editor: nil,
        keys: [{"Enter", :enter, "open the key bindings"}]
    }
  end

  @doc false
  def binding_rows(ctx, context) do
    tier = tier(ctx)
    source = keys_source(ctx)

    picker = %Row{
      id: "bind:context",
      kind: :action,
      label: "Context",
      value: [{"#{if context, do: context_words(context), else: "all"} ▾", :text_primary}],
      tag: [{"/ filter or a key (/ctrl-j)", :text_faint}],
      keys: [{"Enter", :enter, "pick a context"}]
    }

    reset = %Row{
      id: "act:reset_bindings",
      kind: :action,
      label: "Reset every key binding…",
      value: [{"#{map_size(source)} changed · asks first", :text_muted}],
      keys: [{"Enter", :enter, "reset them"}]
    }

    groups =
      Bindings.all()
      |> Enum.filter(&(context == nil or context in Overrides.contexts(&1.id)))
      |> Enum.group_by(& &1.group)

    body =
      Enum.flat_map(Bindings.groups() ++ (Map.keys(groups) -- Bindings.groups()), fn group ->
        case Map.get(groups, group, []) do
          [] ->
            []

          bindings ->
            [Row.heading(Map.get(@group_words, group, to_string(group)))] ++
              Enum.map(bindings, &binding_row(&1, ctx, source, tier))
        end
      end)

    [picker] ++ body ++ [Row.heading("danger"), reset] ++ facts_rows()
  end

  @doc """
  The Key bindings rows a `/` query keeps (§4.3): a key name (`ctrl-j`,
  `Ctrl-J`) keeps what that key does in every context
  (`Overrides.bindings_for_key/2`); other words match the labels.
  """
  @spec filter(map(), [Row.t()], String.t()) :: [Row.t()]
  def filter(ctx, rows, query) do
    query = query |> String.trim() |> String.trim_leading("/")
    bindings = rows |> Enum.filter(&match?(%Row{target: {:binding, _, _}}, &1))

    by_key = Overrides.bindings_for_key(ctx.overrides, query)

    case by_key do
      [_ | _] ->
        ids = MapSet.new(by_key, fn {binding, _contexts} -> binding.id end)
        Enum.filter(bindings, fn %Row{target: {:binding, _, id}} -> id in ids end)

      [] ->
        words = String.downcase(query)
        Enum.filter(bindings, &String.contains?(String.downcase(&1.label), words))
    end
  end

  defp binding_row(binding, ctx, source, tier) do
    sid = Atom.to_string(binding.id)
    keys = Overrides.effective_keys(ctx.overrides, binding.id)
    fixed? = Overrides.fixed?(binding.id)

    key_text =
      case keys do
        [] -> "unbound"
        keys -> keys |> Enum.map(&KeyName.format(&1, tier)) |> Enum.uniq() |> Enum.join(", ")
      end

    names = keys |> Enum.map(&KeyName.name/1) |> Enum.uniq() |> Enum.join(" ")

    {from, marks} =
      cond do
        fixed? ->
          {{"fixed", :text_faint}, []}

        Map.has_key?(source, sid) and Overrides.keys_for(ctx.overrides, binding.id) != :default ->
          {{"· changed", :text_muted}, [:changed]}

        Map.has_key?(source, sid) ->
          {{"· ignored", :warning}, [:attention]}

        true ->
          {{"· default", :text_faint}, []}
      end

    contexts = binding.id |> Overrides.contexts() |> Enum.map_join(", ", &context_words/1)

    %Row{
      id: "bind:" <> sid,
      kind: :setting,
      key: "terminal.keys",
      label: binding.label,
      value: [{key_text, if(keys == [], do: :text_ghost, else: :text_primary)}],
      tag: [from],
      marks: marks,
      state: if(fixed?, do: :readonly, else: :normal),
      columns: [
        {key_text, if(keys == [], do: :text_ghost, else: :text_primary), 1},
        {contexts, :text_muted, 3},
        {names, :text_ghost, 9},
        {elem(from, 0), elem(from, 1), 2}
      ],
      editor:
        if(fixed?,
          do: nil,
          else: {KeyCapture, %{mode: :binding, binding: sid, label: binding.label}}
        ),
      keys:
        if(fixed?,
          do: [],
          else: [
            {"Enter", :enter, "capture a new key"},
            {"+", :add_key, "add a key"},
            {"x", :delete, "remove a key"},
            {"X", :remove_all, "unbind"},
            {"r", :reset, "reset"}
          ]
        ),
      target: {:binding, sid, binding.id}
    }
  end

  defp facts_rows do
    [
      Row.info(
        "bind-fixed",
        "fixed: Esc, Enter, the arrows, Ctrl-C, ? and F1, Ctrl-S, and y Y A d D n where an approval shows",
        role: :text_faint
      ),
      Row.info(
        "bind-recover",
        "Remapped yourself out of a key? swarmcode config reset terminal.keys",
        role: :text_faint
      )
    ]
  end

  # ---------------------------------------------------------------- helpers

  @doc false
  def contexts do
    Bindings.contexts()
  end

  @doc "A context's words for the Context picker and the contexts column."
  @spec context_words(atom()) :: String.t()
  def context_words(:composer), do: "composer"
  def context_words(:composer_normal), do: "vim NORMAL"
  def context_words(:composer_visual), do: "vim VISUAL"
  def context_words(:main), do: "transcript"
  def context_words(:inspector), do: "inspector"
  def context_words(:picker), do: "pickers"
  def context_words(:field), do: "fields"
  def context_words(:dialog), do: "dialogs"
  def context_words(:overlay), do: "agent overlay"
  def context_words(:hint), do: "hint mode"
  def context_words(other), do: other |> Atom.to_string() |> String.replace("_", " ")

  defp current_context(%{page: %Page{sub: {@sub, context}}}), do: context
  defp current_context(_ctx), do: nil

  defp terminal_facts(ctx) do
    caps = ctx.caps || %{}

    [
      "bracketed paste #{feature(Map.get(caps, :paste))}",
      "focus #{feature(Map.get(caps, :focus))}",
      "wheel #{if pref(ctx, "mouse", true) != false, do: "on", else: "off"}",
      "enhanced keys never"
    ]
    |> Enum.join(" · ")
  end

  defp feature(:supported), do: "yes"
  defp feature(:best_effort), do: "best effort"
  defp feature(_), do: "no"

  defp keys_source(ctx) do
    case pref(ctx, "keys", %{}) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  defp pref(ctx, name, default), do: Map.get(ctx.prefs || %{}, name, default)

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp tier(ctx) do
    caps = ctx.caps

    cond do
      is_map(caps) and Map.get(caps, :ascii?) == true -> :ascii
      is_map(caps) -> Map.get(caps, :glyph_tier, :measured)
      true -> :measured
    end
  end
end
