defmodule SwarmCode.Daemon.Service.Settings.Projects do
  @moduledoc """
  The `records:projects` view (pass 74, spec §3.3.6): every project, the scratch
  one only when it is the session's, newest opened first, as `project` records
  (`id, name, root, approval_mode, trusted, trusted_at, prefixes, scratch,
  last_opened_at, current`).
  """
  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Daemon.Service.Settings.{Context, Error, Wire}
  alias SwarmCode.Domain.Projects.Project
  alias SwarmCode.Domain.Repo

  @page 200

  @impl true
  def actions, do: []

  @impl true
  def command(_command, _ctx), do: {:error, Error.unsupported()}

  @impl true
  def views, do: [{"records", "projects"}]

  @impl true
  def query("records", "projects", params, %Context{} = ctx) do
    current = ctx.project && ctx.project.id
    size = min(params["page_size"] || @page, @page)
    offset = offset(params["cursor"])

    query =
      from(p in Project,
        where: p.scratch == false or p.id == ^(current || ""),
        order_by: [desc_nulls_last: p.last_opened_at, asc: p.name]
      )

    total = Repo.aggregate(query, :count)
    projects = Repo.all(from(p in query, offset: ^offset, limit: ^size))
    next = if offset + size < total, do: Integer.to_string(offset + size)

    {:ok,
     %{
       "kind" => "projects",
       "items" => Enum.map(projects, &record(&1, current)),
       "next_cursor" => next,
       "total" => total
     }}
  end

  def query(_view, _kind, _params, _ctx), do: {:error, Error.unsupported()}

  @doc "A project as a `project` record."
  @spec record(Project.t(), String.t() | nil) :: map()
  def record(%Project{} = p, current) do
    %{
      "kind" => "project",
      "id" => p.id,
      "fields" =>
        Wire.json(%{
          "id" => p.id,
          "name" => p.name,
          "root" => p.root_path,
          "approval_mode" => p.approval_mode,
          "trusted" => p.trusted_at != nil,
          "trusted_at" => p.trusted_at,
          "prefixes" => p.auto_approve_prefixes || [],
          "scratch" => p.scratch,
          "last_opened_at" => p.last_opened_at,
          "current" => p.id == current
        })
    }
  end

  defp offset(nil), do: 0

  defp offset(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp offset(_cursor), do: 0
end
