defmodule SwarmCode.Domain.MCP.Server do
  @moduledoc "One configured MCP server (global, or scoped to a project)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # spec 60 T13: `inspect/1` of a server never prints its env or headers.
  @derive {Inspect, except: [:env, :headers]}
  schema "mcp_servers" do
    field(:name, :string)
    field(:transport, :string, default: "stdio")
    field(:command, :string)
    field(:args, {:array, :string}, default: [])
    field(:env, :map, default: %{})
    field(:url, :string)
    field(:headers, :map, default: %{})
    field(:enabled, :boolean, default: true)
    # spec 62 T1: the raw MCP names of this server's tools the owner switched
    # off — they stay in the Settings list, but no agent is offered them.
    field(:disabled_tools, {:array, :string}, default: [])
    field(:project_id, :binary_id)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(name transport command args env url headers enabled disabled_tools project_id)a

  def changeset(server, attrs) do
    server
    |> cast(attrs, @fields)
    |> validate_required([:name, :transport])
    |> validate_inclusion(:transport, ["stdio", "http"])
    |> validate_transport()
    |> unique_constraint(:name)
  end

  defp validate_transport(changeset) do
    case get_field(changeset, :transport) do
      "stdio" ->
        if blank?(get_field(changeset, :command)),
          do: add_error(changeset, :command, "is required for stdio servers"),
          else: changeset

      "http" ->
        url = get_field(changeset, :url)

        cond do
          blank?(url) ->
            add_error(changeset, :url, "is required for http servers")

          not String.starts_with?(url, ["http://", "https://"]) ->
            add_error(changeset, :url, "must start with http:// or https://")

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(v), do: String.trim(to_string(v)) == ""

  @doc "Splits a command line into args the way a shell would (quotes respected)."
  @spec parse_args(String.t() | [String.t()] | nil) :: [String.t()]
  def parse_args(nil), do: []
  def parse_args(list) when is_list(list), do: list

  def parse_args(text) do
    ~r/"([^"]*)"|'([^']*)'|(\S+)/
    |> Regex.scan(text)
    |> Enum.map(fn
      [_, q] -> q
      [_, _, q] -> q
      [_, _, _, w] -> w
      [w] -> w
    end)
  end

  @doc "`KEY=VALUE` lines → map."
  @spec parse_env(String.t() | map() | nil) :: map()
  def parse_env(nil), do: %{}
  def parse_env(map) when is_map(map), do: map

  def parse_env(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), "=", parts: 2) do
        [k, v] when k != "" -> [{String.trim(k), v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc "`Name: value` lines → map."
  @spec parse_headers(String.t() | map() | nil) :: map()
  def parse_headers(nil), do: %{}
  def parse_headers(map) when is_map(map), do: map

  def parse_headers(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      case String.split(String.trim(line), ":", parts: 2) do
        [k, v] when k != "" -> [{String.trim(k), String.trim(v)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  def args_text(%__MODULE__{args: args}), do: Enum.join(args || [], " ")

  def env_text(%__MODULE__{env: env}),
    do: (env || %{}) |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}=#{v}" end)

  def headers_text(%__MODULE__{headers: h}),
    do: (h || %{}) |> Enum.sort() |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{v}" end)

  # A configured value is a credential when its *key* says so, or when the value
  # itself looks like one. `content-type: application/json` is neither.
  # spec 60 T13: `cookie` is a credential name too.
  @secret_key ~r/(authorization|cookie|api[-_ ]?key|apikey|token|secret|password|credential)/i
  @secret_value ~r/^(sk-[A-Za-z0-9_\-]{4,}|Bearer\s+\S{4,})$/i

  @doc """
  The exact values of this server's headers and environment that must never
  appear in an error, a transcript or a log (spec 33 §3).
  """
  @spec secrets(%__MODULE__{} | map()) :: [String.t()]
  def secrets(server) do
    (Map.get(server, :headers) || %{})
    |> Enum.concat(Map.get(server, :env) || %{})
    |> Enum.filter(fn {key, value} -> secret?(to_string(key), to_string(value)) end)
    |> Enum.map(fn {_key, value} -> to_string(value) end)
    |> Enum.uniq()
  end

  defp secret?(key, value) do
    value != "" and (Regex.match?(@secret_key, key) or Regex.match?(@secret_value, value))
  end

  @doc "The namespace prefix of this server's tools."
  def slug(%__MODULE__{name: name}), do: slug(name)

  def slug(name) do
    name |> to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
  end
end
