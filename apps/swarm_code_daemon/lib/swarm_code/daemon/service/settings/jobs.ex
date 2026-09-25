defmodule SwarmCode.Daemon.Service.Settings.Jobs do
  @moduledoc """
  The settings half of a PersistedBackend (pass 74, spec §3.3.10): the work a
  settings job runs (never inside the backend's callbacks) and the pure pieces
  the backend needs around it — the query job key, the command fingerprint
  with secrets masked, and the wire answers.

  A job builds its `Context` itself: it reads the session's project and
  conversation, the session override and the §2.25 list-B environment names;
  the backend hands it only ids, the declared task-cache entries (§3.3.2), its
  cache-hygiene marks and the settings revision.
  """

  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Daemon.Service.Settings.{Command, Context, Error, Result, Router, Values, Wire}
  alias SwarmCode.Domain.{Conversations, Projects}

  @pool 4

  @doc "At most this many settings jobs run per session (beside the other jobs)."
  @spec pool() :: pos_integer()
  def pool, do: @pool

  @doc "The words of a settings command refused because the pool is full."
  @spec busy_words() :: String.t()
  def busy_words, do: "Settings is busy; try again in a moment."

  @doc "The words of a command job that ended without an answer."
  @spec unknown_words() :: String.t()
  def unknown_words, do: "Couldn't tell whether that was saved; reloading."

  @doc """
  The key of a query job: a newer request replaces an older one only when
  view, kind, id, project and `options.slot` are all the same.
  """
  @spec query_key(map()) :: tuple()
  def query_key(params) do
    slot =
      case params["options"] do
        %{"slot" => slot} -> slot
        _ -> nil
      end

    {:settings_query, params["view"], params["kind"], params["id"], params["project_id"], slot}
  end

  @doc """
  The fingerprint of a command (request-id conflict detection): every secret
  value is replaced by `"[secret]"` first.
  """
  @spec fingerprint(map(), map()) :: String.t()
  def fingerprint(scope, params) do
    masked =
      Map.update(params, "secrets", [], fn secrets ->
        for secret <- secrets || [], do: Map.put(secret, "value", "[secret]")
      end)

    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({%{kind: scope.kind, id: scope.id}, :settings_command, masked})
    )
    |> Base.encode16(case: :lower)
  end

  @doc "Whether a command carries pasted secrets (then it is neither durable nor remembered)."
  @spec secrets?(map()) :: boolean()
  def secrets?(params), do: params["secrets"] not in [nil, []]

  @doc "The task-cache declarations of a query or a command."
  @spec declarations(:query | :command, map()) :: list()
  def declarations(:query, params) do
    key = if params["kind"], do: params["view"] <> ":" <> params["kind"], else: params["view"]
    Router.cache_reads(key)
  end

  def declarations(:command, params), do: Router.cache_reads(params["action"] || "")

  ## ---------------------------------------------------------------- job work

  @doc """
  A query job: `{answer, marks}` where marks are the cache-hygiene marks read
  by a values or open view (nil otherwise).
  """
  @spec query(map(), map()) :: {{:ok, map()} | {:error, Error.t()}, map() | nil}
  def query(params, inputs) do
    ctx = context(inputs)
    view = params["view"]

    marks =
      if view in ["values", "open"],
        do: Settings.guarded("hygiene", fn -> {:ok, Values.hygiene(ctx)} end),
        else: nil

    marks =
      case marks do
        {:ok, marks} -> marks
        _ -> nil
      end

    {Settings.query(view, params, ctx), marks}
  end

  @doc "A command job: the handler's answer."
  @spec command(map(), String.t(), map()) ::
          {:ok, Result.t()} | {:task, struct(), Result.t()} | {:error, Error.t()}
  def command(params, request_id, inputs) do
    Settings.command(
      Command.from_params(params, request_id),
      context(Map.put(inputs, :request_id, request_id))
    )
  end

  @doc "The context of a job from the backend's inputs."
  @spec context(map()) :: Context.t()
  def context(inputs) do
    project = inputs[:project_id] && Projects.get(inputs.project_id)
    conversation = inputs[:conversation_id] && Conversations.get(inputs.conversation_id)

    Context.new(
      project: project,
      conversation: conversation,
      override: SessionConfiguration.override(),
      task_results: inputs[:task_results] || %{},
      sessions_store: inputs[:sessions_store],
      seen: inputs[:seen] || %Context{}.seen,
      settings_revision: inputs[:revision] || 0,
      request_id: inputs[:request_id]
    )
  end

  ## ----------------------------------------------------------------- answers

  @doc "The `result` reply of a query answer."
  @spec snapshot_reply(
          String.t(),
          {:ok, map()} | {:error, Error.t()},
          non_neg_integer(),
          String.t()
        ) ::
          {:ok, map()}
  def snapshot_reply(view, {:ok, body}, revision, request_id),
    do: reply("settings_snapshot", Wire.snapshot(view, body, revision, request_id))

  def snapshot_reply(view, {:error, %Error{message: message}}, revision, request_id),
    do: reply("settings_snapshot", Wire.unavailable_snapshot(view, message, revision, request_id))

  @doc "The `result` reply of a settings_result value (kept below the ledger guard)."
  @spec result_reply(map()) :: {:ok, map()}
  def result_reply(value), do: reply("settings_result", Wire.guard(value))

  @doc "The reply of a command job that ended without an answer (M1)."
  @spec unknown_reply(String.t(), non_neg_integer()) :: {:ok, map()}
  def unknown_reply(request_id, revision),
    do: result_reply(Wire.status("unavailable", unknown_words(), request_id, revision))

  @doc "The reply of a command refused because the pool is full."
  @spec busy_reply(String.t(), non_neg_integer()) :: {:ok, map()}
  def busy_reply(request_id, revision),
    do: result_reply(Wire.status("busy", busy_words(), request_id, revision))

  defp reply(kind, value),
    do: {:ok, %{"op" => "result", "response_kind" => kind, "value" => value}}
end
