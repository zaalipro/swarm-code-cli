defmodule SwarmCode.Daemon.Service.Settings.Deltas do
  @moduledoc """
  Live updates of the settings layer (pass 74, spec §3.3.9): which sections a
  domain message touches, the pending set a PersistedBackend coalesces for
  100 ms, and the `settings_update` / `settings_task` delta maps.

  `{:settings_updated, %Setting{}}` carries the whole settings row (the Tavily
  key among its columns): `sections/1` matches it without binding the struct,
  and nothing here keeps, forwards or inspects it (R19).
  """

  alias SwarmCode.Daemon.Service.Settings.Values

  @coalesce_ms 100
  # A settings command of this session completed this recently: the update is
  # the session's own (`origin: "settings"`).
  @own_window_ms 1_000

  @settings ~w(models_effort deep_research search_web agents_limits language_servers storage
               budget desktop pricing approvals)
  @providers ~w(providers models_effort pricing deep_research)

  @doc "The coalescing delay of a `settings_update` (§3.12)."
  @spec coalesce_ms() :: pos_integer()
  def coalesce_ms, do: @coalesce_ms

  @doc """
  The sections a domain message touches, `:refresh` when the workspace
  metadata must be re-projected too (R3), or `:ignore`.
  """
  @spec sections(term()) :: {[String.t()], boolean()} | :ignore
  def sections({:settings_updated, _row}), do: {@settings, true}
  def sections({:providers_changed}), do: {@providers, true}
  def sections({:search_providers_updated}), do: {["search_web"], true}
  def sections({:projects_changed}), do: {["approvals", "project_file", "overview"], true}
  def sections({:storage_done, _result}), do: {["storage"], false}
  def sections({:storage_failed, _reason}), do: {["storage"], false}
  def sections({:mcp_status, _id, _status}), do: {["mcp", "overview"], false}
  # QA F-8: a server created, changed or deleted (`MCP.broadcast/0`); a
  # deleted server stayed on an open MCP page until Ctrl-R.
  def sections({:mcp_changed}), do: {["mcp", "overview"], false}
  def sections(_message), do: :ignore

  @doc "The registry-backed conversation columns (a change of one marks models_effort)."
  @spec conversation_columns() :: [atom()]
  def conversation_columns, do: Values.conversation_columns()

  @doc "The session values of a conversation the backend compares (nil for none)."
  @spec session_values(map() | nil) :: map() | nil
  def session_values(nil), do: nil

  def session_values(%{} = conversation),
    do: Map.new(conversation_columns(), &{&1, Map.get(conversation, &1)})

  @doc """
  Whether a conversation update changed a registry-backed column: `{changed?,
  new values}` (a `mark_seen`, queue or title-less touch changes none).
  """
  @spec conversation_changed(map() | nil, map()) :: {boolean(), map()}
  def conversation_changed(before, %{} = conversation) do
    now = session_values(conversation)
    {before != nil and before != now, now}
  end

  @doc "Whether a settings command completed within the own-update window."
  @spec own?(integer() | nil, integer()) :: boolean()
  def own?(nil, _now), do: false
  def own?(at, now), do: now - at <= @own_window_ms

  @doc "The `settings_update` delta (never values)."
  @spec update_delta(non_neg_integer(), non_neg_integer(), [String.t()], String.t()) :: map()
  def update_delta(stream_revision, settings_revision, sections, origin) do
    sections =
      sections
      |> Enum.uniq()
      |> Enum.filter(&(&1 in SwarmCode.Settings.Sections.id_strings()))
      |> Enum.sort_by(&rail_index/1)
      |> Enum.take(22)

    %{
      "kind" => "settings_update",
      "entity_id" => nil,
      "run_id" => nil,
      "conversation_id" => nil,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => %{"revision" => settings_revision, "sections" => sections, "origin" => origin},
      "sequence" => 0,
      "revision" => stream_revision
    }
  end

  @doc "The `settings_task` delta of a task body (§3.4.4)."
  @spec task_delta(non_neg_integer(), map()) :: map()
  def task_delta(stream_revision, body) do
    %{
      "kind" => "settings_task",
      "entity_id" => body["task_id"],
      "run_id" => nil,
      "conversation_id" => nil,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => body,
      "sequence" => 0,
      "revision" => stream_revision
    }
  end

  defp rail_index(id) do
    Enum.find_index(SwarmCode.Settings.Sections.ids(), &(Atom.to_string(&1) == id)) || 99
  end
end
