defmodule SwarmCode.Settings.Registry.ProjectFile do
  @moduledoc false
  # §2.11 Project file: the top-level keys of <root>/.swarm_code/config.json
  # SwarmCode ignores (D15) and the keys a project file may not set. Hooks and
  # profiles are records (§2.23).
  import SwarmCode.Settings.Registry.Build

  @ignored "SwarmCode ignores this key · x removes it"

  @denied ~w(tavily_api_key default_chat_provider_id default_swarm_provider_id
             default_scheduled_provider_id default_workflow_provider_id monthly_budget_usd
             workflow_budget)

  @doc false
  def denied_keys, do: @denied

  @doc false
  def ignored_keys, do: ~w(effort swarm_effort model swarm_model)

  @entries [
    entry("project_file.effort", :project_file, "effort",
      scope: :project_file,
      storage: {:project_file_key, "effort"},
      type: :fact,
      description: @ignored,
      applies: :at_once,
      parity: "I§5.4"
    ),
    entry("project_file.swarm_effort", :project_file, "swarm_effort",
      scope: :project_file,
      storage: {:project_file_key, "swarm_effort"},
      type: :fact,
      description: @ignored,
      parity: "I§5.4"
    ),
    entry("project_file.model", :project_file, "model",
      scope: :project_file,
      storage: {:project_file_key, "model"},
      type: :fact,
      description: @ignored,
      parity: "I§5.4"
    ),
    entry("project_file.swarm_model", :project_file, "swarm_model",
      scope: :project_file,
      storage: {:project_file_key, "swarm_model"},
      type: :fact,
      description: @ignored,
      parity: "I§5.4"
    ),
    entry("project_file.denied", :project_file, "Keys a project file may not set",
      scope: :project_file,
      storage: {:project_file_key, :denied},
      type: :fact,
      stored_name: "config.json " <> Enum.join(@denied, ", "),
      description:
        "Stripped with a warning when the file is read: tavily_api_key, the default provider ids, monthly_budget_usd, workflow_budget. x removes one.",
      parity: "I§5.2"
    ),
    action("project_file.edit", :project_file, "Edit the whole file in your editor", "file.save",
      description:
        "JSON errors are reported after the save and the file is saved as typed; a new or changed hook command in a trusted project asks first.",
      synonyms: ["edit config.json"],
      since: :c74,
      parity: "NEW"
    )
  ]

  def entries, do: @entries
end
