defmodule SwarmCode.Settings.Entry do
  @moduledoc """
  One settings registry entry (pass 74, spec §3.2.1): a setting, a fact, an
  action or a link row. Entries are compiled data; nothing here is built from
  runtime input. `key` is the dotted string every side uses on the wire; `id`
  is the compile-time atom (D32).
  """

  @enforce_keys [:key, :id, :section, :label, :scope, :storage, :type]
  defstruct [
    :key,
    :id,
    :section,
    :label,
    :scope,
    :storage,
    :type,
    group: nil,
    description: "",
    choices: [],
    dynamic_choices: nil,
    item: nil,
    min: nil,
    max: nil,
    step: 1,
    big_step: nil,
    unit: nil,
    special: %{},
    nullable: false,
    null_label: nil,
    default: nil,
    example: nil,
    layers: [],
    home: nil,
    env: [],
    flag: nil,
    follows: nil,
    applies: :at_once,
    shared: false,
    desktop_only: false,
    scheduler_only: false,
    secret: false,
    resettable: true,
    confirm: nil,
    validate: [],
    messages: %{},
    synonyms: [],
    stored_name: nil,
    parity: nil,
    since: :existing,
    ignored_layers: []
  ]

  @type scope :: :global | :session | :project | :cli | :project_file | :fact | :action | :link
  @type layer :: :flag | :env | :session | :project | :cli | :global | :project_file | :default
  @type choice :: %{value: term(), label: String.t(), hint: String.t() | nil}

  @type t :: %__MODULE__{
          key: String.t(),
          id: atom(),
          section: atom(),
          label: String.t(),
          scope: scope(),
          storage: term(),
          type: atom(),
          group: String.t() | nil,
          description: String.t(),
          choices: [choice()],
          dynamic_choices: nil | {:effort_of, atom()},
          item: nil | :domain | :env_name | :command_family | :model_id | :text,
          min: number() | nil,
          max: number() | nil,
          step: pos_integer(),
          big_step: pos_integer() | nil,
          unit: nil | :ms | :s | :days | :usd | :rows | :lines | :letters | :px,
          special: %{optional(term()) => String.t()},
          nullable: boolean(),
          null_label: String.t() | nil,
          default: term(),
          example: term(),
          layers: [layer()],
          home: layer() | nil,
          env: [String.t()],
          flag: String.t() | nil,
          follows: String.t() | nil,
          applies: atom(),
          shared: boolean(),
          desktop_only: boolean(),
          scheduler_only: boolean(),
          secret: boolean(),
          resettable: boolean(),
          confirm: nil | :always | {:escalate, [term()]},
          validate: [term()],
          messages: %{optional(atom()) => String.t()},
          synonyms: [String.t()],
          stored_name: String.t() | nil,
          parity: String.t() | nil,
          since: :existing | :c74,
          ignored_layers: [{layer(), String.t()}]
        }

  @doc "True for entries that hold a value (not facts, actions or links)."
  @spec scalar?(t()) :: boolean()
  def scalar?(%__MODULE__{scope: scope}),
    do: scope in [:global, :session, :project, :cli, :project_file]

  @doc "True for entries a user can write (a scalar with a home layer)."
  @spec writable?(t()) :: boolean()
  def writable?(%__MODULE__{home: nil}), do: false
  def writable?(%__MODULE__{scope: :project_file}), do: false
  def writable?(%__MODULE__{} = entry), do: scalar?(entry)

  @doc "The values of an entry's static choices, in order."
  @spec choice_values(t()) :: [term()]
  def choice_values(%__MODULE__{choices: choices}), do: Enum.map(choices, & &1.value)
end
