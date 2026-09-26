defmodule SwarmCodeCLI.UI.Settings.Data do
  @moduledoc """
  What the settings layer holds of the service's answers (spec §3.7.4), all
  bounded:

    * `values` — registry key => SettingValue (a map with `value`, `layers`,
      `winner`, `writable`, `base`, `choices`, `state`, `note`), and
      `values_loaded`, the sections whose values arrived;
    * `records` — `{kind, options}` => `%{items, next_cursor, total, loaded_at}`,
      at most 8 pages per kind, the oldest dropped;
    * `record` — `{kind, id}` => record fields, at most 16;
    * `files` — ref => file (with content), at most 3;
    * `task_views` — task id => `%{summary, pages: %{cursor => rows}}`, at most
      4 tasks of at most 5 pages;
    * `overview`, `facts`, `usage`, `projects` — the views of the same names;
    * `cli` — `%{values, status, mode, size, fingerprint, unknown, invalid}`,
      what the runtime read of cli.json.
  """

  defstruct values: %{},
            values_loaded: MapSet.new(),
            revision: 0,
            records: %{},
            record: %{},
            files: %{},
            task_views: %{},
            overview: nil,
            facts: nil,
            usage: nil,
            projects: nil,
            cli: nil,
            loaded_at: nil,
            project_id: nil,
            conversation_id: nil

  @type t :: %__MODULE__{}

  @max_record_pages_per_kind 8
  @max_records 16
  @max_files 3
  @max_task_views 4
  @max_task_pages 5

  @doc "The bounds of the client caches, for tests and the docs."
  def bounds,
    do: %{
      record_pages_per_kind: @max_record_pages_per_kind,
      records: @max_records,
      files: @max_files,
      task_views: @max_task_views,
      task_pages: @max_task_pages
    }

  @doc """
  The cli.json names the runtime's read found with a value it could not use
  (none when cli.json could not be read at all: `cli` is then
  `{:error, reason}`, or nil before the read answers).
  """
  @spec cli_invalid(t() | nil) :: [String.t()]
  def cli_invalid(%__MODULE__{cli: %{invalid: invalid}}) when is_list(invalid), do: invalid
  def cli_invalid(_data), do: []

  @doc "The SettingValue of `key`, or nil."
  @spec value(t(), String.t()) :: map() | nil
  def value(%__MODULE__{values: values}, key), do: Map.get(values, key)

  @doc "Stores a page of `kind` records, keeping at most 8 pages per kind (oldest dropped)."
  @spec put_records(t(), {String.t(), map()}, map(), integer()) :: t()
  def put_records(%__MODULE__{} = data, {kind, _options} = key, page, now) do
    records = Map.put(data.records, key, Map.put(page, :loaded_at, now))

    same_kind =
      records
      |> Enum.filter(fn {{k, _}, _} -> k == kind end)
      |> Enum.sort_by(fn {_, page} -> Map.get(page, :loaded_at, 0) end)

    drop =
      same_kind
      |> Enum.take(max(0, length(same_kind) - @max_record_pages_per_kind))
      |> Enum.map(&elem(&1, 0))

    %{data | records: Map.drop(records, drop)}
  end

  @doc """
  Adds the page at `cursor` of a list read whole (the model picker's options)
  to the page it follows; a page the list no longer ends at (it was read
  again meanwhile) is dropped.
  """
  @spec append_records(t(), {String.t(), map()}, String.t(), map()) :: t()
  def append_records(%__MODULE__{} = data, key, cursor, page) do
    case Map.get(data.records, key) do
      %{items: items, next_cursor: ^cursor} = current ->
        merged = %{
          current
          | items: items ++ (Map.get(page, :items) || []),
            next_cursor: Map.get(page, :next_cursor)
        }

        %{data | records: Map.put(data.records, key, merged)}

      _ ->
        data
    end
  end

  @doc "Stores one record, keeping at most 16 (the oldest dropped)."
  @spec put_record(t(), {String.t(), String.t()}, map(), integer()) :: t()
  def put_record(%__MODULE__{} = data, key, fields, now) do
    record = Map.put(data.record, key, %{fields: fields, loaded_at: now})
    %{data | record: keep_newest(record, @max_records)}
  end

  @doc "Stores one file with its content, keeping at most 3."
  @spec put_file(t(), String.t(), map(), integer()) :: t()
  def put_file(%__MODULE__{} = data, ref, file, now) do
    files = Map.put(data.files, ref, Map.put(file, :loaded_at, now))
    %{data | files: keep_newest(files, @max_files)}
  end

  @doc "Stores one page of a task's result rows (≤ 4 tasks × ≤ 5 pages)."
  @spec put_task_page(t(), String.t(), map() | nil, term(), [map()], integer()) :: t()
  def put_task_page(%__MODULE__{} = data, task_id, summary, cursor, rows, now) do
    view = Map.get(data.task_views, task_id, %{summary: nil, pages: %{}, loaded_at: now})

    pages =
      view.pages
      |> Map.put(cursor, rows)
      |> Enum.take(-@max_task_pages)
      |> Map.new()

    view = %{view | summary: summary || view.summary, pages: pages, loaded_at: now}
    views = data.task_views |> Map.put(task_id, view) |> keep_newest(@max_task_views)
    %{data | task_views: views}
  end

  defp keep_newest(map, bound) when map_size(map) <= bound, do: map

  defp keep_newest(map, bound) do
    map
    |> Enum.sort_by(fn {_, value} -> -Map.get(value, :loaded_at, 0) end)
    |> Enum.take(bound)
    |> Map.new()
  end
end
