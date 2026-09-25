defmodule SwarmCodeCLI.UI.Keymap.Overrides do
  @moduledoc """
  pass74 (spec §3.9.3, D19): the user's key overrides from cli.json `"keys"`
  (`binding id → [key names]`, `[]` = unbound), compiled once per change into
  lookups the resolver, the hints and the help sheet read.

  An override replaces a binding's keys in every context the binding reaches.
  Binding ids are strings in the file and are looked up in a compile-time map
  (never `String.to_atom/1`); key names are `Keymap.KeyName`'s.

  Fixed bindings (Esc, Enter, the arrows, Ctrl-C, `?`/F1, Ctrl-S, the approval
  letters and the in-hint bindings) are never remapped or unbound, and their
  keys cannot be taken. A key another binding holds in a shared context is
  refused with the contexts it is taken in; swapping both (one write) is how
  two bindings trade keys. `compile/1` never raises: an entry it cannot honour
  goes to `errors` (attention AT14) and the binding keeps its default keys.

  Pure; the recovery path is `swarmcode config reset terminal.keys`.
  """

  alias SwarmCodeCLI.UI.Keymap.{Binding, Bindings, KeyName}

  defstruct table: %{}, removed: MapSet.new(), by_id: %{}, errors: [], source: %{}

  @type key :: Binding.key()
  @type t :: %__MODULE__{
          table: %{{atom(), key()} => Binding.t()},
          removed: MapSet.t({atom(), key()}),
          by_id: %{atom() => [key()]},
          errors: [{String.t(), String.t()}],
          source: %{String.t() => [String.t()]}
        }

  @max_keys 4
  @max_entries 256

  @ids Map.new(Bindings.all(), &{Atom.to_string(&1.id), &1.id})
  @bindings Map.new(Bindings.all(), &{&1.id, &1})
  @order Bindings.all() |> Enum.with_index() |> Map.new(fn {b, i} -> {b.id, i} end)

  # Where each default key of each binding reaches it: %{id => %{key => [contexts]}}.
  @default_contexts Enum.reduce(Bindings.table(), %{}, fn {{context, key}, binding}, acc ->
                      Map.update(
                        acc,
                        binding.id,
                        %{key => [context]},
                        &Map.update(&1, key, [context], fn list -> [context | list] end)
                      )
                    end)

  @fixed_keys [
    {:escape, []},
    {:enter, []},
    {:up, []},
    {:down, []},
    {:left, []},
    {:right, []},
    {"c", [:control]},
    {"?", []},
    {{:function, 1}, []},
    {"s", [:control]}
  ]

  @fixed_ids ~w[confirm_yes approve_run always_allow deny deny_stop confirm_no
                hint_again hint_pick hint_run hint_runs_dashboard hint_cancel hint_backspace]a

  @doc "Compiles cli.json's `keys` value (nil or a map) into lookups."
  @spec compile(map() | nil) :: t()
  def compile(nil), do: %__MODULE__{}

  def compile(source) when is_map(source) do
    {parsed, errors} =
      source
      |> Enum.sort_by(fn {id, _} -> to_string(id) end)
      |> Enum.with_index()
      |> Enum.reduce({%{}, []}, fn {{sid, names}, index}, {parsed, errors} ->
        case parse_entry(sid, names, index) do
          {:ok, id, keys} -> {Map.put(parsed, id, keys), errors}
          {:error, message} -> {parsed, [{to_string(sid), message} | errors]}
        end
      end)

    {parsed, conflict_errors} = settle(parsed)
    errors = Enum.reverse(errors) ++ conflict_errors

    kept =
      source
      |> Enum.filter(fn {sid, _} -> Map.has_key?(parsed, Map.get(@ids, to_string(sid))) end)
      |> Map.new(fn {sid, names} -> {to_string(sid), names} end)

    build(parsed, errors, kept)
  end

  def compile(_), do: %__MODULE__{errors: [{"keys", "not a map of binding ids to key names"}]}

  @doc """
  The binding `code`/`mods` reaches in `context` under the overrides:
  a binding (an overridden key), `:unbound` (a default key the overrides took
  away) or `:default` (look it up in the default table).
  """
  @spec lookup(t() | nil, atom(), term(), [atom()]) :: Binding.t() | :default | :unbound
  def lookup(nil, _context, _code, _mods), do: :default

  def lookup(%__MODULE__{table: table, removed: removed}, context, code, mods) do
    key = {context, {code, mods}}

    case Map.fetch(table, key) do
      {:ok, binding} -> binding
      :error -> if MapSet.member?(removed, key), do: :unbound, else: :default
    end
  end

  @doc "The overridden keys of `id` (`[]` when unbound), or `:default`."
  @spec keys_for(t() | nil, atom()) :: [key()] | :default
  def keys_for(nil, _id), do: :default
  def keys_for(%__MODULE__{by_id: by_id}, id), do: Map.get(by_id, id, :default)

  @doc "The keys `id` answers to now (its override, else its default keys)."
  @spec effective_keys(t() | nil, atom()) :: [key()]
  def effective_keys(overrides, id) do
    case keys_for(overrides, id) do
      :default -> Bindings.keys_for(id)
      keys -> keys
    end
  end

  @doc """
  Whether `names` (key names) would be accepted for the binding `sid` on top of
  the overrides in force. The message is the first reason it would not.
  """
  @spec check(t() | nil, String.t(), [String.t()]) :: :ok | {:error, String.t()}
  def check(overrides, sid, names) do
    overrides = overrides || %__MODULE__{}
    trial = compile(Map.put(overrides.source, to_string(sid), names))

    case List.keyfind(trial.errors, to_string(sid), 0) do
      nil -> :ok
      {_, message} -> {:error, message}
    end
  end

  @doc """
  Reverse lookup (Key bindings `/ctrl-j`): every binding the key reaches under
  the overrides, with the contexts it reaches it in, in table order.
  """
  @spec bindings_for_key(t() | nil, String.t()) :: [{Binding.t(), [atom()]}]
  def bindings_for_key(overrides, name) do
    case KeyName.parse(name) do
      {:ok, keys} ->
        overrides = overrides || %__MODULE__{}
        occupancy = occupancy(overrides.by_id)

        pairs = for {{context, key}, ids} <- occupancy, key in keys, id <- ids, do: {id, context}

        pairs
        |> Enum.group_by(fn {id, _} -> id end, fn {_, context} -> context end)
        |> Enum.sort_by(fn {id, _} -> Map.fetch!(@order, id) end)
        |> Enum.map(fn {id, contexts} ->
          {effective_binding(overrides, id), Enum.sort_by(contexts, &context_rank/1)}
        end)

      {:error, _} ->
        []
    end
  end

  @doc "Whether a binding can never be remapped or unbound (D19)."
  @spec fixed?(atom()) :: boolean()
  def fixed?(id) do
    id in @fixed_ids or
      case Map.fetch(@bindings, id) do
        {:ok, %Binding{keys: keys}} -> Enum.any?(keys, &(&1 in @fixed_keys))
        :error -> false
      end
  end

  @doc "The contexts a binding reaches with its default keys, in `Bindings.contexts/0` order."
  @spec contexts(atom()) :: [atom()]
  def contexts(id) do
    @default_contexts
    |> Map.get(id, %{})
    |> Map.values()
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort_by(&context_rank/1)
  end

  @doc "The binding with its effective keys."
  @spec effective_binding(t() | nil, atom()) :: Binding.t() | nil
  def effective_binding(overrides, id) do
    case Map.fetch(@bindings, id) do
      {:ok, binding} -> %Binding{binding | keys: effective_keys(overrides, id)}
      :error -> nil
    end
  end

  @doc "The binding id atom for a cli.json id, or nil (never creates an atom)."
  @spec id(String.t()) :: atom() | nil
  def id(sid) when is_binary(sid), do: Map.get(@ids, sid)
  def id(_), do: nil

  @doc """
  The words of attention AT14, or nil when every override was honoured:
  `{"N key overrides in cli.json were ignored", first_reason}`.
  """
  @spec attention(t() | nil) :: {String.t(), String.t()} | nil
  def attention(%__MODULE__{errors: [{sid, reason} | _] = errors}) do
    count = length(errors)
    noun = if count == 1, do: "key override", else: "key overrides"
    {"#{count} #{noun} in cli.json were ignored", "#{sid}: #{reason}"}
  end

  def attention(_), do: nil

  @doc """
  The cli.json `keys` value after giving `sid` the keys `names` and handing
  the binding that holds the first of them `sid`'s current first key (the
  capture editor's `s swap`, one write for both).
  """
  @spec swap(t() | nil, String.t(), [String.t()]) ::
          {:ok, %{String.t() => [String.t()]}} | {:error, String.t()}
  def swap(overrides, sid, names) do
    overrides = overrides || %__MODULE__{}

    with id when not is_nil(id) <- id(sid),
         [name | _] <- names,
         {:ok, keys} <- KeyName.parse(name),
         [{other, _contexts} | _] <-
           overrides |> bindings_for_key(name) |> Enum.reject(fn {b, _} -> b.id == id end) do
      other_sid = Atom.to_string(other.id)
      theirs = effective_keys(overrides, other.id) -- keys
      given = overrides |> effective_keys(id) |> Enum.take(1)

      source =
        overrides.source
        |> Map.put(sid, names)
        |> Map.put(other_sid, Enum.map(theirs ++ given, &KeyName.name/1))

      case Enum.find(compile(source).errors, fn {s, _} -> s in [sid, other_sid] end) do
        nil -> {:ok, source}
        {_, message} -> {:error, message}
      end
    else
      [] -> {:error, "nothing holds that key"}
      {:error, message} -> {:error, message}
      _ -> {:error, "not a key name"}
    end
  end

  # ------------------------------------------------------------- internals

  defp parse_entry(sid, names, index) do
    sid = to_string(sid)

    with :ok <- if(index < @max_entries, do: :ok, else: {:error, "too many overrides"}),
         id when not is_nil(id) <- Map.get(@ids, sid),
         :ok <- list_ok(names),
         :ok <- fixed_ok(id, names),
         {:ok, keys} <- parse_names(names) do
      {:ok, id, keys}
    else
      nil -> {:error, "no binding is called #{sid}"}
      {:error, message} -> {:error, message}
    end
  end

  defp list_ok(names) when is_list(names) do
    cond do
      not Enum.all?(names, &is_binary/1) -> {:error, "not a key name"}
      length(names) > @max_keys -> {:error, "4 keys at most"}
      true -> :ok
    end
  end

  defp list_ok(_), do: {:error, "not a key name"}

  defp fixed_ok(id, names) do
    if fixed?(id) do
      label = Map.fetch!(@bindings, id).label

      if names == [],
        do: {:error, ~s("#{label}" cannot be unbound)},
        else: {:error, ~s("#{label}" cannot be remapped)}
    else
      :ok
    end
  end

  defp parse_names(names) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case KeyName.parse(name) do
        {:ok, keys} ->
          case Enum.find(keys, &(&1 in @fixed_keys)) do
            nil -> {:cont, {:ok, acc ++ (keys -- acc)}}
            _ -> {:halt, {:error, "#{String.trim(name)} is fixed"}}
          end

        {:error, message} ->
          {:halt, {:error, message}}
      end
    end)
  end

  # Drops overrides whose keys another binding holds in a shared context
  # (default or overridden), until none does. Deterministic: the binding
  # later in id order loses a tie.
  defp settle(parsed), do: settle(parsed, [])

  defp settle(parsed, errors) do
    occupancy = occupancy(parsed)

    conflict =
      parsed
      |> Enum.sort_by(fn {id, _} -> Atom.to_string(id) end)
      |> Enum.find_value(fn {id, keys} ->
        Enum.find_value(keys, fn key ->
          case holders(occupancy, id, key) do
            [] -> nil
            holders -> {id, key, holders}
          end
        end)
      end)

    case conflict do
      nil ->
        {parsed, Enum.reverse(errors)}

      {id, key, holders} ->
        settle(Map.delete(parsed, id), [{Atom.to_string(id), taken(key, holders)} | errors])
    end
  end

  defp holders(occupancy, id, key) do
    mine = MapSet.new(new_key_contexts(id, key))

    for {{context, ^key}, ids} <- occupancy,
        MapSet.member?(mine, context),
        other <- ids,
        other != id,
        do: {other, context}
  end

  defp taken(key, holders) do
    name = KeyName.name(key)

    case Enum.find(holders, fn {other, _} -> fixed?(other) end) do
      {_, _} ->
        "#{name} is fixed"

      nil ->
        [{other, _} | _] = Enum.sort_by(holders, fn {other, _} -> Map.fetch!(@order, other) end)

        contexts =
          holders
          |> Enum.filter(fn {id, _} -> id == other end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.uniq()
          |> Enum.sort_by(&context_rank/1)
          |> Enum.map_join(", ", &Atom.to_string/1)

        ~s(#{name} is taken by "#{Map.fetch!(@bindings, other).label}" in #{contexts})
    end
  end

  # %{{context, key} => [id]} for every binding's effective keys (a list: an
  # override may land on a key another binding still holds).
  defp occupancy(parsed) do
    Enum.reduce(@default_contexts, %{}, fn {id, keys}, acc ->
      pairs =
        case Map.fetch(parsed, id) do
          {:ok, new_keys} ->
            for key <- new_keys, context <- new_key_contexts(id, key), do: {context, key}

          :error ->
            for {key, contexts} <- keys, context <- contexts, do: {context, key}
        end

      Enum.reduce(pairs, acc, fn pair, acc -> Map.update(acc, pair, [id], &[id | &1]) end)
    end)
  end

  # The contexts a new key of `id` reaches: the binding's contexts, without
  # the typing contexts for a bare printable key.
  defp new_key_contexts(id, {code, mods}) do
    base = contexts(id)

    if is_binary(code) and mods == [],
      do: base -- Bindings.typing_contexts(),
      else: base
  end

  defp build(parsed, errors, source) do
    {table, removed} =
      Enum.reduce(parsed, {%{}, MapSet.new()}, fn {id, keys}, {table, removed} ->
        binding = %Binding{Map.fetch!(@bindings, id) | keys: keys}

        table =
          Enum.reduce(keys, table, fn key, table ->
            Enum.reduce(new_key_contexts(id, key), table, &Map.put(&2, {&1, key}, binding))
          end)

        removed =
          @default_contexts
          |> Map.get(id, %{})
          |> Enum.reduce(removed, fn {key, contexts}, removed ->
            Enum.reduce(contexts, removed, &MapSet.put(&2, {&1, key}))
          end)

        {table, removed}
      end)

    removed = MapSet.reject(removed, &Map.has_key?(table, &1))
    %__MODULE__{table: table, removed: removed, by_id: parsed, errors: errors, source: source}
  end

  defp context_rank(context) do
    Enum.find_index(Bindings.contexts(), &(&1 == context)) || 1_000
  end
end
