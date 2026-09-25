defmodule SwarmCodeCLI.UI.Settings.Sections.SessionStartup do
  @moduledoc """
  pass74 U3-10 (spec §2.17): Session & startup — what a launch opens (the
  latest conversation, a new one, or the resume picker: `ask`), whether the
  loopback visual companion starts, and two facts about this launch: the
  project folder and the flags it was started with. Flags and
  `SWARM_CONVERSATION` win over the file (a conversation id is an ignored
  layer: this launch opened one named conversation).
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :startup

  alias SwarmCodeCLI.UI.Settings.{Row, Rows}

  @impl true
  def loads(_ctx), do: []

  @impl true
  def rows(ctx) do
    ctx
    |> Rows.registry(:startup)
    |> Enum.map(fn
      %Row{key: "terminal.project_root"} = row -> fact(row, project_root(ctx), :copy)
      %Row{key: "terminal.launch_flags"} = row -> fact(row, flags(ctx), nil)
      row -> row
    end)
  end

  @impl true
  def act(ctx, %Row{key: "terminal.project_root"}, :copy) do
    case project_root(ctx) do
      nil -> :default
      path -> [{:copy, path}, {:toast, "Copied #{path}", :success}]
    end
  end

  def act(ctx, %Row{key: "terminal.project_root"}, :open_related) do
    case project_root(ctx) do
      nil -> :default
      path -> [{:open_folder, path}]
    end
  end

  def act(_ctx, _row, _verb), do: :default

  defp fact(row, nil, _key),
    do: %Row{row | value: [{"not known in this session", :text_ghost}], state: :readonly}

  defp fact(row, text, key) do
    keys =
      if key == :copy,
        do: [{"y", :copy, "copy the path"}, {"o", :open_related, "open the folder"}],
        else: []

    %Row{row | value: [{text, :text_muted}], state: :readonly, keys: keys}
  end

  @doc "The launch flags in words: `--new --model deepseek-v4-pro`, or `none`."
  @spec flag_words(map() | list() | nil) :: String.t()
  def flag_words(flags) when is_map(flags) and map_size(flags) > 0 do
    flags
    |> Enum.sort()
    |> Enum.map_join(" ", fn
      {flag, value} when value in ["", nil, true] -> to_string(flag)
      {flag, value} -> "#{flag} #{value}"
    end)
  end

  def flag_words(flags) when is_list(flags) and flags != [], do: Enum.join(flags, " ")
  def flag_words(_), do: "none"

  defp flags(ctx), do: ctx.launch_facts |> get(:flags) |> flag_words()

  defp project_root(ctx) do
    case get(ctx.launch_facts, :project_root) do
      root when is_binary(root) and root != "" -> root
      _ -> if is_binary(ctx.project) and ctx.project != "", do: ctx.project
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
