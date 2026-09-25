defmodule SwarmCodeCLI.UI.Settings.Sections.AgentsLimits do
  @moduledoc """
  pass74 U3-6 (spec §2.9, F9): Agents & limits. The registry's rows of the
  section in their groups (limits for every run, isolation, shell for agent
  commands; the bounds, specials and messages are the registry's, so the
  number editor refuses what the service would), then the agent definitions
  as link rows into Library (the first name wins: project › user ›
  bundled) and the link to the always-allowed commands on Approvals & trust.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :agents_limits

  alias SwarmCodeCLI.UI.Settings.{Row, Rows}

  @impl true
  def loads(_ctx), do: [{:values, [:agents_limits]}, {:records, "agent_def", %{}}]

  @impl true
  def rows(ctx) do
    Rows.registry(ctx, :agents_limits) ++ definitions(ctx) ++ [approvals_link()]
  end

  @impl true
  def act(_ctx, %Row{target: {:library, name}}, verb) when verb in [:open_row, :goto],
    do: [{:section, :library}, {:toast, "Library › agent definitions › #{name}", :text_muted}]

  def act(_ctx, %Row{target: {:section, id}}, verb) when verb in [:open_row, :goto],
    do: [{:section, id}]

  def act(_ctx, _row, _verb), do: :default

  @doc false
  def definitions(ctx) do
    case agent_records(ctx) do
      nil ->
        []

      [] ->
        [
          Row.heading("agent definitions"),
          Row.info("agents-none", "none yet · n in Library writes one from a template",
            target: {:section, :library},
            keys: [{"Enter", :enter, "open Library"}]
          )
        ]

      items ->
        [
          Row.heading("agent definitions", [
            {"project › user › bundled · the first name wins", :text_faint}
          ])
          | Enum.map(items, &definition_row/1)
        ]
    end
  end

  defp definition_row(item) do
    fields = Map.get(item, :fields, item)
    name = field(fields, :name) || "?"
    tier = field(fields, :tier) || ""

    model =
      case {field(fields, :model), field(fields, :effort)} do
        {nil, nil} -> "the sub-agent model"
        {nil, effort} -> "the sub-agent model · #{effort}"
        {model, nil} -> model
        {model, effort} -> "#{model} · #{effort}"
      end

    tag =
      cond do
        field(fields, :parse_error) ->
          [{"✗ not read", :error}]

        field(fields, :shadowed) == true ->
          [{"shadowed", :text_faint}]

        is_binary(field(fields, :shadows)) ->
          [{"shadows the #{field(fields, :shadows)} one", :text_faint}]

        true ->
          []
      end

    %Row{
      id: "agent:#{tier}:#{name}",
      kind: :link,
      label: name,
      value: [{String.pad_trailing(tier, 12), :text_muted}, {model, :text_muted}],
      tag: tag,
      target: {:library, name},
      keys: [{"Enter", :enter, "open in Library"}]
    }
  end

  defp approvals_link do
    %Row{
      id: "link:approvals",
      kind: :link,
      label: "Always-allowed commands",
      value: [{"live in Approvals & trust", :text_muted}],
      tag: [{"Enter go there", :text_faint}],
      target: {:section, :approvals},
      keys: [{"Enter", :enter, "go there"}]
    }
  end

  defp agent_records(ctx) do
    records = ctx.data |> Map.get(:records, %{})

    Enum.find_value(records, fn
      {{"agent_def", _options}, page} -> Map.get(page, :items, [])
      _ -> nil
    end)
  end

  defp field(fields, name) when is_map(fields),
    do: Map.get(fields, name, Map.get(fields, Atom.to_string(name)))
end
