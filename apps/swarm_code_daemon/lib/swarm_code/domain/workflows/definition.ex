defmodule SwarmCode.Domain.Workflows.Definition do
  @moduledoc """
  A parsed workflow definition: the `meta` map of the first expression, the raw
  source, the quoted program and the problems `parse/3` found (spec 09 §2).
  """

  @type t :: %__MODULE__{
          name: String.t(),
          scope: String.t(),
          project_id: String.t() | nil,
          path: String.t() | nil,
          source: String.t(),
          meta: map(),
          ast: Macro.t() | nil,
          problems: [String.t()]
        }

  defstruct name: nil,
            scope: "adhoc",
            # spec 64 §Data: which project a `project`-scope definition came
            # from, so `All projects` can group the Library by project.
            project_id: nil,
            path: nil,
            source: "",
            meta: %{},
            ast: nil,
            problems: []

  @doc """
  The declared phases as `[%{title, detail}]` — `meta.phases` may hold plain
  strings or `%{title: …, detail: …}` maps (spec 11 §R.1).
  """
  @spec phases(t() | map()) :: [%{title: String.t(), detail: String.t() | nil}]
  def phases(%__MODULE__{meta: meta}), do: phases(meta)

  def phases(meta) when is_map(meta) do
    (Map.get(meta, :phases) || [])
    |> Enum.map(&phase/1)
    |> Enum.reject(&(&1.title == ""))
  end

  def phases(_meta), do: []

  defp phase(%{} = map) do
    %{
      title: to_string(Map.get(map, :title) || Map.get(map, "title") || ""),
      detail: blank_to_nil(Map.get(map, :detail) || Map.get(map, "detail"))
    }
  end

  defp phase(other), do: %{title: to_string(other), detail: nil}

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(text) do
    text = to_string(text)
    if String.trim(text) == "", do: nil, else: String.slice(text, 0, 500)
  end

  @doc "Just the phase titles, in order."
  @spec phase_titles(t() | map()) :: [String.t()]
  def phase_titles(definition_or_meta), do: definition_or_meta |> phases() |> Enum.map(& &1.title)

  @doc "`%{title => detail}` for the phases that carry one."
  @spec phase_details(t() | map()) :: %{String.t() => String.t()}
  def phase_details(definition_or_meta) do
    for %{title: title, detail: detail} <- phases(definition_or_meta),
        is_binary(detail),
        into: %{},
        do: {title, detail}
  end

  @doc "When the assistant should reach for this workflow (spec 11 §R.1)."
  @spec when_to_use(t() | map()) :: String.t() | nil
  def when_to_use(%__MODULE__{meta: meta}), do: when_to_use(meta)
  def when_to_use(meta) when is_map(meta), do: blank_to_nil(Map.get(meta, :when_to_use))
  def when_to_use(_meta), do: nil

  @doc "`meta.args` in declaration order as `[{key, spec}]`."
  @spec arg_specs(t()) :: [{atom(), map()}]
  def arg_specs(%__MODULE__{meta: meta}), do: arg_specs(meta)

  def arg_specs(meta) when is_map(meta) do
    case Map.get(meta, :args) do
      args when is_map(args) -> Map.get(meta, :__arg_order__, Enum.sort(Map.keys(args)))
      _ -> []
    end
    |> Enum.map(fn key -> {key, get_in(meta, [:args, key]) || %{}} end)
  end

  @doc "The palette hint for a definition: `key=<type> …`."
  @spec args_hint(t()) :: String.t()
  def args_hint(%__MODULE__{} = definition) do
    definition
    |> arg_specs()
    |> Enum.map_join(" ", fn {key, spec} -> "#{key}=<#{spec[:type] || :string}>" end)
  end
end
