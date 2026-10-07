defmodule SwarmCode.Domain.Workflows.RunRows do
  @moduledoc """
  Spec 74 EFFICIENCY-13: the /workflows Runs list as keyset pages of projected
  rows. `Workflows.list_runs/1` returns every run ever with its full workflow
  row (source, args, logs, result) and the page filtered the project in Elixir
  — 19 MB of assigns at 500 runs. A row here carries only what the list draws:

      %{wf: %{run_id, display_name, phase, agents_admitted, budget},
        run: %{id, status, started_at, finished_at, tokens_in, tokens_out, cost_usd},
        conversation: %{title, project_id} | nil}

  newest first (`started_at desc, run id desc`), the project filtered in SQL.
  """

  import Ecto.Query

  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Workflows.Run

  @page 50
  @active ~w(running waiting_user paused interrupted)
  @wf_fields [:run_id, :display_name, :phase, :agents_admitted, :budget]

  @doc "The page size of the Runs list."
  def page, do: @page

  @doc """
  One page of rows. `filter` is the list's filter atom (as `Workflows.list_runs/1`),
  `scope` a project id or `"all"`. Options: `:limit` (default #{@page}) and
  `:after` — the `{started_at, run_id}` of the last row already shown.
  """
  @spec list(atom(), String.t() | nil, keyword()) :: [map()]
  def list(filter, scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, @page)

    from(w in Run,
      join: r in Conversations.Run,
      on: r.id == w.run_id,
      left_join: c in Conversations.Conversation,
      on: c.id == w.conversation_id,
      order_by: [desc: r.started_at, desc: r.id],
      limit: ^limit,
      select: %{
        wf: %{
          run_id: w.run_id,
          display_name: w.display_name,
          phase: w.phase,
          agents_admitted: w.agents_admitted,
          budget: w.budget
        },
        run: %{
          id: r.id,
          status: r.status,
          started_at: r.started_at,
          finished_at: r.finished_at,
          tokens_in: r.tokens_in,
          tokens_out: r.tokens_out,
          cost_usd: r.cost_usd
        },
        conversation_id: c.id,
        conversation: %{title: c.title, project_id: c.project_id}
      }
    )
    |> filter(filter)
    |> scope(scope)
    |> after_cursor(opts[:after])
    |> Repo.all()
    |> Enum.map(fn
      %{conversation_id: nil} = row ->
        row |> Map.delete(:conversation_id) |> Map.put(:conversation, nil)

      row ->
        Map.delete(row, :conversation_id)
    end)
  end

  @doc "The cursor after `row` — pass it as `after:` for the next page."
  @spec cursor(map()) :: {DateTime.t() | nil, String.t()}
  def cursor(%{run: %{started_at: at, id: id}}), do: {at, id}

  @doc """
  An incoming `{:workflow_updated}` row, projected to the list's `wf` shape so
  the list never holds `source`, `args`, `logs` or `result`.
  """
  @spec project_wf(map()) :: map()
  def project_wf(wf), do: Map.take(wf, @wf_fields)

  defp filter(query, :all), do: query
  defp filter(query, :active), do: where(query, [w, r], r.status in ^@active)
  defp filter(query, :waiting), do: where(query, [w, r], r.status in ~w(waiting_user paused))
  defp filter(query, :interrupted), do: where(query, [w, r], r.status == "interrupted")
  defp filter(query, :done), do: where(query, [w, r], r.status == "done")
  defp filter(query, :failed), do: where(query, [w, r], r.status in ~w(failed stopped))

  defp filter(_query, other),
    do: raise(ArgumentError, "unknown workflow run filter: #{inspect(other)}")

  defp scope(query, scope) when scope in [nil, "all"], do: query
  defp scope(query, project_id), do: where(query, [w, r, c], c.project_id == ^project_id)

  defp after_cursor(query, nil), do: query

  defp after_cursor(query, {nil, id}),
    do: where(query, [w, r], is_nil(r.started_at) and r.id < ^id)

  defp after_cursor(query, {at, id}) do
    where(
      query,
      [w, r],
      r.started_at < ^at or (r.started_at == ^at and r.id < ^id) or is_nil(r.started_at)
    )
  end
end
