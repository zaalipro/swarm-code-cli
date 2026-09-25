defmodule SwarmCode.Daemon.Service.Settings.Wire do
  @moduledoc """
  Encodes settings answers for the socket (pass 74, spec §3.4.2): the
  `settings_snapshot` value of a query and the `settings_result` value of a
  command. Everything becomes JSON-ready data (string keys, atoms as strings,
  datetimes as ISO-8601). No settings_result carries file content or a task
  result (D33); `guard/2` keeps an answer below the command ledger's bound.
  """

  alias SwarmCode.Daemon.Service.Settings.{Error, Result}

  @ledger_guard 122_880

  @doc "The ledger guard in bytes (120 KiB, below the ledger's 128 KiB raise)."
  @spec ledger_guard() :: pos_integer()
  def ledger_guard, do: @ledger_guard

  @doc "A `settings_snapshot` value."
  @spec snapshot(String.t(), map(), non_neg_integer(), String.t() | nil) :: map()
  def snapshot(view, body, revision, request_id) do
    %{
      "request_id" => request_id,
      "view" => view,
      "revision" => revision,
      "available" => true,
      "message" => nil,
      "body" => json(body)
    }
  end

  @doc "A snapshot that says settings are not available here, with the words."
  @spec unavailable_snapshot(String.t(), String.t(), non_neg_integer(), String.t() | nil) :: map()
  def unavailable_snapshot(view, message, revision, request_id) do
    %{
      "request_id" => request_id,
      "view" => view,
      "revision" => revision,
      "available" => false,
      "message" => message,
      "body" => nil
    }
  end

  @doc "A `settings_result` value from a result or an error."
  @spec result(Result.t() | Error.t(), String.t() | nil, non_neg_integer()) :: map()
  def result(%Result{} = result, request_id, revision) do
    %{
      "request_id" => request_id,
      "status" => Atom.to_string(result.status),
      "results" => Enum.map(result.results, &row/1),
      "record" => json(result.record),
      "task" => task(result.task),
      "message" => result.message,
      "confirm" => confirm(result.confirm),
      "field_errors" => Enum.map(result.field_errors, &field_error/1),
      "revision" => revision
    }
  end

  def result(%Error{} = error, request_id, revision) do
    %{
      "request_id" => request_id,
      "status" => error_status(error.code),
      "results" => [],
      "record" => nil,
      "task" => nil,
      "message" => error.message,
      "confirm" => nil,
      "field_errors" => Enum.map(error.field_errors, &field_error/1),
      "revision" => revision
    }
  end

  @doc "A bare status answer (`busy`, `unavailable`) with its words."
  @spec status(String.t(), String.t(), String.t() | nil, non_neg_integer()) :: map()
  def status(status, message, request_id, revision) do
    %{
      "request_id" => request_id,
      "status" => status,
      "results" => [],
      "record" => nil,
      "task" => nil,
      "message" => message,
      "confirm" => nil,
      "field_errors" => [],
      "revision" => revision
    }
  end

  @doc "The wire status of an error code."
  @spec error_status(Error.code()) :: String.t()
  def error_status(:invalid), do: "rejected"
  def error_status(:not_found), do: "not_found"
  def error_status(:conflict), do: "conflict"
  def error_status(:busy), do: "busy"
  def error_status(:unsupported), do: "unsupported"
  def error_status(_code), do: "unavailable"

  @doc """
  The ledger guard (D33, B1): an encoded settings_result over 120 KiB keeps
  its status and loses its rows, record and field errors.
  """
  @spec guard(map(), pos_integer()) :: map()
  def guard(value, limit \\ @ledger_guard) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= limit ->
        value

      _ ->
        %{
          value
          | "results" => [],
            "record" => nil,
            "field_errors" => [],
            "confirm" => nil,
            "message" => "The answer was too large to keep; reloading."
        }
    end
  end

  @doc "JSON-ready data: string keys, atoms as strings, datetimes as ISO-8601."
  @spec json(term()) :: term()
  def json(nil), do: nil
  def json(value) when is_boolean(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)
  def json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value) <> "Z"
  def json(%Date{} = value), do: Date.to_iso8601(value)
  def json(value) when is_struct(value), do: value |> Map.from_struct() |> json()
  def json(value) when is_map(value), do: Map.new(value, fn {k, v} -> {key(k), json(v)} end)
  def json(value) when is_list(value), do: Enum.map(value, &json/1)
  def json(value) when is_tuple(value), do: value |> Tuple.to_list() |> json()
  def json(value), do: value

  defp key(k) when is_binary(k), do: k
  defp key(k) when is_atom(k), do: Atom.to_string(k)
  defp key(k), do: to_string(k)

  defp row(row) do
    %{
      "target" => row.target,
      "status" => Atom.to_string(row.status),
      "value" => json(row.value),
      "current" => json(row.current),
      "message" => row.message
    }
  end

  defp task(nil), do: nil
  defp task(%{task_id: id, action: action}), do: %{"task_id" => id, "action" => action}

  defp confirm(nil), do: nil

  defp confirm(%{kind: kind, items: items}),
    do: %{"kind" => kind, "items" => Enum.take(items, 32)}

  defp field_error(%{target: target, message: message}),
    do: %{"target" => target, "message" => message}
end
