defmodule SwarmCode.Domain.Search.SearchProvider do
  @moduledoc "One configured web-search or page-reader endpoint (spec 24 §2.2)."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(tavily exa brave serper firecrawl jina)
  # Everything but Jina, which has a keyless public endpoint.
  @needs_key ~w(tavily exa brave serper firecrawl)

  def kinds, do: @kinds
  def needs_key?(kind), do: kind in @needs_key

  # spec 60 T13: `inspect/1` of a row never prints its key.
  @derive {Inspect, except: [:api_key]}
  schema "search_providers" do
    field(:kind, :string)
    field(:api_key, :string, default: "")
    field(:base_url, :string)
    field(:enabled, :boolean, default: false)
    field(:position, :integer, default: 0)

    timestamps(type: :utc_datetime_usec)
  end

  @fields ~w(kind api_key base_url enabled position)a

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, @fields)
    |> update_change(:base_url, &clean_url/1)
    |> update_change(:api_key, &String.trim/1)
    |> validate_required([:kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_key()
    |> unique_constraint(:kind)
  end

  defp validate_key(changeset) do
    kind = get_field(changeset, :kind)
    enabled = get_field(changeset, :enabled)
    key = get_field(changeset, :api_key) || ""

    if enabled and needs_key?(kind) and String.trim(key) == "",
      do: add_error(changeset, :api_key, "is needed to enable #{kind}"),
      else: changeset
  end

  defp clean_url(nil), do: nil

  defp clean_url(url) do
    case url |> String.trim() |> String.trim_trailing("/") do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
