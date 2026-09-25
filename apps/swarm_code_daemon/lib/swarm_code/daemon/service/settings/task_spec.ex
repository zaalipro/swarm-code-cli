defmodule SwarmCode.Daemon.Service.Settings.TaskSpec do
  @moduledoc """
  An async settings action the backend owns (pass 74, spec §3.3.1, §3.3.8).
  `key` identifies `{action, target}`: a new task with the same key replaces
  the old one. For a cancellable task `timeout_ms` is the kill deadline; for
  one that is not it is a reporting deadline that never kills. `kind` decides
  how it stops (`:plain` brutal kill, `:file` a 2 s shutdown so it removes its
  temporary files, `:probe` reaps the OS process tree). `run` receives a
  `report` function for progress maps. `redact` lists secrets that must never
  appear in a message or summary; `Inspect` hides it and the functions.
  """

  @derive {Inspect, except: [:redact, :run, :summary]}
  @enforce_keys [:action, :key, :timeout_ms, :run]
  defstruct action: nil,
            key: nil,
            timeout_ms: 30_000,
            cancellable?: true,
            kind: :plain,
            run: nil,
            summary: nil,
            redact: [],
            target: nil,
            holds_secrets?: false

  @type t :: %__MODULE__{
          action: String.t(),
          key: term(),
          timeout_ms: pos_integer(),
          cancellable?: boolean(),
          kind: :plain | :probe | :file,
          run: (function() -> {:ok, map()} | {:error, String.t()}),
          summary: (map() -> map()) | nil,
          redact: [String.t()],
          target: map() | nil,
          holds_secrets?: boolean()
        }

  # §3.3.8 table: timeout, cancellable, kind per action.
  @table %{
    "provider.test" => {15_000, true, :plain},
    "provider.set_key" => {15_000, true, :plain},
    "provider.fetch_models" => {30_000, true, :plain},
    "provider.fetch_all" => {120_000, true, :plain},
    "search.test" => {20_000, true, :plain},
    "search.set_key" => {20_000, true, :plain},
    "mcp.test" => {65_000, true, :probe},
    "mcp.reconnect" => {35_000, true, :plain},
    "mcp.import.read" => {10_000, true, :plain},
    "lsp.check" => {5_000, true, :plain},
    "storage.measure" => {120_000, true, :plain},
    "storage.plan" => {60_000, true, :plain},
    "storage.run" => {1_800_000, false, :plain},
    "storage.vacuum" => {1_800_000, false, :plain},
    "storage.apply_retention" => {600_000, false, :plain},
    "workflow.smoke" => {30_000, true, :plain},
    "export" => {10_000, true, :file},
    "import.preview" => {10_000, true, :file},
    "import.apply" => {60_000, false, :file},
    "doctor" => {30_000, true, :plain}
  }

  @doc "A spec with the §3.3.8 defaults of its action (fields in `opts` win)."
  @spec new(String.t(), term(), (function() -> term()), keyword()) :: t()
  def new(action, key, run, opts \\ []) do
    {timeout, cancellable?, kind} = Map.get(@table, action, {30_000, true, :plain})

    struct(
      %__MODULE__{
        action: action,
        key: key,
        run: run,
        timeout_ms: timeout,
        cancellable?: cancellable?,
        kind: kind
      },
      opts
    )
  end

  @doc "The §3.3.8 defaults of an action: `{timeout_ms, cancellable?, kind}`."
  @spec defaults(String.t()) :: {pos_integer(), boolean(), atom()} | nil
  def defaults(action), do: Map.get(@table, action)
end
