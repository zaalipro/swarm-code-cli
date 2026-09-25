defmodule SwarmCodeCLI.UI.Settings.Sections.Approvals do
  @moduledoc """
  pass74 U3-7 (spec §2.10, F14, D12–D14): Approvals & trust, for any
  non-scratch project (the picker row first; the session's project by
  default). Raising approvals to full access asks; going down does not.
  Trusting asks and lists the hooks that will start running; untrusting (D13,
  CLI-local) asks and says approvals go back to read-only. The always-allowed
  command families are a list (`x` forgets one, undoable; `▸ Forget all…`
  asks). A collapsed *other projects* group lists every other project's
  families; Enter switches the page to that project.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :approvals

  alias SwarmCodeCLI.UI.Settings.{Confirm, Picker, Row, Rows}

  @impl true
  def loads(ctx) do
    base = [{:values, [:approvals]}]

    case project_id(ctx) do
      nil -> base
      id -> base ++ [{:record, "project_config", id}]
    end
  end

  @impl true
  def rows(ctx) do
    case project(ctx) do
      nil ->
        [
          picker_row(ctx),
          Row.info("no-project", "There is no project in this session. Pick one above.")
        ]

      project ->
        rows =
          ctx
          |> Rows.registry(:approvals)
          |> Enum.map(&decorate(&1, ctx, project))
          |> Enum.flat_map(&with_families(&1, ctx))

        [picker_row(ctx) | rows] ++ forget_all(ctx) ++ others(ctx, project)
    end
  end

  # --------------------------------------------------------------- actions

  @impl true
  def act(ctx, %Row{id: "act:project_picker"}, verb) when verb in [:open, :enter, :open_row] do
    options =
      for p <- projects(ctx), get(p, :scratch) != true do
        %{
          value: get(p, :id),
          label: get(p, :name) || "?",
          hint: "#{get(p, :root) || ""}#{if get(p, :current), do: " · this session", else: ""}"
        }
      end

    [
      {:picker,
       %Picker{
         id: "approvals-project",
         title: "Project",
         options: options,
         current: project_id(ctx),
         on_pick: {:section, :approvals, :project},
         opener: "act:project_picker"
       }}
    ]
  end

  def act(ctx, %Row{id: "act:forget_all"}, verb) when verb in [:open, :enter, :open_row] do
    families = families(ctx)
    name = project_name(ctx)
    count = length(families)

    listed =
      families
      |> Enum.take(12)
      |> Enum.map(&("  " <> &1))
      |> Kernel.++(if count > 12, do: ["  +#{count - 12} more"], else: [])

    [
      {:confirm,
       %Confirm{
         id: "forget-all",
         title: "Forget #{count} #{plural(count, "command")}?",
         lines: ["#{name} asks again before each of these:" | listed],
         safe: "Keep them",
         danger: "F  Forget all",
         letter: "F",
         opener: "act:forget_all"
       }, then: [{:patch, "project.allow", []}]}
    ]
  end

  def act(ctx, %Row{target: {:family, family}}, :delete),
    do: [{:patch, "project.allow", List.delete(families(ctx), family)}]

  def act(_ctx, %Row{target: {:project, id}}, verb) when verb in [:open, :enter, :open_row],
    do: [{:project, id}]

  def act(_ctx, _row, _verb), do: :default

  @doc false
  @impl true
  def picked(_ctx, :project, id) when is_binary(id), do: [{:project, id}]
  def picked(_ctx, _tag, _value), do: []

  @impl true
  def commit(ctx, %Row{key: "project.approval_mode"}, "full_access") do
    if current(ctx, "project.approval_mode") == "full_access" do
      :default
    else
      name = project_name(ctx)
      now = mode_words(current(ctx, "project.approval_mode"))

      [
        {:confirm,
         %Confirm{
           id: "full-access",
           title: "Give #{name} full access?",
           lines: ["Agents run commands and make edits without asking you."],
           safe: "Keep #{now}",
           danger: "F  Give full access",
           letter: "F",
           opener: "key:project.approval_mode"
         }, then: [{:patch, "project.approval_mode", "full_access"}]}
      ]
    end
  end

  def commit(ctx, %Row{key: "project.trusted"}, true) do
    if current(ctx, "project.trusted") == true do
      :default
    else
      name = project_name(ctx)
      hooks = hook_lines(ctx)

      lines =
        ["Agents read AGENTS.md, edits are allowed, and the project's hooks start running:"] ++
          if(hooks == [], do: ["  (no hooks)"], else: hooks)

      [
        {:confirm,
         %Confirm{
           id: "trust",
           title: "Trust #{name}?",
           lines: lines,
           safe: "Not now",
           danger: "T  Trust",
           letter: "T",
           opener: "key:project.trusted"
         }, then: [{:patch, "project.trusted", true}]}
      ]
    end
  end

  def commit(ctx, %Row{key: "project.trusted"}, false) do
    if current(ctx, "project.trusted") == false do
      :default
    else
      [
        {:confirm,
         %Confirm{
           id: "untrust",
           title: "Stop trusting #{project_name(ctx)}?",
           lines: ["Hooks stop running and approvals go back to read-only."],
           safe: "Keep trust",
           danger: "U  Stop trusting",
           letter: "U",
           opener: "key:project.trusted"
         }, then: [{:patch, "project.trusted", false}]}
      ]
    end
  end

  def commit(_ctx, _row, _value), do: :default

  # ------------------------------------------------------------------ rows

  defp picker_row(ctx) do
    name =
      case project(ctx) do
        nil -> "pick a project"
        p -> get(p, :name) || "?"
      end

    here = if current_project?(ctx), do: " · this session's project", else: ""

    %Row{
      id: "act:project_picker",
      kind: :action,
      label: "Project",
      value: [{name <> " ▾", :title}, {here, :text_faint}],
      tag: [{"writes to #{name} (project)", :text_faint}],
      keys: [{"Enter", :enter, "pick a project"}]
    }
  end

  defp decorate(%Row{key: "project.trusted"} = row, _ctx, project) do
    case get(project, :trusted_at) do
      at when is_binary(at) and at != "" ->
        %Row{row | lines: row.lines ++ [[{"since #{String.slice(at, 0, 10)}", :text_faint}]]}

      _ ->
        row
    end
  end

  defp decorate(%Row{key: "project.approval_env"} = row, ctx, _project) do
    case env_var(ctx, "SWARM_APPROVAL") do
      nil ->
        %Row{row | value: [{"SWARM_APPROVAL not set", :text_ghost}], state: :readonly}

      value ->
        %Row{
          row
          | value: [{"SWARM_APPROVAL=#{value}", :text_muted}],
            lines: [[{"read only by unsaved live sessions; it has no effect here", :text_faint}]],
            state: :readonly
        }
    end
  end

  defp decorate(%Row{key: "project.root"} = row, _ctx, project),
    do: %Row{row | value: [{get(project, :root) || "", :text_muted}], state: :readonly}

  defp decorate(%Row{key: "project.last_opened"} = row, _ctx, project) do
    words =
      case get(project, :last_opened_at) do
        at when is_binary(at) ->
          SwarmCodeCLI.UI.Settings.IntegrationRows.local_stamp(at, "%Y-%m-%d %H:%M") ||
            at |> String.slice(0, 16) |> String.replace("T", " ")
        _ -> "never"
      end

    %Row{row | value: [{words, :text_muted}], state: :readonly}
  end

  defp decorate(row, _ctx, _project), do: row

  # The families under their row, each forgettable with `x` (undo puts it back).
  defp with_families(%Row{key: "project.allow"} = row, ctx) do
    items =
      ctx
      |> families()
      |> Enum.with_index()
      |> Enum.map(fn {family, n} ->
        %Row{
          id: "item:project.allow:#{n}",
          kind: :list_item,
          label: family,
          value: [],
          target: {:family, family},
          indent: 1,
          keys: [{"x", :delete, "forget"}]
        }
      end)

    [row | items]
  end

  defp with_families(row, _ctx), do: [row]

  defp forget_all(ctx) do
    case families(ctx) do
      [] ->
        []

      families ->
        [
          %Row{
            id: "act:forget_all",
            kind: :action,
            label: "Forget all…",
            value: [{"#{length(families)} always-allowed · asks first", :text_muted}],
            keys: [{"Enter", :enter, "forget them all"}]
          }
        ]
    end
  end

  defp others(ctx, project) do
    me = get(project, :id)

    others =
      for p <- projects(ctx), get(p, :id) != me, get(p, :scratch) != true do
        prefixes = get(p, :prefixes) || []

        %Row{
          id: "other:" <> to_string(get(p, :id)),
          kind: :link,
          label: get(p, :name) || "?",
          value: [
            {if(prefixes == [], do: "none yet", else: Enum.join(prefixes, ", ")),
             if(prefixes == [], do: :text_ghost, else: :text_muted)}
          ],
          tag: [{mode_words(get(p, :approval_mode)), :text_faint}],
          target: {:project, get(p, :id)},
          keys: [{"Enter", :enter, "switch to this project"}]
        }
      end

    if others == [], do: [], else: [Row.heading("other projects") | others]
  end

  defp hook_lines(ctx) do
    case project_config(ctx) do
      nil ->
        []

      fields ->
        case get(fields, :hooks) do
          hooks when is_map(hooks) ->
            for {event, list} <- Enum.sort_by(hooks, &to_string(elem(&1, 0))),
                is_list(list),
                hook <- list,
                is_binary(get(hook, :command)),
                do: "  #{event} · #{get(hook, :command)}"

          list when is_list(list) ->
            for hook <- list,
                is_binary(get(hook, :command)),
                do: "  #{get(hook, :event)} · #{get(hook, :command)}"

          _ ->
            []
        end
    end
  end

  # ---------------------------------------------------------------- facts

  @doc false
  def mode_words("read_only"), do: "read-only"
  def mode_words("auto"), do: "auto"
  def mode_words("full_access"), do: "full access"
  def mode_words(_), do: "read-only"

  defp families(ctx) do
    case current(ctx, "project.allow") do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp current(ctx, key) do
    case ctx.data |> Map.get(:values, %{}) |> Map.get(key) do
      nil -> nil
      value -> get(value, :value)
    end
  end

  defp projects(ctx) do
    case ctx.data |> Map.get(:projects) do
      %{items: items} when is_list(items) -> Enum.map(items, &fields/1)
      list when is_list(list) -> Enum.map(list, &fields/1)
      _ -> []
    end
  end

  defp fields(%{fields: fields}) when is_map(fields), do: fields
  defp fields(other), do: other

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

  defp project_name(ctx) do
    case project(ctx) do
      nil -> "this project"
      p -> get(p, :name) || "this project"
    end
  end

  defp current_project?(ctx) do
    case project(ctx) do
      nil -> false
      p -> get(p, :current) == true
    end
  end

  defp project_config(ctx) do
    with id when is_binary(id) <- project_id(ctx),
         record when not is_nil(record) <-
           ctx.data |> Map.get(:record, %{}) |> Map.get({"project_config", id}) do
      Map.get(record, :fields, record)
    else
      _ -> nil
    end
  end

  defp env_var(ctx, name) do
    case ctx.data |> Map.get(:facts) |> get(:env) do
      list when is_list(list) ->
        Enum.find_value(list, fn item ->
          if get(item, :name) == name and get(item, :set) == true, do: get(item, :value) || "set"
        end)

      _ ->
        nil
    end
  end

  defp plural(1, word), do: word
  defp plural(_, word), do: word <> "s"

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
