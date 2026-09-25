defmodule SwarmCode.Settings.Registry.Session do
  @moduledoc false
  # §2.2 Models & effort: this conversation's values (scope :session).
  import SwarmCode.Settings.Registry.Build

  @effort_format [{:format, "^[a-z0-9][a-z0-9_-]{0,23}$"}]
  @model_msg %{provider_exists: "that provider no longer exists"}

  @consensus_checks [
    {"over_engineering", "Avoid over-engineering", "on by default"},
    {"judge_plan", "Judge the plan before any change", "on by default"},
    {"judge_changes", "Judge the changes after implementing", nil},
    {"minimal", "Keep changes minimal", "on by default"},
    {"codebase", "Compare against the codebase", "on by default"},
    {"scope", "Scope guard", "on by default"},
    {"edge_cases", "Missing requirements & edge cases", "on by default"},
    {"risk", "Risk & safety review", nil},
    {"tests", "Require verification", nil},
    {"alternatives", "Propose a simpler alternative", nil},
    {"decision_complete", "No open questions left", nil},
    {"gate", "Ask me before implementing", "on by default"}
  ]

  @doc false
  def consensus_check_keys, do: Enum.map(@consensus_checks, &elem(&1, 0))

  @entries [
    session("session.model", :models_effort, "Model · this conversation",
      group: "this conversation",
      description:
        "The model of this conversation's next turn. A write also ends a --model launch override, as /model does.",
      storage: {:conversation_pair, :chat_provider_id, :chat_model},
      type: :model,
      nullable: true,
      null_label: "the chat model",
      layers: [:flag, :session, :global, :default],
      flag: "--model",
      env: ["SWARM_MODEL_OVERRIDE"],
      follows: "models.chat",
      validate: [{:svc, :provider_exists}],
      messages: @model_msg,
      applies: :next_turn,
      parity: "CLI /model"
    ),
    session("session.effort", :models_effort, "Effort · this conversation",
      group: "this conversation",
      description:
        "Reasoning effort of this conversation's next turn; a running turn keeps its level.",
      storage: {:conversation, :effort},
      type: :effort,
      dynamic_choices: {:effort_of, :session_chat},
      nullable: true,
      null_label: "the default effort",
      layers: [:session, :global, :default],
      follows: "efforts.default",
      validate: @effort_format ++ [{:svc, :effort_of_model}],
      applies: :next_turn,
      parity: "CLI /effort"
    ),
    session("session.sub_agent_model", :models_effort, "Sub-agent model · this conversation",
      group: "this conversation",
      description:
        "The model of this conversation's workers. A write also ends a --model launch override, as /swarm_model does.",
      storage: {:conversation_pair, :swarm_provider_id, :swarm_model},
      type: :model,
      nullable: true,
      null_label: "the sub-agent model",
      layers: [:flag, :session, :global, :default],
      flag: "--model",
      env: ["SWARM_MODEL_OVERRIDE"],
      follows: "models.sub_agent",
      validate: [{:svc, :provider_exists}],
      messages: @model_msg,
      applies: :next_spawn,
      parity: "CLI /swarm_model"
    ),
    session("session.sub_agent_effort", :models_effort, "Sub-agent effort · this conversation",
      group: "this conversation",
      description: "Reasoning effort of this conversation's workers.",
      storage: {:conversation, :swarm_effort},
      type: :effort,
      dynamic_choices: {:effort_of, :session_swarm},
      nullable: true,
      null_label: "the sub-agent effort",
      layers: [:session, :global, :default],
      follows: "efforts.sub_agent",
      validate: @effort_format ++ [{:svc, :effort_of_model}],
      applies: :next_spawn,
      parity: "CLI /swarm_effort"
    ),
    session("session.mode", :models_effort, "Mode",
      group: "this conversation",
      description:
        "Build makes changes; plan only plans; consensus plans, judges, then implements; ultra works harder on each turn; workflow sends your messages to /create-workflow.",
      storage: {:conversation_mode},
      type: :enum,
      choices:
        choices([
          {"build", "Build"},
          {"plan", "Plan"},
          {"consensus", "Consensus"},
          {"ultra", "Ultra"},
          {"workflow", "Writing a workflow"}
        ]),
      default: "build",
      applies: :next_turn,
      synonyms: ["mode", "plan", "consensus", "ultra", "plan mode"],
      parity: "CLI /plan /consensus /ultra /create-workflow"
    ),
    session("session.title", :models_effort, "Title",
      group: "this conversation",
      storage: {:conversation, :title},
      type: :text,
      default: "New conversation",
      validate: [{:max_length, 120}],
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    session("session.pinned", :models_effort, "Pinned",
      group: "this conversation",
      description: "Storage cleanup never deletes a pinned conversation.",
      storage: :conversation_pinned,
      type: :toggle,
      default: false,
      applies: :at_once,
      since: :c74,
      parity: "NEW"
    ),
    session("session.consensus_checks", :models_effort, "Consensus checks",
      group: "consensus · this conversation",
      description: "What the judge looks at. Used only in consensus mode.",
      storage: {:conversation, :consensus_checks},
      type: :checklist,
      choices: choices(@consensus_checks),
      nullable: true,
      null_label: "the 7 defaults",
      validate: [{:svc, :known_checks}],
      messages: %{known_checks: "unknown check: {key}"},
      applies: :next_turn,
      parity: "D§15a"
    ),
    session("session.consensus_rounds", :models_effort, "Consensus rounds",
      group: "consensus · this conversation",
      description: "Used only in consensus mode.",
      storage: {:conversation, :consensus_rounds},
      type: :enum,
      choices: choices([{1, "1"}, {2, "2"}, {3, "3"}]),
      default: 2,
      applies: :next_turn,
      parity: "D§15a"
    ),
    session("session.judge_model", :models_effort, "Judge model",
      group: "consensus · this conversation",
      description: "Used only in consensus mode.",
      storage: {:conversation_pair, :judge_provider_id, :judge_model},
      type: :model,
      nullable: true,
      null_label: "the sub-agent model",
      layers: [:session, :global, :default],
      follows: "models.sub_agent",
      validate: [{:svc, :provider_exists}],
      messages: @model_msg,
      applies: :next_turn,
      parity: "D§15a"
    ),
    session("session.judge_effort", :models_effort, "Judge effort",
      group: "consensus · this conversation",
      description: "Used only in consensus mode.",
      storage: {:conversation, :judge_effort},
      type: :effort,
      dynamic_choices: {:effort_of, :session_judge},
      nullable: true,
      null_label: "the default",
      validate: @effort_format,
      applies: :next_turn,
      parity: "D§15a"
    ),
    session("session.implementer_model", :models_effort, "Implementer model · this conversation",
      group: "consensus · this conversation",
      description: "Used only in consensus mode.",
      storage: {:conversation_pair, :implementer_provider_id, :implementer_model},
      type: :model,
      nullable: true,
      null_label: "the default implementer",
      layers: [:session, :global, :default],
      follows: "models.implementer",
      validate: [{:svc, :provider_exists}],
      messages: @model_msg,
      applies: :next_turn,
      parity: "D§15a"
    ),
    session(
      "session.implementer_effort",
      :models_effort,
      "Implementer effort · this conversation",
      group: "consensus · this conversation",
      description: "Used only in consensus mode.",
      storage: {:conversation, :implementer_effort},
      type: :effort,
      dynamic_choices: {:effort_of, :session_implementer},
      nullable: true,
      null_label: "the default implementer effort",
      layers: [:session, :global, :default],
      follows: "efforts.implementer",
      validate: @effort_format,
      applies: :next_turn,
      parity: "D§15a"
    ),
    action("session.profile", :models_effort, "Apply a profile", "profile.apply",
      group: "this conversation",
      description:
        "Writes effort, sub-agent effort, model and sub-agent model of this conversation from one of the project file's profiles.",
      messages: %{unknown: "Unknown profile \"{name}\""},
      parity: "I§5.4"
    )
  ]

  def entries, do: @entries
end
