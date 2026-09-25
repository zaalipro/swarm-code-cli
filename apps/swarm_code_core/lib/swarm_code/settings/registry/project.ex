defmodule SwarmCode.Settings.Registry.Project do
  @moduledoc false
  # §2.10 Approvals & trust: one project's columns (scope :project).
  import SwarmCode.Settings.Registry.Build

  @entries [
    project("project.approval_mode", :approvals, "Approvals",
      storage: {:project, :approval_mode},
      type: :enum,
      choices:
        choices([
          {"read_only", "Read-only", "nothing runs or changes without asking"},
          {"auto", "Auto", "edits go ahead, commands ask first"},
          {"full_access", "Full access", "commands and edits go ahead"}
        ]),
      default: "read_only",
      confirm: {:escalate, ["full_access"]},
      applies: :at_once,
      synonyms: ["approvals", "approval mode", "permissions"],
      parity: "A§2.10, /approval"
    ),
    project("project.trusted", :approvals, "Trusted",
      description:
        "Reads AGENTS.md and lets hooks run. Untrusting puts approvals back to read-only.",
      storage: :project_trust,
      type: :toggle,
      default: false,
      confirm: :always,
      resettable: false,
      applies: :at_once,
      synonyms: ["trust"],
      parity: "/trust, I§10"
    ),
    project("project.allow", :approvals, "Always-allowed commands",
      description: "A command whose first words match runs without asking, in this project only.",
      storage: {:project, :auto_approve_prefixes},
      type: :list,
      item: :command_family,
      default: [],
      validate: [
        {:list_max, 64},
        :unique_items,
        {:item, :command_family},
        {:svc, :not_dangerous},
        {:svc, :not_scratch}
      ],
      messages: %{
        not_dangerous: "a dangerous command is never remembered",
        not_scratch: "the scratch project keeps no always-allowed commands"
      },
      applies: :next_turn,
      synonyms: ["always allowed", "allow list", "approved commands"],
      parity: "D§12a"
    ),
    project("project.name", :approvals, "Name",
      description: "The desktop sidebar shows it.",
      storage: {:project, :name},
      type: :text,
      example: "ailogic",
      validate: [:required, {:max_length, 120}],
      resettable: false,
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    fact("project.root", :approvals, "Folder", :project_root, parity: "I§10"),
    fact("project.last_opened", :approvals, "Last opened", :project_last_opened, parity: "I§10"),
    fact("project.approval_env", :approvals, "From the environment", :approval_env,
      description: "SWARM_APPROVAL is read only by unsaved live sessions; it has no effect here.",
      env: ["SWARM_APPROVAL"],
      parity: "A§6.2"
    )
  ]

  def entries, do: @entries
end
