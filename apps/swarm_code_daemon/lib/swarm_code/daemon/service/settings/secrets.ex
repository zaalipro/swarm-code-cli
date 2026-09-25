defmodule SwarmCode.Daemon.Service.Settings.Secrets do
  @moduledoc """
  The one place the settings service turns a secret into something it may
  answer (pass 74 §3.5.9, D6).

  A stored secret never leaves the service: it is answered as
  `{"set": bool, "hint": "a1b2" | null}` (the last 4 characters, only for a
  secret of 12 characters or more). A new secret arrives only in the command's
  `secrets` list, once per write attempt, and is checked with `check_paste/1`
  before anything is written. MCP environment and header entries are secret by
  `SwarmCode.Settings.SecretPattern.secret_kv?/2`, a strict superset of the
  desktop's `Server.secrets/1`. Every handler calls these functions and never
  formats a secret itself.
  """

  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Domain.MCP.Server
  alias SwarmCode.Domain.Providers.Provider
  alias SwarmCode.Domain.Search.SearchProvider
  alias SwarmCode.Settings.SecretPattern

  @compile {:no_warn_undefined, [SecretPattern]}

  # `LLM.HTTP.redact/2` skips shorter values, so a shorter key could not be
  # redacted from an error message.
  @min_bytes 8
  @max_bytes 8_192

  @doc "The wire form of a stored secret: `%{\"set\" => bool, \"hint\" => String.t() | nil}`."
  @spec mask(String.t() | nil) :: %{String.t() => boolean() | String.t() | nil}
  def mask(value) when is_binary(value) do
    if String.trim(value) == "",
      do: %{"set" => false, "hint" => nil},
      else: %{"set" => true, "hint" => hint(value)}
  end

  def mask(_value), do: %{"set" => false, "hint" => nil}

  @doc """
  The last 4 characters of a secret of 12 characters or more, else nil. A
  hint that would not be 4 printable characters (a control character, a
  space) is nil: the client rejects any other shape (§3.4.6 rule 2).
  """
  @spec hint(String.t() | nil) :: String.t() | nil
  def hint(value) when is_binary(value) do
    case SecretPattern.hint(value) do
      hint when is_binary(hint) ->
        if String.length(hint) == 4 and String.printable?(hint) and not (hint =~ ~r/\s/u),
          do: hint

      _ ->
        nil
    end
  end

  def hint(_value), do: nil

  @doc """
  Checks a pasted secret (trimmed first): one line, no inner whitespace,
  8..8 192 bytes. The words are the ones the status row shows.
  """
  @spec check_paste(term()) :: :ok | {:error, String.t()}
  def check_paste(value) when is_binary(value) do
    trimmed = String.trim(value)
    lines = trimmed |> String.split(~r/\r\n|\r|\n/) |> length()

    cond do
      lines > 1 -> {:error, "paste only the key: it had #{lines} lines"}
      trimmed =~ ~r/\s/u -> {:error, "a key has no spaces inside"}
      byte_size(trimmed) < @min_bytes -> {:error, "that is too short to be a key"}
      byte_size(trimmed) > @max_bytes -> {:error, "that is too long to be a key"}
      not String.printable?(trimmed) -> {:error, "that does not look like a key"}
      true -> :ok
    end
  end

  def check_paste(_value), do: {:error, "that is too short to be a key"}

  @doc "The pasted value, trimmed, as it is stored."
  @spec normalise(String.t()) :: String.t()
  def normalise(value), do: String.trim(value)

  @doc "The secret of `slot` in the command's `secrets` list."
  @spec take(map(), String.t()) :: {:ok, String.t()} | :error
  def take(command, slot) do
    command
    |> Map.get(:secrets)
    |> List.wrap()
    |> Enum.find_value(:error, fn entry ->
      if is_map(entry) and slot_of(entry) == slot and is_binary(value_of(entry)),
        do: {:ok, value_of(entry)}
    end)
  end

  @doc """
  The pasted value of `slot`, checked (§3.5.9): `{:ok, value}` or an
  `invalid` error on the `field` row. The value is never in the error.
  """
  @spec required(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, struct()}
  def required(command, slot, field \\ "api_key") do
    case take(command, slot) do
      :error ->
        Kit.error(:invalid, "paste the key", [Kit.field_error(field, "paste the key")])

      {:ok, value} ->
        case check_paste(value) do
          :ok -> {:ok, value}
          {:error, message} -> Kit.error(:invalid, message, [Kit.field_error(field, message)])
        end
    end
  end

  @doc "The pasted value of an optional `slot`: `{:ok, nil}` when absent, else as `required/3`."
  @spec optional(map(), String.t(), String.t()) :: {:ok, String.t() | nil} | {:error, struct()}
  def optional(command, slot, field \\ "api_key") do
    case take(command, slot) do
      :error -> {:ok, nil}
      {:ok, _} -> with {:ok, value} <- required(command, slot, field), do: {:ok, normalise(value)}
    end
  end

  @doc "Every slot the command carries (never the values)."
  @spec slots(map()) :: [String.t()]
  def slots(command) do
    command
    |> Map.get(:secrets)
    |> List.wrap()
    |> Enum.map(&slot_of/1)
    |> Enum.filter(&is_binary/1)
  end

  defp slot_of(entry), do: Map.get(entry, :slot) || Map.get(entry, "slot")
  defp value_of(entry), do: Map.get(entry, :value) || Map.get(entry, "value")

  @doc "Whether an MCP environment or header entry is secret (§3.2.5)."
  @spec secret_kv?(term(), term()) :: boolean()
  def secret_kv?(name, value), do: SecretPattern.secret_kv?(to_string(name), to_string(value))

  @doc """
  An MCP `env`/`headers` map in its wire form, sorted by name:
  `[%{"name", "secret", "value" (nil when secret), "hint"}]`.
  """
  @spec masked_entries(map() | nil) :: [map()]
  def masked_entries(map) when is_map(map) do
    map
    |> Enum.map(fn {name, value} -> {to_string(name), to_string(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, value} ->
      if secret_kv?(name, value),
        do: %{"name" => name, "secret" => true, "value" => nil, "hint" => hint(value)},
        else: %{"name" => name, "secret" => false, "value" => value, "hint" => nil}
    end)
  end

  def masked_entries(_other), do: []

  @doc """
  Every stored secret of a record, for redacting messages about it: the
  provider or search key, and every MCP value either rule calls secret.
  """
  @spec redaction_list(term()) :: [String.t()]
  def redaction_list(%Provider{api_key: key}), do: present([key])
  def redaction_list(%SearchProvider{api_key: key}), do: present([key])

  def redaction_list(%Server{} = server) do
    entries = Map.to_list(server.env || %{}) ++ Map.to_list(server.headers || %{})

    present(
      Server.secrets(server) ++
        for({name, value} <- entries, secret_kv?(name, value), do: to_string(value))
    )
  end

  def redaction_list(%{} = map) do
    present([
      Map.get(map, :api_key) || Map.get(map, "api_key")
      | Enum.flat_map(["env", "headers", :env, :headers], fn key ->
          for {name, value} <- Map.get(map, key) || %{}, secret_kv?(name, value), do: value
        end)
    ])
  end

  def redaction_list(_other), do: []

  # A scheme-prefixed credential (`Bearer <token>`) is also redacted when a
  # message quotes the token alone.
  defp present(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.flat_map(fn value ->
      case Regex.run(~r/^\s*(?:bearer|basic|token)\s+(\S+)\s*$/i, value) do
        [_, token] -> [value, token]
        nil -> [value]
      end
    end)
    |> Enum.uniq()
  end
end
