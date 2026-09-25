defmodule SwarmCodeCLI.UI.Keymap.Overrides do
  @moduledoc """
  The user's key overrides from cli.json's `keys` (spec §3.9.3), read by the
  resolver and by every surface that prints a key.

  This is the pass-through version U1 publishes with the settings layer: it
  compiles to an empty override set, so the defaults answer everywhere. U3
  replaces the bodies (binding ids looked up through a compile-time map, never
  `String.to_atom/1`; `[]` unbinds; fixed bindings refused); the API does not
  change.
  """

  alias SwarmCodeCLI.UI.Keymap.{Binding, Bindings, KeyName}

  defstruct table: %{}, removed: MapSet.new(), by_id: %{}, errors: []

  @type key :: {term(), [atom()]}
  @type t :: %__MODULE__{
          table: %{{atom(), key()} => Binding.t()},
          removed: MapSet.t(),
          by_id: %{atom() => [key()]},
          errors: [{String.t(), String.t()}]
        }

  @doc "The overrides of a cli.json `keys` map (`binding id => [key names]`)."
  @spec compile(%{String.t() => [String.t()]} | nil) :: t()
  def compile(_keys), do: %__MODULE__{}

  @doc """
  What `code`/`mods` means in `context` under the overrides: a binding,
  `:unbound` (the user removed it there) or `:default` (the table answers).
  """
  @spec lookup(t() | nil, atom(), term(), [atom()]) :: Binding.t() | :default | :unbound
  def lookup(nil, _context, _code, _mods), do: :default

  def lookup(%__MODULE__{} = overrides, context, code, mods) do
    cond do
      Map.has_key?(overrides.table, {context, {code, mods}}) ->
        Map.fetch!(overrides.table, {context, {code, mods}})

      MapSet.member?(overrides.removed, {context, {code, mods}}) ->
        :unbound

      true ->
        :default
    end
  end

  @doc "The keys the user gave `binding_id` (`[]` when unbound), or `:default`."
  @spec keys_for(t() | nil, atom()) :: [key()] | :default
  def keys_for(nil, _id), do: :default
  def keys_for(%__MODULE__{by_id: by_id}, id), do: Map.get(by_id, id, :default)

  @doc "Whether `keys` may be given to the binding `binding_id` (a string from cli.json)."
  @spec check(t() | nil, String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def check(_overrides, _binding_id, _keys), do: :ok

  @doc """
  Every binding `key_name` reaches, with the contexts it reaches it in: the
  Key bindings page's reverse lookup (`/ctrl-j`).
  """
  @spec bindings_for_key(t() | nil, String.t()) :: [{Binding.t(), [atom()]}]
  def bindings_for_key(overrides, key_name) do
    case KeyName.parse(key_name) do
      {:ok, {code, mods}} ->
        Bindings.contexts()
        |> Enum.flat_map(fn context ->
          case Bindings.lookup(context, code, mods, overrides) do
            nil -> []
            binding -> [{binding, context}]
          end
        end)
        |> Enum.group_by(fn {binding, _} -> binding.id end)
        |> Enum.map(fn {_id, [{binding, _} | _] = pairs} ->
          {binding, Enum.map(pairs, &elem(&1, 1))}
        end)
        |> Enum.sort_by(fn {binding, _} ->
          Enum.find_index(Bindings.all(), &(&1.id == binding.id))
        end)

      {:error, _} ->
        []
    end
  end
end
