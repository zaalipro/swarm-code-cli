defmodule SwarmCodeCLI.UI.Projector.Panel.Name do
  @moduledoc """
  The one name an agent goes by on screen (pass73 T10). The owner saw one
  agent called "review-angular-plan" on the approval card, "angular-plan" in
  the needs-you band and "angular" on its panel row. Now the card, the band,
  the panel's rows (full, compact and the narrow strip), the overlay and the
  transcript's agent lines all ask this module, so they say the same word:

    * the Lead is "Lead";
    * a chat turn's one agent is its role label, the name the engine gave its
      node ("Workflow author", "Planner", "Consensus"), else "Assistant";
    * any other agent is its own name without the prefix and suffix that
      three or more of its siblings share (R14); the run header says the
      shared part once (`4 × review-*`).

  Where a row has no room for it, `fit/3` cuts that same name at its end
  with `…`: never another word for the agent.
  """
  alias SwarmCodeCLI.UI.Projector.Inspector.Hive
  alias SwarmCodeCLI.UI.Projector.Panel.{Draw, Model}

  @type affixes :: {binary(), binary()}

  @doc "The name `agent` goes by, its siblings read from `state`."
  @spec of(map(), map()) :: binary()
  def of(state, %{run_id: run_id} = agent) do
    display(agent, affixes(state, run_id), Map.get(state.read_model.runs, run_id))
  end

  def of(_state, agent), do: display(agent, {"", ""}, nil)

  @doc """
  The name of the agent behind `node_id` in `run_id` (an approval names the
  op node that waits, or the agent itself), else `fallback` trimmed like its
  siblings, else nil.
  """
  @spec for_node(map(), binary() | nil, binary() | nil, binary() | nil) :: binary() | nil
  def for_node(state, run_id, node_id, fallback \\ nil) do
    agents = state.read_model.agents

    case node_id && Map.get(agents, node_id) do
      %{} = agent ->
        of(state, agent)

      _ ->
        case fallback && present(fallback) do
          nil ->
            nil

          name ->
            match =
              agents
              |> Map.values()
              |> Enum.find(&(&1.run_id == run_id and Map.get(&1, :name) == name))

            if match,
              do: of(state, match),
              else: trim(name, affixes(state, run_id))
        end
    end
  end

  @doc "The shared `{prefix, suffix}` of the run's agents other than its lead (R14)."
  @spec affixes(map(), binary() | nil) :: affixes()
  def affixes(_state, nil), do: {"", ""}

  def affixes(state, run_id) do
    state
    |> Hive.agents(run_id)
    |> Enum.reject(&lead?/1)
    |> Enum.map(&Hive.name/1)
    |> Model.affixes()
  end

  @doc "The name of `agent` given its run's `affixes` (and the run, for a chat turn's label)."
  @spec display(map(), affixes(), map() | nil) :: binary()
  def display(%{role: :lead}, _affixes, _run), do: "Lead"
  def display(%{role: :assistant} = agent, _affixes, run), do: role_label(agent, run)
  def display(agent, affixes, _run), do: trim(Hive.name(agent), affixes)

  @doc """
  A chat turn's agent by its role (spec 50 §4, the desktop's `Run.agent_name/1`):
  the engine names the node "Workflow author", "Planner", "Consensus" or
  "Assistant"; a run without a node of its own reads its title.
  """
  @spec role_label(map(), map() | nil) :: binary()
  def role_label(agent, run) do
    name = present(Map.get(agent, :name))
    title = (run && Map.get(run, :title)) || ""

    cond do
      name && String.downcase(name) != "assistant" -> name
      String.starts_with?(title, "/create-workflow") -> "Workflow author"
      true -> "Assistant"
    end
  end

  @doc "`name` without the shared prefix and suffix, never empty."
  @spec trim(binary(), affixes()) :: binary()
  def trim(name, {prefix, suffix}) do
    trimmed =
      name
      |> then(&if(prefix != "", do: String.replace_prefix(&1, prefix, ""), else: &1))
      |> then(&if(suffix != "", do: String.replace_suffix(&1, suffix, ""), else: &1))

    if trimmed == "", do: name, else: trimmed
  end

  @doc """
  `name` in at most `cells` cells: whole when it fits, else cut at its end
  with `…`, so a narrow row shows the start of the same name.
  """
  @spec fit(binary(), non_neg_integer(), map()) :: binary()
  def fit(name, cells, state) do
    if Draw.cells(name, state) <= cells, do: name, else: Draw.elide(name, max(1, cells), state)
  end

  defp lead?(%{role: role}), do: role in [:lead, :assistant]

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp present(_), do: nil
end
