defmodule SwarmCode.Settings.RecordKind do
  @moduledoc """
  A record kind of the settings registry (pass 74, spec §2.23, §3.2.5): a
  provider, an MCP server, a pricing row, a file… and the task row kinds whose
  rows `view=task` pages (§2.23 "Task row kinds"). The client decodes records
  against these declarations: a field that is not declared is refused, a field
  declared `secret` must be exactly `{"set": bool, "hint": null | 4 characters}`
  (§3.4.6 rules 2 and 4).

  The declarations live in `SwarmCode.Settings.Registry.Records` (S2 owns that
  file after the tag `c74-S1-core`).
  """

  defmodule Field do
    @moduledoc "One field of a record kind."
    @enforce_keys [:name, :type]
    defstruct [
      :name,
      :type,
      secret: false,
      required: false,
      max: nil,
      editable: false,
      nullable: true,
      derived: false,
      choices: [],
      item: nil,
      validate: [],
      messages: %{}
    ]

    @type type ::
            :uuid
            | :string
            | :text
            | :url
            | :bool
            | :integer
            | :number
            | :enum
            | :list
            | :map
            | :json
            | :secret
            | :kv_secrets
            | :datetime
            | {:records, String.t()}

    @type t :: %__MODULE__{
            name: String.t(),
            type: type(),
            secret: boolean(),
            required: boolean(),
            max: pos_integer() | nil,
            editable: boolean(),
            nullable: boolean(),
            derived: boolean(),
            choices: [term()],
            item: atom() | nil,
            validate: [term()],
            messages: %{optional(atom()) => String.t()}
          }
  end

  @enforce_keys [:name, :fields]
  defstruct [:name, :table, :fields, role: :record, id_field: "id", order: nil]

  @type role :: :record | :task_row | :nested
  @type t :: %__MODULE__{
          name: String.t(),
          table: String.t() | nil,
          role: role(),
          fields: [Field.t()],
          id_field: String.t() | nil,
          order: [String.t()] | nil
        }

  @records SwarmCode.Settings.Registry.Records
  @kinds @records.kinds()
  @by_name Map.new(@kinds, &{&1.name, &1})
  @task_rows @records.task_rows()
  @query_kind_records @records.query_kind_records()

  @doc "Every declared kind (records, nested kinds and task row kinds)."
  @spec all() :: [t()]
  def all, do: @kinds

  @doc "The kind named `name` (a wire string; never creates atoms)."
  @spec fetch(term()) :: {:ok, t()} | :error
  def fetch(name) when is_binary(name) do
    case Map.fetch(@by_name, name) do
      {:ok, kind} -> {:ok, kind}
      :error -> :error
    end
  end

  def fetch(_name), do: :error

  @doc "The field `name` of a kind."
  @spec field(t(), String.t()) :: Field.t() | nil
  def field(%__MODULE__{fields: fields}, name), do: Enum.find(fields, &(&1.name == name))

  @doc "The names of a kind's fields."
  @spec field_names(t()) :: [String.t()]
  def field_names(%__MODULE__{fields: fields}), do: Enum.map(fields, & &1.name)

  @doc "The names of a kind's secret fields."
  @spec secret_fields(t()) :: [String.t()]
  def secret_fields(%__MODULE__{fields: fields}),
    do: for(%Field{secret: true, name: name} <- fields, do: name)

  @doc "The row kind of a task action's `view=task` rows (§2.23), or nil."
  @spec task_row_kind(String.t()) :: String.t() | nil
  def task_row_kind(action), do: Map.get(@task_rows, action)

  @doc "The record kind of a `records`/`record` view's `kind` (`providers` → `provider`), or nil."
  @spec for_query_kind(term()) :: String.t() | nil
  def for_query_kind(kind) when is_binary(kind), do: Map.get(@query_kind_records, kind)
  def for_query_kind(_kind), do: nil

  @doc "The effective list bound of a field: its `max`, else 200 (§3.4.6 rule 4)."
  @spec list_max(Field.t()) :: pos_integer()
  def list_max(%Field{max: max}) when is_integer(max), do: max
  def list_max(%Field{}), do: 200
end
