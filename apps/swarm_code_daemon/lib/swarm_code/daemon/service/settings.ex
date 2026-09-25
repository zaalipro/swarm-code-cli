defmodule SwarmCode.Daemon.Service.Settings do
  @moduledoc """
  The settings service (pass 74, spec §3.3): plain functions over the domain,
  called from PersistedBackend jobs (never inside the backend's callbacks) and
  directly by `swarmcode config`. The Router picks the handler from a static
  table. Neither function raises to its caller: an exception becomes
  `unavailable` with "Couldn't read settings right now." and a log line that
  names the action or view only — never an attribute, a value or a secret.

  No code running inside a `Repo.transaction` calls the backend.
  """

  require Logger

  alias SwarmCode.Daemon.Service.Settings.{Command, Context, Error, Result, Router, TaskSpec}

  @open_limit 900_000

  @doc "Answer a settings view: `values`, `overview`, `facts`, `usage`, `open`, `records`, `record`, `file`."
  @spec query(String.t(), map(), Context.t()) :: {:ok, map()} | {:error, Error.t()}
  def query("open", params, %Context{} = ctx), do: open(params, ctx)

  def query(view, params, %Context{} = ctx) when is_binary(view) and is_map(params) do
    kind = params["kind"]

    case Router.view(view, kind) do
      {:ok, :backend} ->
        {:error, Error.unsupported()}

      {:ok, module} ->
        guarded(Router.view_key({view, kind}), fn -> module.query(view, kind, params, ctx) end)

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Run a settings command: a result, a task to start with its immediate result, or an error."
  @spec command(Command.t(), Context.t()) ::
          {:ok, Result.t()} | {:task, TaskSpec.t(), Result.t()} | {:error, Error.t()}
  def command(%Command{action: action} = command, %Context{} = ctx) do
    case Router.action(action) do
      {:ok, :backend} -> {:error, Error.unsupported()}
      {:ok, module} -> guarded(action, fn -> module.command(command, ctx) end)
      {:error, error} -> {:error, error}
    end
  end

  # The `open` view (M7): what opening the settings layer needs, in one job.
  defp open(params, ctx) do
    with {:ok, values} <-
           query("values", Map.merge(params, %{"sections" => nil, "keys" => nil}), ctx) do
      overview = optional("overview", %{}, ctx, %{"attention" => [], "glance" => %{}})
      facts = optional("facts", %{}, ctx, %{})

      projects =
        optional(
          "records",
          %{"kind" => "projects", "page_size" => 200},
          ctx,
          %{"kind" => "projects", "items" => [], "next_cursor" => nil, "total" => 0}
        )

      body = %{
        "values" => values,
        "overview" => overview,
        "facts" => facts,
        "projects" => projects
      }

      if encoded_size(body) <= @open_limit,
        do: {:ok, body},
        else: {:ok, %{"values" => values, "overview" => nil, "facts" => nil, "projects" => nil}}
    end
  end

  defp optional(view, params, ctx, fallback) do
    case query(view, params, ctx) do
      {:ok, body} -> body
      {:error, _} -> fallback
    end
  end

  defp encoded_size(body) do
    case Jason.encode(SwarmCode.Daemon.Service.Settings.Wire.json(body)) do
      {:ok, json} -> byte_size(json)
      {:error, _} -> @open_limit + 1
    end
  end

  @doc false
  # Run handler code; an exception or a malformed answer is `unavailable`,
  # logged with the action or view name only.
  @spec guarded(String.t(), (-> term())) :: term()
  def guarded(name, fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:task, %TaskSpec{}, %Result{}} = task -> task
      {:error, %Error{}} = error -> error
      _other -> failed(name)
    end
  rescue
    _exception -> failed(name)
  catch
    :exit, _reason -> failed(name)
  end

  defp failed(name) do
    Logger.warning("settings request failed: #{safe_name(name)}")
    {:error, Error.unavailable()}
  end

  defp safe_name(name) when is_binary(name) and byte_size(name) <= 64, do: name
  defp safe_name(_name), do: "(unnamed)"
end
