defmodule SwarmCode.Daemon.Service.Settings.Context do
  @moduledoc """
  What a settings query or command runs with (pass 74, spec §3.3.1): the
  session's project and conversation, the `--model` override, the §2.25
  list-B environment names that are set (never the whole environment), the
  task-cache entries the Router declared for this action or view, the cache
  hygiene marks and the settings revision. `Inspect` never shows the
  environment or task results.
  """

  @derive {Inspect, except: [:env, :task_results]}
  defstruct project: nil,
            conversation: nil,
            live?: false,
            override: nil,
            env: %{},
            task_results: %{},
            sessions_store: nil,
            seen: %{settings: nil, providers: nil, search_providers: nil, projects: nil},
            settings_revision: 0,
            now: nil,
            request_id: nil,
            origin: :tui

  @type t :: %__MODULE__{
          project: struct() | nil,
          conversation: struct() | nil,
          live?: boolean(),
          override: term() | nil,
          env: %{String.t() => String.t()},
          task_results: %{{String.t(), term()} => map()},
          sessions_store: list() | nil,
          seen: %{atom() => DateTime.t() | nil},
          settings_revision: non_neg_integer(),
          now: DateTime.t() | nil,
          request_id: String.t() | nil,
          origin: :tui | :headless
        }

  # §2.25 list B (and the developer names, shown only when set).
  @list_b ~w(SWARM_THEME SWARM_MOUSE SWARM_KEYMAP SWARM_ASCII NO_COLOR COLORTERM TERM TERM_PROGRAM
             VISUAL EDITOR SWARM_COMPANION SWARM_CONVERSATION SWARM_PROJECT_ROOT SWARM_MODEL_OVERRIDE
             SWARM_MODEL SWARM_PROVIDER SWARM_BASE_URL SWARM_API_KEY OPENAI_API_KEY OPENAI_BASE_URL
             OPENAI_MODEL ANTHROPIC_API_KEY ANTHROPIC_BASE_URL ANTHROPIC_MODEL SWARM_EFFORT
             SWARM_APPROVAL LLMOTIONS_API_KEY SWARM_ENV_FILE SWARM_CODE_CONFIG_DIR SWARM_CODE_SHELL
             XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR XDG_CACHE_HOME TMPDIR)

  @developer ~w(SWARM_TEST_EXPECTED SWARM_SCENE_DUMP SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT
                SWARM_CODE_DEMO_AUDIT_FD SWARM_RELEASE_TUI SWARM_RELEASE_MODE SWARM_PERSISTED
                SWARM_CODE_UPSTREAM SWARM_TERMINAL_PORT SWARM_USER_UMASK SWARM_PLAIN_FORMAT
                SWARM_SETTINGS_OPEN SWARM_SETTINGS_ONLY)

  @doc "The §2.25 list-B names."
  @spec list_b() :: [String.t()]
  def list_b, do: @list_b

  @doc "The developer names (listed only when set, never editable)."
  @spec developer_names() :: [String.t()]
  def developer_names, do: @developer

  @doc "Only the list-B and developer names of `environment` that are set."
  @spec env_from(%{String.t() => String.t()}) :: %{String.t() => String.t()}
  def env_from(environment) when is_map(environment),
    do: Map.take(environment, @list_b ++ @developer)

  @doc "A context for `swarmcode config` and tests."
  @spec new(keyword()) :: t()
  def new(fields \\ []) do
    struct(
      %__MODULE__{
        now: DateTime.utc_now(),
        request_id: random_id(),
        env: env_from(System.get_env())
      },
      fields
    )
  end

  defp random_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", [
      a,
      b,
      Bitwise.band(c, 0x0FFF),
      Bitwise.bor(Bitwise.band(d, 0x3FFF), 0x8000),
      e
    ])
    |> IO.iodata_to_binary()
  end
end
