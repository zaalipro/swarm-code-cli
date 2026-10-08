defmodule SwarmCodeCLI.UI.SlashArgs do
  @moduledoc """
  cli021 B3: the choices a slash command's argument takes, for the dropdown
  that opens when the draft is `/<command> ` (`SlashPalette`).

  Static ones are the command's own enumeration (`/panel full|compact|…`,
  `/diff on|off`, `/approval read-only|auto|full`, `/theme dark|light|<palette>`,
  `/mouse on|off`, `/ultra on|off`); dynamic ones come from data the client
  already holds: `default` and the levels of the model (`/effort`,
  `/worker_effort`), the
  models of the workspace snapshot (`/model`, `/worker_model`) and the
  project's conversations (`/resume`). The worker slot's old names
  (`/swarm_effort`, `/swarm_model`) are aliases of the worker commands.

  A command with free text as its argument (`/goal`, `/search`, `/consensus`,
  `/queue`, `/rename`, `/export` …) has no choices here, so no dropdown: its
  Enter and Tab are unchanged. Pure; every function takes the UI state.
  """

  alias SwarmCode.Commands
  alias SwarmCodeCLI.UI.Reducer.EffortPicker
  alias SwarmCodeCLI.UI.Theme

  @type choice :: %{
          required(:value) => binary(),
          required(:label) => binary(),
          required(:desc) => binary(),
          required(:current?) => boolean()
        }

  # The dropdown never lists more than this many models or conversations.
  @cap 100

  @doc "The canonical command name (`swarm_effort` is `worker_effort`'s old name)."
  @spec canonical(binary()) :: binary()
  def canonical(name) when is_binary(name) do
    name = String.downcase(name)
    Map.get(Commands.aliases(), name, name)
  end

  @doc """
  The choices of `name`'s argument that match the typed `typed` (what follows
  `/<name> `), best first: those whose value starts with it, then, for models
  and conversations, those that contain it. `[]` when the command has none.
  """
  @spec matching(map(), binary(), binary()) :: [choice()]
  def matching(state, name, typed) do
    needle = typed |> String.trim_leading() |> String.downcase()
    all = all(state, canonical(name))

    {prefix, rest} = Enum.split_with(all, &prefix?(&1, needle))

    contains =
      if needle != "" and canonical(name) in ~w(model worker_model resume),
        do: Enum.filter(rest, &contains?(&1, needle)),
        else: []

    Enum.take(prefix ++ contains, @cap)
  end

  defp prefix?(choice, needle) do
    String.starts_with?(String.downcase(choice.value), needle) or
      String.starts_with?(String.downcase(choice.label), needle)
  end

  defp contains?(choice, needle) do
    String.contains?(String.downcase(choice.label), needle) or
      String.contains?(String.downcase(choice.desc), needle)
  end

  # ------------------------------------------------------------- the lists

  defp all(state, "panel") do
    mode = Map.get(state, :panel_mode)
    summaries = Map.get(state, :agent_summaries?)

    [
      pick("auto", "Only when two agents work or something needs you", mode == :auto),
      pick("full", "Docked, two rows per agent", mode == :full),
      pick("compact", "Docked, one row per agent", mode == :compact),
      pick("hidden", "No side panel", mode == :hidden),
      pick("summaries on", "AI status lines under the agents", summaries == true),
      pick("summaries off", "No AI status lines", summaries == false)
    ]
  end

  defp all(state, "diff"),
    do:
      on_off(
        Map.get(state, :show_diffs),
        "Show diffs, previews and output tails under tool rows",
        "Hide them"
      )

  defp all(state, "mouse"),
    do:
      on_off(
        Map.get(state, :mouse?),
        "Wheel scrolling on",
        "Wheel off; the terminal selects text"
      )

  defp all(state, "ultra") do
    ultra? = match?(%{mode: :ultra}, workspace(state))
    [pick("on", "Big tasks run as workflows", ultra?), pick("off", "Back to Build mode", false)]
  end

  defp all(state, "theme") do
    mode = Map.get(state, :theme_mode)

    [
      pick("dark", "Dark theme", mode == :dark),
      pick("light", "Light theme", mode == :light)
    ] ++
      for palette <- Theme.palettes() do
        name = Atom.to_string(palette)
        pick(name, "The " <> name <> " palette", false)
      end
  end

  defp all(state, "approval") do
    current =
      case workspace(state) do
        %{approval_mode: :read_only} -> "read-only"
        %{approval_mode: :auto} -> "auto"
        %{approval_mode: :full_access} -> "full"
        _ -> nil
      end

    [
      pick("read-only", "Asks before every write and command", current == "read-only"),
      pick("auto", "Edits and safe commands run without asking", current == "auto"),
      pick("full", "Everything runs without asking", current == "full")
    ]
  end

  defp all(state, name) when name in ["effort", "worker_effort"] do
    target = if name == "effort", do: :chat, else: :swarm
    current = EffortPicker.current(state, target)

    # cli022 F2: `default` clears the conversation's value; it is the current
    # row while none is set and then names the level in effect (F4).
    # cli022 int: the level in effect comes from the daemon (F4); a session's
    # NCODE_EFFORT is named as such, since it is not the global default.
    default =
      case {EffortPicker.effective(state, target), EffortPicker.source(state, target)} do
        {level, :env} when is_binary(level) and is_nil(current) ->
          "Follow NCODE_EFFORT · " <> level

        {level, _} when is_binary(level) and is_nil(current) ->
          "Follow the global default · " <> level

        _ ->
          "Follow the global default"
      end

    case EffortPicker.levels(state, target) do
      [] ->
        []

      levels ->
        [pick("default", default, is_nil(current))] ++
          for level <- levels, do: pick(level, effort_words(level), level == current)
    end
  end

  defp all(state, name) when name in ["model", "worker_model"] do
    workspace = workspace(state) || %{}
    key = if name == "model", do: :chat_model, else: :swarm_model
    current = Map.get(workspace, key)

    workspace
    |> Map.get(:models, [])
    |> Enum.filter(&match?(%{provider_id: p, model: m} when is_binary(p) and is_binary(m), &1))
    |> Enum.uniq_by(&{&1.provider_id, &1.model})
    |> Enum.map(fn option ->
      %{
        value: option.provider_id <> "|" <> option.model,
        label: option.model,
        desc: option.provider,
        current?: option.model == current
      }
    end)
  end

  defp all(state, "resume") do
    case Map.get(state, :conversations) do
      %{items: items} when is_list(items) ->
        for item <- items, is_binary(item.id), item.id != "" do
          title = if item.title in [nil, ""], do: "(untitled)", else: item.title

          %{
            value: item.id,
            label: title,
            desc: item.id,
            current?: item.current
          }
        end

      _ ->
        []
    end
  end

  defp all(_state, _name), do: []

  # ---------------------------------------------------------------- pieces

  defp pick(value, desc, current?),
    do: %{value: value, label: value, desc: desc, current?: current?}

  defp on_off(current, on, off) do
    [pick("on", on, current == true), pick("off", off, current == false)]
  end

  defp effort_words("none"), do: "No reasoning"
  defp effort_words("minimal"), do: "Barely any reasoning"
  defp effort_words("low"), do: "Quick, little reasoning"
  defp effort_words("medium"), do: "Balanced"
  defp effort_words("high"), do: "Careful, more reasoning"
  defp effort_words("xhigh"), do: "Very thorough"
  defp effort_words("max"), do: "The most reasoning the model offers"
  defp effort_words(_level), do: "Reasoning effort"

  defp workspace(state), do: Map.get(state.read_model.snapshots, :workspace)
end
