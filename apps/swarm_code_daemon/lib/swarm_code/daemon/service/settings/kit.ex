defmodule SwarmCode.Daemon.Service.Settings.Kit do
  @moduledoc """
  What every integration handler of the settings service shares (pass 74
  §3.5): the frame's result, error and task shapes, paging, compare-and-set of
  wire values, changeset errors as field errors, redaction of messages and
  reads of the task-cache entries the backend copied into the context.

  Nothing here does IO; the handlers call the domain.
  """

  alias SwarmCode.Daemon.Service.Settings.{Error, Result, TaskSpec}
  alias SwarmCode.Domain.LLM.HTTP

  @compile {:no_warn_undefined, [Error, Result, TaskSpec]}

  @page_size 200
  @message_bytes 2_048

  ## ------------------------------------------------------------ frame shapes

  @doc "A `%Result{}` with `status` and the given fields."
  @spec result(atom(), keyword()) :: struct()
  def result(status, fields \\ []), do: struct(Result, Keyword.put(fields, :status, status))

  @doc "`{:ok, %Result{status: :accepted}}`."
  @spec ok(keyword()) :: {:ok, struct()}
  def ok(fields \\ []), do: {:ok, result(:accepted, fields)}

  @doc "`{:ok, %Result{status: status}}`."
  @spec ok(atom(), keyword()) :: {:ok, struct()}
  def ok(status, fields), do: {:ok, result(status, fields)}

  @doc "`{:error, %Error{}}`; `field_errors` are `%{target, message}` maps (≤ 64)."
  @spec error(atom(), String.t(), [map()]) :: {:error, struct()}
  def error(code, message, field_errors \\ []) do
    {:error,
     struct(Error,
       code: code,
       message: cut(message),
       field_errors: Enum.take(field_errors, 64)
     )}
  end

  @doc "The `expected[key]` of a command (present, possibly null), or an `invalid` error."
  @spec expected(map(), String.t()) :: {:ok, term()} | {:error, struct()}
  def expected(command, key) do
    expected = cmd(command, :expected)

    if has?(expected, key),
      do: {:ok, get(expected, key)},
      else: error(:invalid, "expected is missing for #{key}")
  end

  @doc "The busy answer of a write that could not get the database."
  @spec busy() :: {:error, struct()}
  def busy, do: error(:busy, "Settings is busy; try again in a moment.")

  @doc "The answer of a part of settings this build does not have."
  @spec unsupported() :: {:error, struct()}
  def unsupported,
    do: error(:unsupported, "This part of settings is not available in this build.")

  @doc "A field error row."
  @spec field_error(String.t(), String.t()) :: map()
  def field_error(target, message), do: %{target: to_string(target), message: message}

  @doc "`{:task, %TaskSpec{}, %Result{status: :accepted}}` (§3.3.8 rule 1)."
  @spec task(keyword(), keyword()) :: {:task, struct(), struct()}
  def task(spec, result_fields \\ []),
    do: {:task, struct(TaskSpec, spec), result(:accepted, result_fields)}

  @doc "A `results[]` row of a `%Result{}`."
  @spec row(String.t(), atom(), keyword()) :: map()
  def row(target, status, opts \\ []) do
    %{
      target: to_string(target),
      status: status,
      value: Keyword.get(opts, :value),
      current: Keyword.get(opts, :current),
      message: Keyword.get(opts, :message)
    }
  end

  @doc "A conflict answer: `current` is what the service read, fresh."
  @spec conflict(String.t(), term(), keyword()) :: {:ok, struct()}
  def conflict(target, current, fields \\ []) do
    ok(
      :conflict,
      [
        results: [row(target, :conflict, current: current)],
        message: Keyword.get(fields, :message, "That changed while you edited it.")
      ] ++ Keyword.delete(fields, :message)
    )
  end

  ## ------------------------------------------------------------ inputs

  @doc "A value of a wire map, by string key (atom keys are read too)."
  @spec get(map() | nil, String.t(), term()) :: term()
  def get(map, key, default \\ nil)
  def get(nil, _key, default), do: default

  def get(map, key, default) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, default, fn
          {k, v} when is_atom(k) -> if Atom.to_string(k) == key, do: v
          _ -> nil
        end)
    end
  end

  def get(_other, _key, default), do: default

  @doc "True when the wire map has `key` (string or atom)."
  @spec has?(map() | nil, String.t()) :: boolean()
  def has?(map, key) when is_map(map) do
    Map.has_key?(map, key) or
      Enum.any?(map, fn
        {k, _} when is_atom(k) -> Atom.to_string(k) == key
        _ -> false
      end)
  end

  def has?(_map, _key), do: false

  @doc "The command's field (`:target`, `:attributes`, `:expected`) as a map."
  @spec cmd(map(), atom()) :: map()
  def cmd(command, field), do: Map.get(command, field) || %{}

  @doc "A context field (`:project`, `:conversation`, `:task_results`, `:now`, `:env`)."
  @spec ctx(map(), atom()) :: term()
  def ctx(context, :task_results), do: Map.get(context, :task_results) || %{}
  def ctx(context, :env), do: Map.get(context, :env) || %{}
  def ctx(context, :now), do: Map.get(context, :now) || DateTime.utc_now()
  def ctx(context, field), do: Map.get(context, field)

  @doc "A string attribute, trimmed; nil when absent or not a string."
  @spec string(map(), String.t()) :: String.t() | nil
  def string(map, key) do
    case get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  ## ------------------------------------------------------------ paging

  @doc """
  One page of `items` for `params` (`cursor` is an offset string, `page_size`
  1..200): `{page, next_cursor, total}`.
  """
  @spec page([term()], map()) :: {[term()], String.t() | nil, non_neg_integer()}
  def page(items, params) do
    total = length(items)
    size = page_size(params)
    offset = cursor(params)
    page = items |> Enum.drop(offset) |> Enum.take(size)
    next = if offset + size < total, do: Integer.to_string(offset + size)
    {page, next, total}
  end

  @doc "A `records` view body (§3.4.2)."
  @spec records_body(String.t(), [map()], map()) :: map()
  def records_body(kind, items, params) do
    {page, next, total} = page(items, params)
    %{"kind" => kind, "items" => page, "next_cursor" => next, "total" => total}
  end

  @doc "One record (`record` view body, and the items of a `records` page)."
  @spec record(String.t(), String.t() | nil, map()) :: map()
  def record(kind, id, fields), do: %{"kind" => kind, "id" => id, "fields" => fields}

  @doc "The `options` map of the query params."
  @spec options(map()) :: map()
  def options(params), do: get(params, "options") || %{}

  defp page_size(params) do
    case get(params, "page_size") do
      n when is_integer(n) and n >= 1 and n <= @page_size -> n
      _ -> @page_size
    end
  end

  defp cursor(params) do
    with value when is_binary(value) <- get(params, "cursor"),
         {offset, ""} when offset >= 0 <- Integer.parse(value) do
      offset
    else
      _ -> 0
    end
  end

  ## ------------------------------------------------------------ CAS

  @doc "The JSON-stable form of a wire value (atom keys and datetimes become strings)."
  @spec canonical(term()) :: term()
  def canonical(value) do
    case Jason.encode(value) do
      {:ok, json} -> Jason.decode!(json)
      {:error, _} -> value
    end
  end

  @doc "Whether `expected` still holds against `current` (`{\"$any\": true}` always does)."
  @spec same?(term(), term()) :: boolean()
  def same?(%{"$any" => true}, _current), do: true
  def same?(%{:"$any" => true}, _current), do: true
  def same?(expected, current), do: canonical(expected) == canonical(current)

  @doc """
  Compares every `expected["fields"]` entry with `fresh` (a wire-field map).
  `:ok`, or `{:conflict, [field]}` for the fields that moved.
  """
  @spec check_fields(map() | nil, map()) :: :ok | {:conflict, [String.t()]}
  def check_fields(expected, fresh) do
    fields = get(expected, "fields") || %{}

    moved =
      for {field, value} <- fields, not same?(value, get(fresh, to_string(field))) do
        to_string(field)
      end

    if moved == [], do: :ok, else: {:conflict, moved}
  end

  ## ------------------------------------------------------------ changesets

  @doc "A changeset's errors as field error rows, field order as Ecto gives them."
  @spec changeset_errors(Ecto.Changeset.t(), (atom() -> String.t())) :: [map()]
  def changeset_errors(%Ecto.Changeset{} = changeset, target \\ &Atom.to_string/1) do
    changeset
    |> Ecto.Changeset.traverse_errors(&interpolate/1)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(List.wrap(messages), &field_error(target.(field), flatten(&1)))
    end)
  end

  @doc "An `invalid` error from a changeset: `Couldn't save: <field> <message>`."
  @spec changeset_error(Ecto.Changeset.t(), (atom() -> String.t())) :: {:error, struct()}
  def changeset_error(changeset, target \\ &Atom.to_string/1) do
    errors = changeset_errors(changeset, target)

    message =
      case errors do
        [%{target: t, message: m} | _] -> "Couldn't save: #{t} #{m}"
        [] -> "Couldn't save that."
      end

    error(:invalid, message, errors)
  end

  defp interpolate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn whole, key ->
      opts |> Keyword.get(String.to_existing_atom(key), whole) |> to_string()
    end)
  rescue
    ArgumentError -> message
  end

  defp flatten(message) when is_binary(message), do: message
  defp flatten(%{} = nested), do: nested |> Map.values() |> List.flatten() |> hd() |> flatten()
  defp flatten(other), do: to_string(other)

  ## ------------------------------------------------------------ redaction

  @doc """
  A message safe to show (§3.3.8 rule 6): `LLM.HTTP.redact/2` with the known
  secrets, then exact removal of secrets under 8 bytes (which `redact/2`
  skips), cut to 2 048 bytes.
  """
  @spec redact(term(), [String.t() | nil]) :: String.t()
  def redact(text, secrets) do
    secrets = secrets |> Enum.filter(&is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))

    secrets
    |> Enum.filter(&(byte_size(&1) < 8))
    |> Enum.reduce(HTTP.redact(text, secrets), &String.replace(&2, &1, "[REDACTED]"))
    |> cut()
  end

  @doc "Cut to 2 048 bytes on a character boundary."
  @spec cut(term()) :: String.t()
  def cut(text) do
    text = to_string(text)

    if byte_size(text) <= @message_bytes,
      do: text,
      else: text |> binary_part(0, @message_bytes) |> valid_prefix()
  end

  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end

  ## ------------------------------------------------------------ task cache

  @doc """
  The task-cache entries of `action` the backend copied into the context
  (§3.3.2), newest first. Each is normalised to
  `%{task_id, key, state, at, summary, result, message}`.
  """
  @spec task_entries(map(), String.t()) :: [map()]
  def task_entries(context, action) do
    context
    |> ctx(:task_results)
    |> Enum.flat_map(fn
      {{^action, key}, entry} when is_map(entry) -> [normalise_entry(key, entry)]
      _ -> []
    end)
    |> Enum.sort_by(&sort_at/1, :desc)
  end

  @doc "The entry of `action` for `key` (the task key, or a task id)."
  @spec task_entry(map(), String.t(), term()) :: map() | nil
  def task_entry(context, action, key) do
    Enum.find(task_entries(context, action), fn entry ->
      entry.key == key or entry.task_id == key or key_names?(entry.key, key)
    end)
  end

  defp key_names?(%{} = entry_key, key), do: key in Map.values(entry_key)
  defp key_names?({_, inner}, key), do: inner == key
  defp key_names?(_entry_key, _key), do: false

  defp normalise_entry(key, entry) do
    %{
      key: key,
      task_id: get(entry, "task_id"),
      state: entry |> get("state") |> to_state(),
      at: get(entry, "at"),
      summary: get(entry, "summary") || %{},
      result: get(entry, "result"),
      message: get(entry, "message")
    }
  end

  defp to_state(state) when is_atom(state) and not is_nil(state), do: Atom.to_string(state)
  defp to_state(state), do: state

  defp sort_at(%{at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)

  defp sort_at(%{at: at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp sort_at(_entry), do: 0

  @doc """
  A `last_test`/`last_fetch` summary (§2.23): `{state, at, count, ms, message}`
  or nil when this session never ran it.
  """
  @spec last_run(map() | nil) :: map() | nil
  def last_run(nil), do: nil

  def last_run(entry) do
    summary = entry.summary || %{}

    %{
      "state" => entry.state,
      "at" => iso(entry.at),
      "count" => get(summary, "count") || get(summary, "listed"),
      "ms" => get(summary, "ms"),
      "message" => entry.message
    }
  end

  ## ------------------------------------------------------------ small words

  @doc "An ISO-8601 string, or nil."
  @spec iso(term()) :: String.t() | nil
  def iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  def iso(%NaiveDateTime{} = at), do: NaiveDateTime.to_iso8601(at) <> "Z"
  def iso(at) when is_binary(at), do: at
  def iso(_), do: nil

  @doc "A path with the user's home written `~`."
  @spec tilde(String.t() | nil) :: String.t() | nil
  def tilde(nil), do: nil

  def tilde(path) do
    home = System.user_home() || ""

    cond do
      home == "" -> path
      path == home -> "~"
      String.starts_with?(path, home <> "/") -> "~" <> String.replace_prefix(path, home, "")
      true -> path
    end
  end

  @doc "Bytes in words: `512 B`, `12 KB`, `1.8 GB`."
  @spec bytes(integer() | nil) :: String.t()
  def bytes(nil), do: "0 B"
  def bytes(n) when n < 1_000, do: "#{n} B"
  def bytes(n) when n < 1_000_000, do: "#{round(n / 1_000)} KB"
  def bytes(n) when n < 1_000_000_000, do: "#{Float.round(n / 1_000_000, 1)} MB"
  def bytes(n), do: "#{Float.round(n / 1_000_000_000, 1)} GB"

  @doc "A monotonic stopwatch in ms."
  @spec since(integer()) :: non_neg_integer()
  def since(started), do: System.monotonic_time(:millisecond) - started
end
