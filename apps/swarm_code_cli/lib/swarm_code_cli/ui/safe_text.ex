defmodule SwarmCodeCLI.UI.SafeText do
  @moduledoc """
  Bounded inert terminal text. Trusted chrome has a closed, fixed catalogue.

  External values are revalidated at `value/1`: Elixir structs are forgeable, so
  an opaque type alone is never a terminal safety boundary. Limits are byte
  ceilings, not truncation: a field returns an error without partial output.

  `external_chunks/2` treats its enumerable as ONE logical bounded field, not
  independent records. It lazily consumes at most the input bound, halts on the
  first oversized chunk, then emits exactly one result at EOF. Buffering that
  bounded field preserves UTF-8, extended graphemes and tab columns across any
  chunk split (including an arbitrarily long combining sequence). For a long
  document, callers stream separately bounded logical fields.

  Variation selectors are retained only for attested base/selector pairs from
  Unicode 17.0.0 standardized/emoji variants and the IVD 2025-07-14 registry.
  An emoji join is retained only when each component survives sanitization;
  escaping a deceptive mark cannot leave behind a contextless invisible join.

  """
  alias SwarmCodeCLI.UI.SafeText.{Limits, Variants}
  alias SwarmCodeCLI.UI.Width
  alias SwarmCodeCLI.UI.Width.Table
  @mark_regex ~r/^\p{M}$/u
  @derive {Inspect, only: []}
  @enforce_keys [:token]
  defstruct [:token]
  @opaque t :: %__MODULE__{token: chrome() | {:external, binary()}}
  @type chrome ::
          :previous_page
          | :next_page
          | :full_detail
          | :no_results
          | :confirm_stop
          | :steer
          | :mark_seen
          | :line_break
          | :submit
          | :text_limit
          | :title
          | :fake_banner_compact
          | :live_banner
          | :persisted_banner
          | :build_mode
          | :navigator
          | :inspector
          | :composer
          | :activity
          | :status
          | :resize_help
          | :plain_exit
          | :unsent_changes
          | :cancel_exit
          | :confirm_exit
          | :help_key
          | :detach_key
          | :plain_key
          | :back_close_help
          | :read_only_resize
          | :needs
          | :target_main
          | :validation_none
          | :focus_label
          | :inspect
          | :pause
          | :continue
          | :send
          | :queue
          | :superseded_child
          | :research_depth
          | :representative_only
          | :consensus_docket
          | :consensus_ledger
          | :research_report
          | :sources
          | :diagnostics
          | :loading_before
          | :loading_after
          | :page_error
          | :accepted
          | :needs_input
          | :rejected
          | :deadline_exceeded
          | :outcome_unknown
          | :revision_conflict
          | :fake_banner
          | :empty
          | :main
          | :help
          | :detach
          | :plain
          | :focus_marker
          | :selection_marker
          | :disabled_marker
          | :stale_marker
          | :accent_marker
          | :success_marker
          | :warning_marker
          | :error_marker
          | :info_marker
          | :run_assistant
          | :run_goal
          | :run_swarm
          | :run_workflow
          | :run_research
          | :run_consensus_judge
          | :run_ultra
          | :agent_lane_1
          | :agent_lane_2
          | :agent_lane_3
          | :agent_lane_4
          | :agent_lane_5
          | :approve
          | :deny
          | :always_allow
          | :retry
          | :resume
          | :stop
          | :cancel
          | :confirm
          | :retry_available
          | :resume_available
          | :status_connecting
          | :status_empty
          | :status_loading
          | :status_running
          | :status_streaming
          | :status_queued
          | :status_waiting_question
          | :status_waiting_approval
          | :status_paused
          | :status_retrying
          | :status_done
          | :status_failed
          | :status_stopped
          | :status_interrupted
          | :status_stale
          | :status_resyncing
          | :status_disconnected
          | :status_superseded
          | :status_mutation_pending
          | :swarmcode_wordmark
          | :workspace_label
          | :nav_conversation
          | :nav_activity
          | :nav_workflows
          | :nav_research
          | :nav_memory
          | :runs_label
          | :glyph_selected
          | :glyph_inactive
          | :glyph_workflows
          | :glyph_research
          | :glyph_memory
          | :glyph_changes
          | :live_run_label
          | :agents_label
          | :you_label
          | :assistant_label
          | :tool_label
          | :system_label
          | :gap_hairline
          | :composer_gutter
          | :pipeline_arrow
          | :persistent_objective
          | :plan_approve
          | :plan_revise
          | :plan_decline
          | :plan_done
          | :plan_steps_label
          | :glyph_selected_ascii
          | :glyph_inactive_ascii
          | :glyph_workflows_ascii
          | :glyph_research_ascii
          | :glyph_memory_ascii
          | :glyph_changes_ascii
          | :composer_gutter_ascii
          | :pipeline_arrow_ascii
          | :plan_done_ascii
          | :glyph_failed
          | :glyph_failed_ascii
          | :stripe
          | :stripe_ascii
          | :stripe_off
          | :stripe_off_ascii
          | :rail
          | :rail_gap
          | :rail_ascii
          | :corner_tl
          | :corner_tl_ascii
          | :corner_tr
          | :corner_tr_ascii
          | :corner_bl
          | :corner_bl_ascii
          | :corner_br
          | :corner_br_ascii
          | :seg_on
          | :seg_on_ascii
          | :seg_off
          | :seg_off_ascii
          | :rule
          | :rule_ascii
          | :eighth_1
          | :eighth_2
          | :eighth_3
          | :eighth_4
          | :eighth_5
          | :eighth_6
          | :eighth_7
          | :block_full
          | :half_lower
          | :half_upper
          | :vert_1
          | :vert_2
          | :vert_3
          | :vert_4
          | :vert_5
          | :vert_6
          | :vert_7
          | :dash_rule
          | :copy_mark
          | :copy_mark_ascii
          | :ops_mark
          | :ops_mark_ascii
          | :command_mark
          | :command_mark_ascii
          | :dot_small
          | :dot_small_ascii
          | :dot
          | :dot_ascii
          | :agent_lead
          | :agent_lead_ascii
          | :agent_sub
          | :agent_sub_ascii
          | :assistant_mark
          | :assistant_mark_ascii
          | :kind_swarm_mark
          | :kind_swarm_mark_ascii
          | :kind_consensus_mark
          | :kind_consensus_mark_ascii
          | :kind_plan
          | :kind_plan_ascii
          | :close_mark
          | :close_mark_ascii
          | :settings_mark
          | :settings_mark_ascii
          | :logo_mark
          | :logo_mark_ascii
          | :search_mark
          | :search_mark_ascii
          | :branch_mark
          | :branch_mark_ascii
          | :retry_mark
          | :retry_mark_ascii
          | :enter_key
          | :enter_key_ascii
          | :check_mark
          | :check_mark_ascii
          | :chevron
          | :chevron_ascii
          | :write_mark
          | :write_mark_ascii
          | :clock_mark
          | :clock_mark_ascii
          | :effort_mark
          | :effort_mark_ascii
          | :shield_mark
          | :shield_mark_ascii
          | :usage_mark
          | :usage_mark_ascii
          | :hex_full
          | :hex_full_ascii
          | :hex_empty
          | :hex_empty_ascii
          | :judge
          | :judge_ascii
          | :caret
          | :caret_ascii
          | :collapsed
          | :collapsed_ascii
          | :expanded
          | :expanded_ascii
          | :check
          | :check_ascii
          | :fail
          | :fail_ascii
          | :gauge_on
          | :gauge_on_ascii
          | :gauge_off
          | :gauge_off_ascii
          | :waiting
          | :waiting_ascii
          | :jump_title
          | :jump_top
          | :jump_bottom
          | :jump_next_run
          | :jump_previous_run
          | {:braille, 0..255}

  def chrome(:full_detail), do: %__MODULE__{token: :full_detail}
  def chrome(:next_page), do: %__MODULE__{token: :next_page}
  def chrome(:previous_page), do: %__MODULE__{token: :previous_page}
  def chrome(:no_results), do: %__MODULE__{token: :no_results}
  def chrome(:confirm_stop), do: %__MODULE__{token: :confirm_stop}
  def chrome(:steer), do: %__MODULE__{token: :steer}
  def chrome(:mark_seen), do: %__MODULE__{token: :mark_seen}
  def chrome(:line_break), do: %__MODULE__{token: :line_break}
  def chrome(:submit), do: %__MODULE__{token: :submit}
  def chrome(:text_limit), do: %__MODULE__{token: :text_limit}
  def chrome(:title), do: %__MODULE__{token: :title}
  def chrome(:fake_banner_compact), do: %__MODULE__{token: :fake_banner_compact}
  def chrome(:live_banner), do: %__MODULE__{token: :live_banner}
  def chrome(:persisted_banner), do: %__MODULE__{token: :persisted_banner}
  def chrome(:build_mode), do: %__MODULE__{token: :build_mode}
  def chrome(:navigator), do: %__MODULE__{token: :navigator}
  def chrome(:inspector), do: %__MODULE__{token: :inspector}
  def chrome(:composer), do: %__MODULE__{token: :composer}
  def chrome(:activity), do: %__MODULE__{token: :activity}
  def chrome(:status), do: %__MODULE__{token: :status}
  def chrome(:resize_help), do: %__MODULE__{token: :resize_help}
  def chrome(:plain_exit), do: %__MODULE__{token: :plain_exit}
  def chrome(:unsent_changes), do: %__MODULE__{token: :unsent_changes}
  def chrome(:cancel_exit), do: %__MODULE__{token: :cancel_exit}
  def chrome(:confirm_exit), do: %__MODULE__{token: :confirm_exit}
  def chrome(:help_key), do: %__MODULE__{token: :help_key}
  def chrome(:detach_key), do: %__MODULE__{token: :detach_key}
  def chrome(:plain_key), do: %__MODULE__{token: :plain_key}
  def chrome(:back_close_help), do: %__MODULE__{token: :back_close_help}
  def chrome(:read_only_resize), do: %__MODULE__{token: :read_only_resize}
  def chrome(:needs), do: %__MODULE__{token: :needs}
  def chrome(:target_main), do: %__MODULE__{token: :target_main}
  def chrome(:validation_none), do: %__MODULE__{token: :validation_none}
  def chrome(:focus_label), do: %__MODULE__{token: :focus_label}
  def chrome(:inspect), do: %__MODULE__{token: :inspect}
  def chrome(:pause), do: %__MODULE__{token: :pause}
  def chrome(:continue), do: %__MODULE__{token: :continue}
  def chrome(:send), do: %__MODULE__{token: :send}
  def chrome(:queue), do: %__MODULE__{token: :queue}
  def chrome(:superseded_child), do: %__MODULE__{token: :superseded_child}
  def chrome(:research_depth), do: %__MODULE__{token: :research_depth}
  def chrome(:representative_only), do: %__MODULE__{token: :representative_only}
  def chrome(:consensus_docket), do: %__MODULE__{token: :consensus_docket}
  def chrome(:consensus_ledger), do: %__MODULE__{token: :consensus_ledger}
  def chrome(:research_report), do: %__MODULE__{token: :research_report}
  def chrome(:sources), do: %__MODULE__{token: :sources}
  def chrome(:diagnostics), do: %__MODULE__{token: :diagnostics}
  def chrome(:loading_before), do: %__MODULE__{token: :loading_before}
  def chrome(:loading_after), do: %__MODULE__{token: :loading_after}
  def chrome(:page_error), do: %__MODULE__{token: :page_error}
  def chrome(:accepted), do: %__MODULE__{token: :accepted}
  def chrome(:needs_input), do: %__MODULE__{token: :needs_input}
  def chrome(:rejected), do: %__MODULE__{token: :rejected}
  def chrome(:deadline_exceeded), do: %__MODULE__{token: :deadline_exceeded}
  def chrome(:outcome_unknown), do: %__MODULE__{token: :outcome_unknown}
  def chrome(:revision_conflict), do: %__MODULE__{token: :revision_conflict}

  def chrome(:fake_banner), do: %__MODULE__{token: :fake_banner}
  def chrome(:empty), do: %__MODULE__{token: :empty}
  def chrome(:main), do: %__MODULE__{token: :main}
  def chrome(:help), do: %__MODULE__{token: :help}
  def chrome(:detach), do: %__MODULE__{token: :detach}
  def chrome(:plain), do: %__MODULE__{token: :plain}
  def chrome(:focus_marker), do: %__MODULE__{token: :focus_marker}
  def chrome(:selection_marker), do: %__MODULE__{token: :selection_marker}
  def chrome(:disabled_marker), do: %__MODULE__{token: :disabled_marker}
  def chrome(:stale_marker), do: %__MODULE__{token: :stale_marker}
  def chrome(:accent_marker), do: %__MODULE__{token: :accent_marker}
  def chrome(:success_marker), do: %__MODULE__{token: :success_marker}
  def chrome(:warning_marker), do: %__MODULE__{token: :warning_marker}
  def chrome(:error_marker), do: %__MODULE__{token: :error_marker}
  def chrome(:info_marker), do: %__MODULE__{token: :info_marker}
  def chrome(:run_assistant), do: %__MODULE__{token: :run_assistant}
  def chrome(:run_goal), do: %__MODULE__{token: :run_goal}
  def chrome(:run_swarm), do: %__MODULE__{token: :run_swarm}
  def chrome(:run_workflow), do: %__MODULE__{token: :run_workflow}
  def chrome(:run_research), do: %__MODULE__{token: :run_research}
  def chrome(:run_consensus_judge), do: %__MODULE__{token: :run_consensus_judge}
  def chrome(:run_ultra), do: %__MODULE__{token: :run_ultra}
  def chrome(:agent_lane_1), do: %__MODULE__{token: :agent_lane_1}
  def chrome(:agent_lane_2), do: %__MODULE__{token: :agent_lane_2}
  def chrome(:agent_lane_3), do: %__MODULE__{token: :agent_lane_3}
  def chrome(:agent_lane_4), do: %__MODULE__{token: :agent_lane_4}
  def chrome(:agent_lane_5), do: %__MODULE__{token: :agent_lane_5}
  def chrome(:approve), do: %__MODULE__{token: :approve}
  def chrome(:deny), do: %__MODULE__{token: :deny}
  def chrome(:always_allow), do: %__MODULE__{token: :always_allow}
  def chrome(:retry), do: %__MODULE__{token: :retry}
  def chrome(:resume), do: %__MODULE__{token: :resume}
  def chrome(:stop), do: %__MODULE__{token: :stop}
  def chrome(:cancel), do: %__MODULE__{token: :cancel}
  def chrome(:confirm), do: %__MODULE__{token: :confirm}
  def chrome(:retry_available), do: %__MODULE__{token: :retry_available}
  def chrome(:resume_available), do: %__MODULE__{token: :resume_available}
  def chrome(:status_connecting), do: %__MODULE__{token: :status_connecting}
  def chrome(:status_empty), do: %__MODULE__{token: :status_empty}
  def chrome(:status_loading), do: %__MODULE__{token: :status_loading}
  def chrome(:status_running), do: %__MODULE__{token: :status_running}
  def chrome(:status_streaming), do: %__MODULE__{token: :status_streaming}
  def chrome(:status_queued), do: %__MODULE__{token: :status_queued}
  def chrome(:status_waiting_question), do: %__MODULE__{token: :status_waiting_question}
  def chrome(:status_waiting_approval), do: %__MODULE__{token: :status_waiting_approval}
  def chrome(:status_paused), do: %__MODULE__{token: :status_paused}
  def chrome(:status_retrying), do: %__MODULE__{token: :status_retrying}
  def chrome(:status_done), do: %__MODULE__{token: :status_done}
  def chrome(:status_failed), do: %__MODULE__{token: :status_failed}
  def chrome(:status_stopped), do: %__MODULE__{token: :status_stopped}
  def chrome(:status_interrupted), do: %__MODULE__{token: :status_interrupted}
  def chrome(:status_stale), do: %__MODULE__{token: :status_stale}
  def chrome(:status_resyncing), do: %__MODULE__{token: :status_resyncing}
  def chrome(:status_disconnected), do: %__MODULE__{token: :status_disconnected}
  def chrome(:status_superseded), do: %__MODULE__{token: :status_superseded}
  def chrome(:status_mutation_pending), do: %__MODULE__{token: :status_mutation_pending}
  def chrome(:swarmcode_wordmark), do: %__MODULE__{token: :swarmcode_wordmark}
  def chrome(:workspace_label), do: %__MODULE__{token: :workspace_label}
  def chrome(:nav_conversation), do: %__MODULE__{token: :nav_conversation}
  def chrome(:nav_activity), do: %__MODULE__{token: :nav_activity}
  def chrome(:nav_workflows), do: %__MODULE__{token: :nav_workflows}
  def chrome(:nav_research), do: %__MODULE__{token: :nav_research}
  def chrome(:nav_memory), do: %__MODULE__{token: :nav_memory}
  def chrome(:runs_label), do: %__MODULE__{token: :runs_label}
  def chrome(:glyph_selected), do: %__MODULE__{token: :glyph_selected}
  def chrome(:glyph_inactive), do: %__MODULE__{token: :glyph_inactive}
  def chrome(:glyph_workflows), do: %__MODULE__{token: :glyph_workflows}
  def chrome(:glyph_research), do: %__MODULE__{token: :glyph_research}
  def chrome(:glyph_memory), do: %__MODULE__{token: :glyph_memory}
  def chrome(:glyph_changes), do: %__MODULE__{token: :glyph_changes}
  def chrome(:live_run_label), do: %__MODULE__{token: :live_run_label}
  def chrome(:agents_label), do: %__MODULE__{token: :agents_label}
  def chrome(:you_label), do: %__MODULE__{token: :you_label}
  def chrome(:assistant_label), do: %__MODULE__{token: :assistant_label}
  def chrome(:tool_label), do: %__MODULE__{token: :tool_label}
  def chrome(:system_label), do: %__MODULE__{token: :system_label}
  def chrome(:gap_hairline), do: %__MODULE__{token: :gap_hairline}
  def chrome(:composer_gutter), do: %__MODULE__{token: :composer_gutter}
  def chrome(:pipeline_arrow), do: %__MODULE__{token: :pipeline_arrow}
  def chrome(:persistent_objective), do: %__MODULE__{token: :persistent_objective}
  def chrome(:plan_approve), do: %__MODULE__{token: :plan_approve}
  def chrome(:plan_revise), do: %__MODULE__{token: :plan_revise}
  def chrome(:plan_decline), do: %__MODULE__{token: :plan_decline}
  def chrome(:plan_done), do: %__MODULE__{token: :plan_done}
  def chrome(:plan_steps_label), do: %__MODULE__{token: :plan_steps_label}
  def chrome(:glyph_selected_ascii), do: %__MODULE__{token: :glyph_selected_ascii}
  def chrome(:glyph_inactive_ascii), do: %__MODULE__{token: :glyph_inactive_ascii}
  def chrome(:glyph_workflows_ascii), do: %__MODULE__{token: :glyph_workflows_ascii}
  def chrome(:glyph_research_ascii), do: %__MODULE__{token: :glyph_research_ascii}
  def chrome(:glyph_memory_ascii), do: %__MODULE__{token: :glyph_memory_ascii}
  def chrome(:glyph_changes_ascii), do: %__MODULE__{token: :glyph_changes_ascii}
  def chrome(:composer_gutter_ascii), do: %__MODULE__{token: :composer_gutter_ascii}
  def chrome(:pipeline_arrow_ascii), do: %__MODULE__{token: :pipeline_arrow_ascii}
  def chrome(:plan_done_ascii), do: %__MODULE__{token: :plan_done_ascii}
  def chrome(:glyph_failed), do: %__MODULE__{token: :glyph_failed}
  def chrome(:glyph_failed_ascii), do: %__MODULE__{token: :glyph_failed_ascii}
  def chrome(:stripe), do: %__MODULE__{token: :stripe}
  def chrome(:stripe_ascii), do: %__MODULE__{token: :stripe_ascii}
  def chrome(:stripe_off), do: %__MODULE__{token: :stripe_off}
  def chrome(:stripe_off_ascii), do: %__MODULE__{token: :stripe_off_ascii}
  # pass71 V1 (R3): the thin rail. `▏` at the rich tier; below it a one-cell
  # gap, since every thin bar that is one cell under both policies is missing
  # from common terminal fonts; `|` in ASCII.
  def chrome(:rail), do: %__MODULE__{token: :rail}
  def chrome(:rail_gap), do: %__MODULE__{token: :rail_gap}
  def chrome(:rail_ascii), do: %__MODULE__{token: :rail_ascii}
  def chrome(:corner_tl), do: %__MODULE__{token: :corner_tl}
  def chrome(:corner_tl_ascii), do: %__MODULE__{token: :corner_tl_ascii}
  def chrome(:corner_tr), do: %__MODULE__{token: :corner_tr}
  def chrome(:corner_tr_ascii), do: %__MODULE__{token: :corner_tr_ascii}
  def chrome(:corner_bl), do: %__MODULE__{token: :corner_bl}
  def chrome(:corner_bl_ascii), do: %__MODULE__{token: :corner_bl_ascii}
  def chrome(:corner_br), do: %__MODULE__{token: :corner_br}
  def chrome(:corner_br_ascii), do: %__MODULE__{token: :corner_br_ascii}
  def chrome(:seg_on), do: %__MODULE__{token: :seg_on}
  def chrome(:seg_on_ascii), do: %__MODULE__{token: :seg_on_ascii}
  def chrome(:seg_off), do: %__MODULE__{token: :seg_off}
  def chrome(:seg_off_ascii), do: %__MODULE__{token: :seg_off_ascii}
  def chrome(:rule), do: %__MODULE__{token: :rule}
  def chrome(:rule_ascii), do: %__MODULE__{token: :rule_ascii}
  def chrome(:eighth_1), do: %__MODULE__{token: :eighth_1}
  def chrome(:eighth_2), do: %__MODULE__{token: :eighth_2}
  def chrome(:eighth_3), do: %__MODULE__{token: :eighth_3}
  def chrome(:eighth_4), do: %__MODULE__{token: :eighth_4}
  def chrome(:eighth_5), do: %__MODULE__{token: :eighth_5}
  def chrome(:eighth_6), do: %__MODULE__{token: :eighth_6}
  def chrome(:eighth_7), do: %__MODULE__{token: :eighth_7}
  def chrome(:block_full), do: %__MODULE__{token: :block_full}
  def chrome(:half_lower), do: %__MODULE__{token: :half_lower}
  def chrome(:half_upper), do: %__MODULE__{token: :half_upper}
  def chrome(:vert_1), do: %__MODULE__{token: :vert_1}
  def chrome(:vert_2), do: %__MODULE__{token: :vert_2}
  def chrome(:vert_3), do: %__MODULE__{token: :vert_3}
  def chrome(:vert_4), do: %__MODULE__{token: :vert_4}
  def chrome(:vert_5), do: %__MODULE__{token: :vert_5}
  def chrome(:vert_6), do: %__MODULE__{token: :vert_6}
  def chrome(:vert_7), do: %__MODULE__{token: :vert_7}
  def chrome(:dash_rule), do: %__MODULE__{token: :dash_rule}
  def chrome(:copy_mark), do: %__MODULE__{token: :copy_mark}
  def chrome(:copy_mark_ascii), do: %__MODULE__{token: :copy_mark_ascii}
  def chrome(:ops_mark), do: %__MODULE__{token: :ops_mark}
  def chrome(:ops_mark_ascii), do: %__MODULE__{token: :ops_mark_ascii}
  def chrome(:command_mark), do: %__MODULE__{token: :command_mark}
  def chrome(:command_mark_ascii), do: %__MODULE__{token: :command_mark_ascii}
  def chrome(:dot_small), do: %__MODULE__{token: :dot_small}
  def chrome(:dot_small_ascii), do: %__MODULE__{token: :dot_small_ascii}
  def chrome(:dot), do: %__MODULE__{token: :dot}
  def chrome(:dot_ascii), do: %__MODULE__{token: :dot_ascii}
  def chrome(:agent_lead), do: %__MODULE__{token: :agent_lead}
  def chrome(:agent_lead_ascii), do: %__MODULE__{token: :agent_lead_ascii}
  def chrome(:agent_sub), do: %__MODULE__{token: :agent_sub}
  def chrome(:agent_sub_ascii), do: %__MODULE__{token: :agent_sub_ascii}
  def chrome(:assistant_mark), do: %__MODULE__{token: :assistant_mark}
  def chrome(:assistant_mark_ascii), do: %__MODULE__{token: :assistant_mark_ascii}
  def chrome(:kind_swarm_mark), do: %__MODULE__{token: :kind_swarm_mark}
  def chrome(:kind_swarm_mark_ascii), do: %__MODULE__{token: :kind_swarm_mark_ascii}
  def chrome(:kind_consensus_mark), do: %__MODULE__{token: :kind_consensus_mark}
  def chrome(:kind_consensus_mark_ascii), do: %__MODULE__{token: :kind_consensus_mark_ascii}
  def chrome(:kind_plan), do: %__MODULE__{token: :kind_plan}
  def chrome(:kind_plan_ascii), do: %__MODULE__{token: :kind_plan_ascii}
  def chrome(:close_mark), do: %__MODULE__{token: :close_mark}
  def chrome(:close_mark_ascii), do: %__MODULE__{token: :close_mark_ascii}
  def chrome(:settings_mark), do: %__MODULE__{token: :settings_mark}
  def chrome(:settings_mark_ascii), do: %__MODULE__{token: :settings_mark_ascii}
  def chrome(:logo_mark), do: %__MODULE__{token: :logo_mark}
  def chrome(:logo_mark_ascii), do: %__MODULE__{token: :logo_mark_ascii}
  def chrome(:search_mark), do: %__MODULE__{token: :search_mark}
  def chrome(:search_mark_ascii), do: %__MODULE__{token: :search_mark_ascii}
  def chrome(:branch_mark), do: %__MODULE__{token: :branch_mark}
  def chrome(:branch_mark_ascii), do: %__MODULE__{token: :branch_mark_ascii}
  def chrome(:retry_mark), do: %__MODULE__{token: :retry_mark}
  def chrome(:retry_mark_ascii), do: %__MODULE__{token: :retry_mark_ascii}
  def chrome(:enter_key), do: %__MODULE__{token: :enter_key}
  def chrome(:enter_key_ascii), do: %__MODULE__{token: :enter_key_ascii}
  def chrome(:check_mark), do: %__MODULE__{token: :check_mark}
  def chrome(:check_mark_ascii), do: %__MODULE__{token: :check_mark_ascii}
  def chrome(:chevron), do: %__MODULE__{token: :chevron}
  def chrome(:chevron_ascii), do: %__MODULE__{token: :chevron_ascii}
  def chrome(:write_mark), do: %__MODULE__{token: :write_mark}
  def chrome(:write_mark_ascii), do: %__MODULE__{token: :write_mark_ascii}
  def chrome(:clock_mark), do: %__MODULE__{token: :clock_mark}
  def chrome(:clock_mark_ascii), do: %__MODULE__{token: :clock_mark_ascii}
  def chrome(:effort_mark), do: %__MODULE__{token: :effort_mark}
  def chrome(:effort_mark_ascii), do: %__MODULE__{token: :effort_mark_ascii}
  def chrome(:shield_mark), do: %__MODULE__{token: :shield_mark}
  def chrome(:shield_mark_ascii), do: %__MODULE__{token: :shield_mark_ascii}
  def chrome(:usage_mark), do: %__MODULE__{token: :usage_mark}

  # The go-to popup's which-key rows: fixed chrome, one token each.
  def chrome(:jump_title), do: %__MODULE__{token: :jump_title}
  def chrome(:jump_top), do: %__MODULE__{token: :jump_top}
  def chrome(:jump_bottom), do: %__MODULE__{token: :jump_bottom}
  def chrome(:jump_next_run), do: %__MODULE__{token: :jump_next_run}
  def chrome(:jump_previous_run), do: %__MODULE__{token: :jump_previous_run}
  def chrome(:usage_mark_ascii), do: %__MODULE__{token: :usage_mark_ascii}

  # The hive and transcript glyphs of the north star: one cell under both width
  # policies, each with a pure-ASCII twin chosen by Projector.Support.glyph/2.
  def chrome(:hex_full), do: %__MODULE__{token: :hex_full}
  def chrome(:hex_full_ascii), do: %__MODULE__{token: :hex_full_ascii}
  def chrome(:hex_empty), do: %__MODULE__{token: :hex_empty}
  def chrome(:hex_empty_ascii), do: %__MODULE__{token: :hex_empty_ascii}
  def chrome(:judge), do: %__MODULE__{token: :judge}
  def chrome(:judge_ascii), do: %__MODULE__{token: :judge_ascii}
  def chrome(:caret), do: %__MODULE__{token: :caret}
  def chrome(:caret_ascii), do: %__MODULE__{token: :caret_ascii}
  def chrome(:collapsed), do: %__MODULE__{token: :collapsed}
  def chrome(:collapsed_ascii), do: %__MODULE__{token: :collapsed_ascii}
  def chrome(:expanded), do: %__MODULE__{token: :expanded}
  def chrome(:expanded_ascii), do: %__MODULE__{token: :expanded_ascii}
  def chrome(:check), do: %__MODULE__{token: :check}
  def chrome(:check_ascii), do: %__MODULE__{token: :check_ascii}
  def chrome(:fail), do: %__MODULE__{token: :fail}
  def chrome(:fail_ascii), do: %__MODULE__{token: :fail_ascii}
  def chrome(:gauge_on), do: %__MODULE__{token: :gauge_on}
  def chrome(:gauge_on_ascii), do: %__MODULE__{token: :gauge_on_ascii}
  def chrome(:gauge_off), do: %__MODULE__{token: :gauge_off}
  def chrome(:gauge_off_ascii), do: %__MODULE__{token: :gauge_off_ascii}
  def chrome(:waiting), do: %__MODULE__{token: :waiting}
  def chrome(:waiting_ascii), do: %__MODULE__{token: :waiting_ascii}

  # A braille cell is 2x4 addressable dots. Carrying the bit pattern rather than
  # 256 separate tokens keeps the catalogue closed: the value is provably inside
  # U+2800..U+28FF for every accepted input.
  def chrome({:braille, bits}) when is_integer(bits) and bits in 0..255,
    do: %__MODULE__{token: {:braille, bits}}

  def value(%{__struct__: __MODULE__, token: :full_detail} = text) when map_size(text) == 2,
    do: "Full text"

  def value(%{__struct__: __MODULE__, token: :next_page} = text) when map_size(text) == 2,
    do: "Next page"

  def value(%{__struct__: __MODULE__, token: :previous_page} = text) when map_size(text) == 2,
    do: "Previous page"

  def value(%{__struct__: __MODULE__, token: :no_results} = text) when map_size(text) == 2,
    do: "NO RESULTS"

  def value(%{__struct__: __MODULE__, token: :confirm_stop} = text) when map_size(text) == 2,
    do: "Confirm Stop? Cancel keeps this run or agent active."

  def value(%{__struct__: __MODULE__, token: :steer} = text) when map_size(text) == 2, do: "Steer"

  def value(%{__struct__: __MODULE__, token: :mark_seen} = text) when map_size(text) == 2,
    do: "Mark read"

  def value(%{__struct__: __MODULE__, token: :line_break} = text) when map_size(text) == 2,
    do: "\n"

  def value(%{__struct__: __MODULE__, token: :submit} = text) when map_size(text) == 2,
    do: "Submit"

  def value(%{__struct__: __MODULE__, token: :text_limit} = text) when map_size(text) == 2,
    do: "TEXT LIMIT EXCEEDED"

  def value(%{__struct__: __MODULE__, token: :title} = text) when map_size(text) == 2, do: "Build"

  def value(%{__struct__: __MODULE__, token: :fake_banner_compact} = text)
      when map_size(text) == 2,
      do: "FAKE — NO USER DATA"

  def value(%{__struct__: __MODULE__, token: :live_banner} = text) when map_size(text) == 2,
    do: "LIVE · UNSAVED"

  def value(%{__struct__: __MODULE__, token: :persisted_banner} = text)
      when map_size(text) == 2,
      do: "SAVED · DEV"

  def value(%{__struct__: __MODULE__, token: :build_mode} = text) when map_size(text) == 2,
    do: "Build"

  def value(%{__struct__: __MODULE__, token: :navigator} = text) when map_size(text) == 2,
    do: "Navigator"

  def value(%{__struct__: __MODULE__, token: :inspector} = text) when map_size(text) == 2,
    do: "Inspector"

  def value(%{__struct__: __MODULE__, token: :composer} = text) when map_size(text) == 2,
    do: "Composer · Build"

  def value(%{__struct__: __MODULE__, token: :activity} = text) when map_size(text) == 2,
    do: "Activity"

  def value(%{__struct__: __MODULE__, token: :status} = text) when map_size(text) == 2,
    do: "Status"

  def value(%{__struct__: __MODULE__, token: :resize_help} = text) when map_size(text) == 2,
    do: "Resize help"

  def value(%{__struct__: __MODULE__, token: :plain_exit} = text) when map_size(text) == 2,
    do: "Exit; rerun with --plain"

  def value(%{__struct__: __MODULE__, token: :unsent_changes} = text) when map_size(text) == 2,
    do: "UNSENT CHANGES"

  def value(%{__struct__: __MODULE__, token: :cancel_exit} = text) when map_size(text) == 2,
    do: "Esc CANCEL"

  def value(%{__struct__: __MODULE__, token: :confirm_exit} = text) when map_size(text) == 2,
    do: "X CONFIRM EXIT"

  def value(%{__struct__: __MODULE__, token: :help_key} = text) when map_size(text) == 2,
    do: "? HELP"

  def value(%{__struct__: __MODULE__, token: :detach_key} = text) when map_size(text) == 2,
    do: "q DETACH"

  def value(%{__struct__: __MODULE__, token: :plain_key} = text) when map_size(text) == 2,
    do: "P EXIT; RERUN --plain"

  def value(%{__struct__: __MODULE__, token: :back_close_help} = text) when map_size(text) == 2,
    do: "Back / Close / Help"

  def value(%{__struct__: __MODULE__, token: :read_only_resize} = text) when map_size(text) == 2,
    do: "Read-only at this size; resize to act"

  def value(%{__struct__: __MODULE__, token: :needs} = text) when map_size(text) == 2, do: "NEEDS"

  def value(%{__struct__: __MODULE__, token: :target_main} = text) when map_size(text) == 2,
    do: "Target: Main"

  def value(%{__struct__: __MODULE__, token: :validation_none} = text) when map_size(text) == 2,
    do: "Validation: none"

  def value(%{__struct__: __MODULE__, token: :focus_label} = text) when map_size(text) == 2,
    do: "Focus: "

  def value(%{__struct__: __MODULE__, token: :inspect} = text) when map_size(text) == 2,
    do: "Inspect"

  def value(%{__struct__: __MODULE__, token: :pause} = text) when map_size(text) == 2, do: "Pause"

  def value(%{__struct__: __MODULE__, token: :continue} = text) when map_size(text) == 2,
    do: "Continue"

  def value(%{__struct__: __MODULE__, token: :send} = text) when map_size(text) == 2, do: "Send"
  def value(%{__struct__: __MODULE__, token: :queue} = text) when map_size(text) == 2, do: "Queue"

  def value(%{__struct__: __MODULE__, token: :superseded_child} = text) when map_size(text) == 2,
    do: "Launched by a superseded turn"

  def value(%{__struct__: __MODULE__, token: :research_depth} = text) when map_size(text) == 2,
    do: "Research: Ultra (4x10)"

  def value(%{__struct__: __MODULE__, token: :representative_only} = text)
      when map_size(text) == 2,
      do: "Static representative evidence"

  def value(%{__struct__: __MODULE__, token: :consensus_docket} = text) when map_size(text) == 2,
    do: "Consensus docket"

  def value(%{__struct__: __MODULE__, token: :consensus_ledger} = text) when map_size(text) == 2,
    do: "Consensus ledger"

  def value(%{__struct__: __MODULE__, token: :research_report} = text) when map_size(text) == 2,
    do: "Research report"

  def value(%{__struct__: __MODULE__, token: :sources} = text) when map_size(text) == 2,
    do: "Sources"

  def value(%{__struct__: __MODULE__, token: :diagnostics} = text) when map_size(text) == 2,
    do: "Diagnostics"

  def value(%{__struct__: __MODULE__, token: :loading_before} = text) when map_size(text) == 2,
    do: "Loading earlier items"

  def value(%{__struct__: __MODULE__, token: :loading_after} = text) when map_size(text) == 2,
    do: "Loading later items"

  def value(%{__struct__: __MODULE__, token: :page_error} = text) when map_size(text) == 2,
    do: "Page error — Retry via Help"

  def value(%{__struct__: __MODULE__, token: :accepted} = text) when map_size(text) == 2,
    do: "Accepted"

  def value(%{__struct__: __MODULE__, token: :needs_input} = text) when map_size(text) == 2,
    do: "Needs input"

  def value(%{__struct__: __MODULE__, token: :rejected} = text) when map_size(text) == 2,
    do: "Rejected"

  def value(%{__struct__: __MODULE__, token: :deadline_exceeded} = text) when map_size(text) == 2,
    do: "Deadline exceeded"

  def value(%{__struct__: __MODULE__, token: :outcome_unknown} = text) when map_size(text) == 2,
    do: "Outcome unknown"

  def value(%{__struct__: __MODULE__, token: :revision_conflict} = text) when map_size(text) == 2,
    do: "Revision conflict"

  def value(%{__struct__: __MODULE__, token: :fake_banner} = text) when map_size(text) == 2,
    do: "FAKE DEMO — NO USER DATA"

  def value(%{__struct__: __MODULE__, token: :empty} = text) when map_size(text) == 2, do: ""
  def value(%{__struct__: __MODULE__, token: :main} = text) when map_size(text) == 2, do: "Main"
  def value(%{__struct__: __MODULE__, token: :help} = text) when map_size(text) == 2, do: "Help"

  def value(%{__struct__: __MODULE__, token: :detach} = text) when map_size(text) == 2,
    do: "Detach"

  def value(%{__struct__: __MODULE__, token: :plain} = text) when map_size(text) == 2, do: "Plain"

  def value(%{__struct__: __MODULE__, token: :focus_marker} = text) when map_size(text) == 2,
    do: "FOCUS >"

  def value(%{__struct__: __MODULE__, token: :selection_marker} = text) when map_size(text) == 2,
    do: "SELECTED >"

  def value(%{__struct__: __MODULE__, token: :disabled_marker} = text) when map_size(text) == 2,
    do: "[DISABLED]"

  def value(%{__struct__: __MODULE__, token: :stale_marker} = text) when map_size(text) == 2,
    do: "[STALE]"

  def value(%{__struct__: __MODULE__, token: :accent_marker} = text) when map_size(text) == 2,
    do: "RUNNING"

  def value(%{__struct__: __MODULE__, token: :success_marker} = text) when map_size(text) == 2,
    do: "OK"

  def value(%{__struct__: __MODULE__, token: :warning_marker} = text) when map_size(text) == 2,
    do: "! WAITING"

  def value(%{__struct__: __MODULE__, token: :error_marker} = text) when map_size(text) == 2,
    do: "ERROR"

  def value(%{__struct__: __MODULE__, token: :info_marker} = text) when map_size(text) == 2,
    do: "[INFO]"

  def value(%{__struct__: __MODULE__, token: :run_assistant} = text) when map_size(text) == 2,
    do: "A"

  def value(%{__struct__: __MODULE__, token: :run_goal} = text) when map_size(text) == 2, do: "G"
  def value(%{__struct__: __MODULE__, token: :run_swarm} = text) when map_size(text) == 2, do: "S"

  def value(%{__struct__: __MODULE__, token: :run_workflow} = text) when map_size(text) == 2,
    do: "W"

  def value(%{__struct__: __MODULE__, token: :run_research} = text) when map_size(text) == 2,
    do: "R"

  def value(%{__struct__: __MODULE__, token: :run_consensus_judge} = text)
      when map_size(text) == 2,
      do: "C"

  def value(%{__struct__: __MODULE__, token: :run_ultra} = text) when map_size(text) == 2, do: "U"

  def value(%{__struct__: __MODULE__, token: :agent_lane_1} = text) when map_size(text) == 2,
    do: "A1"

  def value(%{__struct__: __MODULE__, token: :agent_lane_2} = text) when map_size(text) == 2,
    do: "A2"

  def value(%{__struct__: __MODULE__, token: :agent_lane_3} = text) when map_size(text) == 2,
    do: "A3"

  def value(%{__struct__: __MODULE__, token: :agent_lane_4} = text) when map_size(text) == 2,
    do: "A4"

  def value(%{__struct__: __MODULE__, token: :agent_lane_5} = text) when map_size(text) == 2,
    do: "A5"

  def value(%{__struct__: __MODULE__, token: :approve} = text) when map_size(text) == 2,
    do: "Approve"

  def value(%{__struct__: __MODULE__, token: :deny} = text) when map_size(text) == 2, do: "Deny"

  def value(%{__struct__: __MODULE__, token: :always_allow} = text) when map_size(text) == 2,
    do: "Always allow"

  def value(%{__struct__: __MODULE__, token: :retry} = text) when map_size(text) == 2, do: "Retry"

  def value(%{__struct__: __MODULE__, token: :resume} = text) when map_size(text) == 2,
    do: "Resume"

  def value(%{__struct__: __MODULE__, token: :stop} = text) when map_size(text) == 2, do: "Stop"

  def value(%{__struct__: __MODULE__, token: :cancel} = text) when map_size(text) == 2,
    do: "Cancel"

  def value(%{__struct__: __MODULE__, token: :confirm} = text) when map_size(text) == 2,
    do: "Confirm"

  def value(%{__struct__: __MODULE__, token: :retry_available} = text) when map_size(text) == 2,
    do: " — RETRY AVAILABLE"

  def value(%{__struct__: __MODULE__, token: :resume_available} = text) when map_size(text) == 2,
    do: " — RESUME AVAILABLE"

  def value(%{__struct__: __MODULE__, token: :status_connecting} = text) when map_size(text) == 2,
    do: "CONNECTING"

  def value(%{__struct__: __MODULE__, token: :status_empty} = text) when map_size(text) == 2,
    do: "EMPTY"

  def value(%{__struct__: __MODULE__, token: :status_loading} = text) when map_size(text) == 2,
    do: "LOADING"

  def value(%{__struct__: __MODULE__, token: :status_running} = text) when map_size(text) == 2,
    do: "RUNNING"

  def value(%{__struct__: __MODULE__, token: :status_streaming} = text) when map_size(text) == 2,
    do: "STREAMING"

  def value(%{__struct__: __MODULE__, token: :status_queued} = text) when map_size(text) == 2,
    do: "QUEUED"

  def value(%{__struct__: __MODULE__, token: :status_waiting_question} = text)
      when map_size(text) == 2,
      do: "NEEDS ANSWER"

  def value(%{__struct__: __MODULE__, token: :status_waiting_approval} = text)
      when map_size(text) == 2,
      do: "NEEDS APPROVAL"

  def value(%{__struct__: __MODULE__, token: :status_paused} = text) when map_size(text) == 2,
    do: "PAUSED"

  def value(%{__struct__: __MODULE__, token: :status_retrying} = text) when map_size(text) == 2,
    do: "RETRYING"

  def value(%{__struct__: __MODULE__, token: :status_done} = text) when map_size(text) == 2,
    do: "DONE"

  def value(%{__struct__: __MODULE__, token: :status_failed} = text) when map_size(text) == 2,
    do: "FAILED"

  def value(%{__struct__: __MODULE__, token: :status_stopped} = text) when map_size(text) == 2,
    do: "STOPPED"

  def value(%{__struct__: __MODULE__, token: :status_interrupted} = text)
      when map_size(text) == 2,
      do: "INTERRUPTED"

  def value(%{__struct__: __MODULE__, token: :status_stale} = text) when map_size(text) == 2,
    do: "STALE"

  def value(%{__struct__: __MODULE__, token: :status_resyncing} = text) when map_size(text) == 2,
    do: "RESYNCING"

  def value(%{__struct__: __MODULE__, token: :status_disconnected} = text)
      when map_size(text) == 2,
      do: "DISCONNECTED"

  def value(%{__struct__: __MODULE__, token: :status_superseded} = text) when map_size(text) == 2,
    do: "SUPERSEDED"

  def value(%{__struct__: __MODULE__, token: :status_mutation_pending} = text)
      when map_size(text) == 2,
      do: "PENDING"

  def value(%{__struct__: __MODULE__, token: :swarmcode_wordmark} = text)
      when map_size(text) == 2,
      do: "SwarmCode"

  def value(%{__struct__: __MODULE__, token: :workspace_label} = text) when map_size(text) == 2,
    do: "WORKSPACE"

  def value(%{__struct__: __MODULE__, token: :nav_conversation} = text) when map_size(text) == 2,
    do: "Conversation"

  def value(%{__struct__: __MODULE__, token: :nav_activity} = text) when map_size(text) == 2,
    do: "Activity"

  def value(%{__struct__: __MODULE__, token: :nav_workflows} = text) when map_size(text) == 2,
    do: "Workflows"

  def value(%{__struct__: __MODULE__, token: :nav_research} = text) when map_size(text) == 2,
    do: "Research"

  def value(%{__struct__: __MODULE__, token: :nav_memory} = text) when map_size(text) == 2,
    do: "Memory"

  def value(%{__struct__: __MODULE__, token: :runs_label} = text) when map_size(text) == 2,
    do: "RUNS"

  def value(%{__struct__: __MODULE__, token: :glyph_selected} = text) when map_size(text) == 2,
    do: "◉"

  def value(%{__struct__: __MODULE__, token: :glyph_inactive} = text) when map_size(text) == 2,
    do: "◌"

  def value(%{__struct__: __MODULE__, token: :glyph_workflows} = text) when map_size(text) == 2,
    do: "⧉"

  def value(%{__struct__: __MODULE__, token: :glyph_research} = text) when map_size(text) == 2,
    do: "⌁"

  def value(%{__struct__: __MODULE__, token: :glyph_memory} = text) when map_size(text) == 2,
    do: "⌘"

  def value(%{__struct__: __MODULE__, token: :glyph_changes} = text) when map_size(text) == 2,
    do: "⬡"

  def value(%{__struct__: __MODULE__, token: :live_run_label} = text) when map_size(text) == 2,
    do: "LIVE RUN"

  def value(%{__struct__: __MODULE__, token: :agents_label} = text) when map_size(text) == 2,
    do: "AGENTS"

  def value(%{__struct__: __MODULE__, token: :you_label} = text) when map_size(text) == 2,
    do: "YOU"

  def value(%{__struct__: __MODULE__, token: :assistant_label} = text) when map_size(text) == 2,
    do: "assistant"

  def value(%{__struct__: __MODULE__, token: :tool_label} = text) when map_size(text) == 2,
    do: "tool"

  def value(%{__struct__: __MODULE__, token: :system_label} = text) when map_size(text) == 2,
    do: "system"

  def value(%{__struct__: __MODULE__, token: :gap_hairline} = text) when map_size(text) == 2,
    do: "╎"

  def value(%{__struct__: __MODULE__, token: :composer_gutter} = text) when map_size(text) == 2,
    do: "▐"

  def value(%{__struct__: __MODULE__, token: :pipeline_arrow} = text) when map_size(text) == 2,
    do: "❯"

  def value(%{__struct__: __MODULE__, token: :persistent_objective} = text)
      when map_size(text) == 2,
      do: "Persistent objective"

  def value(%{__struct__: __MODULE__, token: :plan_approve} = text) when map_size(text) == 2,
    do: "Approve"

  def value(%{__struct__: __MODULE__, token: :plan_revise} = text) when map_size(text) == 2,
    do: "Revise"

  def value(%{__struct__: __MODULE__, token: :plan_decline} = text) when map_size(text) == 2,
    do: "Decline"

  def value(%{__struct__: __MODULE__, token: :plan_done} = text) when map_size(text) == 2,
    do: "✓"

  def value(%{__struct__: __MODULE__, token: :plan_steps_label} = text) when map_size(text) == 2,
    do: "PLAN STEPS"

  def value(%{__struct__: __MODULE__, token: :glyph_selected_ascii} = text)
      when map_size(text) == 2,
      do: "*"

  def value(%{__struct__: __MODULE__, token: :glyph_inactive_ascii} = text)
      when map_size(text) == 2,
      do: "o"

  def value(%{__struct__: __MODULE__, token: :glyph_workflows_ascii} = text)
      when map_size(text) == 2,
      do: "#"

  def value(%{__struct__: __MODULE__, token: :glyph_research_ascii} = text)
      when map_size(text) == 2,
      do: "^"

  def value(%{__struct__: __MODULE__, token: :glyph_memory_ascii} = text)
      when map_size(text) == 2,
      do: "@"

  def value(%{__struct__: __MODULE__, token: :glyph_changes_ascii} = text)
      when map_size(text) == 2,
      do: "+"

  def value(%{__struct__: __MODULE__, token: :composer_gutter_ascii} = text)
      when map_size(text) == 2,
      do: ">"

  def value(%{__struct__: __MODULE__, token: :pipeline_arrow_ascii} = text)
      when map_size(text) == 2,
      do: ">"

  def value(%{__struct__: __MODULE__, token: :plan_done_ascii} = text) when map_size(text) == 2,
    do: "*"

  def value(%{__struct__: __MODULE__, token: :glyph_failed} = text) when map_size(text) == 2,
    do: "✗"

  def value(%{__struct__: __MODULE__, token: :glyph_failed_ascii} = text)
      when map_size(text) == 2,
      do: "x"

  # Rich tier glyphs (East Asian Ambiguous: one cell under :narrow only). Only
  # Projector.Support.glyph/2 hands these out, and only at the :rich tier.
  def value(%{__struct__: __MODULE__, token: :eighth_1} = text)
      when map_size(text) == 2,
      do: "▏"

  def value(%{__struct__: __MODULE__, token: :eighth_2} = text)
      when map_size(text) == 2,
      do: "▎"

  def value(%{__struct__: __MODULE__, token: :eighth_3} = text)
      when map_size(text) == 2,
      do: "▍"

  def value(%{__struct__: __MODULE__, token: :eighth_4} = text)
      when map_size(text) == 2,
      do: "▌"

  def value(%{__struct__: __MODULE__, token: :eighth_5} = text)
      when map_size(text) == 2,
      do: "▋"

  def value(%{__struct__: __MODULE__, token: :eighth_6} = text)
      when map_size(text) == 2,
      do: "▊"

  def value(%{__struct__: __MODULE__, token: :eighth_7} = text)
      when map_size(text) == 2,
      do: "▉"

  def value(%{__struct__: __MODULE__, token: :block_full} = text)
      when map_size(text) == 2,
      do: "█"

  def value(%{__struct__: __MODULE__, token: :half_lower} = text)
      when map_size(text) == 2,
      do: "▄"

  def value(%{__struct__: __MODULE__, token: :half_upper} = text)
      when map_size(text) == 2,
      do: "▀"

  def value(%{__struct__: __MODULE__, token: :vert_1} = text)
      when map_size(text) == 2,
      do: "▁"

  def value(%{__struct__: __MODULE__, token: :vert_2} = text)
      when map_size(text) == 2,
      do: "▂"

  def value(%{__struct__: __MODULE__, token: :vert_3} = text)
      when map_size(text) == 2,
      do: "▃"

  def value(%{__struct__: __MODULE__, token: :vert_4} = text)
      when map_size(text) == 2,
      do: "▄"

  def value(%{__struct__: __MODULE__, token: :vert_5} = text)
      when map_size(text) == 2,
      do: "▅"

  def value(%{__struct__: __MODULE__, token: :vert_6} = text)
      when map_size(text) == 2,
      do: "▆"

  def value(%{__struct__: __MODULE__, token: :vert_7} = text)
      when map_size(text) == 2,
      do: "▇"

  def value(%{__struct__: __MODULE__, token: :dash_rule} = text)
      when map_size(text) == 2,
      do: "┄"

  def value(%{__struct__: __MODULE__, token: :copy_mark} = text)
      when map_size(text) == 2,
      do: "⧉"

  def value(%{__struct__: __MODULE__, token: :copy_mark_ascii} = text)
      when map_size(text) == 2,
      do: "c"

  def value(%{__struct__: __MODULE__, token: :ops_mark} = text)
      when map_size(text) == 2,
      do: "≣"

  def value(%{__struct__: __MODULE__, token: :ops_mark_ascii} = text)
      when map_size(text) == 2,
      do: "="

  def value(%{__struct__: __MODULE__, token: :command_mark} = text)
      when map_size(text) == 2,
      do: "⌘"

  def value(%{__struct__: __MODULE__, token: :command_mark_ascii} = text)
      when map_size(text) == 2,
      do: "$"

  def value(%{__struct__: __MODULE__, token: :stripe} = text)
      when map_size(text) == 2,
      do: "▐"

  def value(%{__struct__: __MODULE__, token: :rail} = text)
      when map_size(text) == 2,
      do: "▏"

  def value(%{__struct__: __MODULE__, token: :rail_gap} = text)
      when map_size(text) == 2,
      do: " "

  def value(%{__struct__: __MODULE__, token: :rail_ascii} = text)
      when map_size(text) == 2,
      do: "|"

  def value(%{__struct__: __MODULE__, token: :stripe_ascii} = text)
      when map_size(text) == 2,
      do: "#"

  def value(%{__struct__: __MODULE__, token: :stripe_off} = text)
      when map_size(text) == 2,
      do: "▐"

  def value(%{__struct__: __MODULE__, token: :stripe_off_ascii} = text)
      when map_size(text) == 2,
      do: "-"

  def value(%{__struct__: __MODULE__, token: :corner_tl} = text)
      when map_size(text) == 2,
      do: "▗"

  def value(%{__struct__: __MODULE__, token: :corner_tl_ascii} = text)
      when map_size(text) == 2,
      do: " "

  def value(%{__struct__: __MODULE__, token: :corner_tr} = text)
      when map_size(text) == 2,
      do: "▖"

  def value(%{__struct__: __MODULE__, token: :corner_tr_ascii} = text)
      when map_size(text) == 2,
      do: " "

  def value(%{__struct__: __MODULE__, token: :corner_bl} = text)
      when map_size(text) == 2,
      do: "▝"

  def value(%{__struct__: __MODULE__, token: :corner_bl_ascii} = text)
      when map_size(text) == 2,
      do: " "

  def value(%{__struct__: __MODULE__, token: :corner_br} = text)
      when map_size(text) == 2,
      do: "▘"

  def value(%{__struct__: __MODULE__, token: :corner_br_ascii} = text)
      when map_size(text) == 2,
      do: " "

  def value(%{__struct__: __MODULE__, token: :seg_on} = text)
      when map_size(text) == 2,
      do: "▰"

  def value(%{__struct__: __MODULE__, token: :seg_on_ascii} = text)
      when map_size(text) == 2,
      do: "#"

  def value(%{__struct__: __MODULE__, token: :seg_off} = text)
      when map_size(text) == 2,
      do: "▱"

  def value(%{__struct__: __MODULE__, token: :seg_off_ascii} = text)
      when map_size(text) == 2,
      do: "-"

  def value(%{__struct__: __MODULE__, token: :rule} = text)
      when map_size(text) == 2,
      do: "▬"

  def value(%{__struct__: __MODULE__, token: :rule_ascii} = text)
      when map_size(text) == 2,
      do: "-"

  def value(%{__struct__: __MODULE__, token: :dot_small} = text)
      when map_size(text) == 2,
      do: "▪"

  def value(%{__struct__: __MODULE__, token: :dot_small_ascii} = text)
      when map_size(text) == 2,
      do: "-"

  def value(%{__struct__: __MODULE__, token: :dot} = text)
      when map_size(text) == 2,
      do: "⬤"

  def value(%{__struct__: __MODULE__, token: :dot_ascii} = text)
      when map_size(text) == 2,
      do: "*"

  def value(%{__struct__: __MODULE__, token: :agent_lead} = text)
      when map_size(text) == 2,
      do: "⬡"

  def value(%{__struct__: __MODULE__, token: :agent_lead_ascii} = text)
      when map_size(text) == 2,
      do: "o"

  def value(%{__struct__: __MODULE__, token: :agent_sub} = text)
      when map_size(text) == 2,
      do: "✦"

  def value(%{__struct__: __MODULE__, token: :agent_sub_ascii} = text)
      when map_size(text) == 2,
      do: "+"

  def value(%{__struct__: __MODULE__, token: :assistant_mark} = text)
      when map_size(text) == 2,
      do: "✳"

  def value(%{__struct__: __MODULE__, token: :assistant_mark_ascii} = text)
      when map_size(text) == 2,
      do: "*"

  def value(%{__struct__: __MODULE__, token: :kind_swarm_mark} = text)
      when map_size(text) == 2,
      do: "⋔"

  def value(%{__struct__: __MODULE__, token: :kind_swarm_mark_ascii} = text)
      when map_size(text) == 2,
      do: "S"

  def value(%{__struct__: __MODULE__, token: :kind_consensus_mark} = text)
      when map_size(text) == 2,
      do: "⚖"

  def value(%{__struct__: __MODULE__, token: :kind_consensus_mark_ascii} = text)
      when map_size(text) == 2,
      do: "C"

  def value(%{__struct__: __MODULE__, token: :kind_plan} = text)
      when map_size(text) == 2,
      do: "≣"

  def value(%{__struct__: __MODULE__, token: :kind_plan_ascii} = text)
      when map_size(text) == 2,
      do: "P"

  def value(%{__struct__: __MODULE__, token: :close_mark} = text)
      when map_size(text) == 2,
      do: "✕"

  def value(%{__struct__: __MODULE__, token: :close_mark_ascii} = text)
      when map_size(text) == 2,
      do: "x"

  def value(%{__struct__: __MODULE__, token: :settings_mark} = text)
      when map_size(text) == 2,
      do: "⚙"

  def value(%{__struct__: __MODULE__, token: :settings_mark_ascii} = text)
      when map_size(text) == 2,
      do: "*"

  def value(%{__struct__: __MODULE__, token: :logo_mark} = text)
      when map_size(text) == 2,
      do: "⬢"

  def value(%{__struct__: __MODULE__, token: :logo_mark_ascii} = text)
      when map_size(text) == 2,
      do: "#"

  def value(%{__struct__: __MODULE__, token: :search_mark} = text)
      when map_size(text) == 2,
      do: "⌕"

  def value(%{__struct__: __MODULE__, token: :search_mark_ascii} = text)
      when map_size(text) == 2,
      do: "/"

  def value(%{__struct__: __MODULE__, token: :branch_mark} = text)
      when map_size(text) == 2,
      do: "⎇"

  def value(%{__struct__: __MODULE__, token: :branch_mark_ascii} = text)
      when map_size(text) == 2,
      do: "Y"

  def value(%{__struct__: __MODULE__, token: :retry_mark} = text)
      when map_size(text) == 2,
      do: "↻"

  def value(%{__struct__: __MODULE__, token: :retry_mark_ascii} = text)
      when map_size(text) == 2,
      do: "r"

  def value(%{__struct__: __MODULE__, token: :enter_key} = text)
      when map_size(text) == 2,
      do: "↵"

  def value(%{__struct__: __MODULE__, token: :enter_key_ascii} = text)
      when map_size(text) == 2,
      do: "<"

  def value(%{__struct__: __MODULE__, token: :check_mark} = text)
      when map_size(text) == 2,
      do: "✓"

  def value(%{__struct__: __MODULE__, token: :check_mark_ascii} = text)
      when map_size(text) == 2,
      do: "v"

  def value(%{__struct__: __MODULE__, token: :chevron} = text)
      when map_size(text) == 2,
      do: "›"

  def value(%{__struct__: __MODULE__, token: :chevron_ascii} = text)
      when map_size(text) == 2,
      do: ">"

  def value(%{__struct__: __MODULE__, token: :write_mark} = text)
      when map_size(text) == 2,
      do: "✎"

  def value(%{__struct__: __MODULE__, token: :write_mark_ascii} = text)
      when map_size(text) == 2,
      do: "w"

  def value(%{__struct__: __MODULE__, token: :clock_mark} = text)
      when map_size(text) == 2,
      do: "◷"

  def value(%{__struct__: __MODULE__, token: :clock_mark_ascii} = text)
      when map_size(text) == 2,
      do: "t"

  def value(%{__struct__: __MODULE__, token: :effort_mark} = text)
      when map_size(text) == 2,
      do: "◕"

  def value(%{__struct__: __MODULE__, token: :effort_mark_ascii} = text)
      when map_size(text) == 2,
      do: "e"

  def value(%{__struct__: __MODULE__, token: :shield_mark} = text)
      when map_size(text) == 2,
      do: "❖"

  def value(%{__struct__: __MODULE__, token: :shield_mark_ascii} = text)
      when map_size(text) == 2,
      do: "!"

  def value(%{__struct__: __MODULE__, token: :usage_mark} = text)
      when map_size(text) == 2,
      do: "⌗"

  def value(%{__struct__: __MODULE__, token: :usage_mark_ascii} = text)
      when map_size(text) == 2,
      do: "#"

  # Block elements U+2580..U+258F (▍ ▇ ▁) are two cells under the :wide policy,
  # so the caret and the gauge use the one-cell rectangles U+25AC..U+25AE.
  def value(%{__struct__: __MODULE__, token: :hex_full} = text)
      when map_size(text) == 2,
      do: "⬢"

  def value(%{__struct__: __MODULE__, token: :hex_full_ascii} = text)
      when map_size(text) == 2,
      do: "o"

  def value(%{__struct__: __MODULE__, token: :hex_empty} = text)
      when map_size(text) == 2,
      do: "⬡"

  def value(%{__struct__: __MODULE__, token: :hex_empty_ascii} = text)
      when map_size(text) == 2,
      do: "."

  def value(%{__struct__: __MODULE__, token: :judge} = text)
      when map_size(text) == 2,
      do: "⚖"

  def value(%{__struct__: __MODULE__, token: :judge_ascii} = text)
      when map_size(text) == 2,
      do: "j"

  def value(%{__struct__: __MODULE__, token: :caret} = text)
      when map_size(text) == 2,
      do: "▮"

  def value(%{__struct__: __MODULE__, token: :caret_ascii} = text)
      when map_size(text) == 2,
      do: "|"

  def value(%{__struct__: __MODULE__, token: :collapsed} = text)
      when map_size(text) == 2,
      do: "▸"

  def value(%{__struct__: __MODULE__, token: :collapsed_ascii} = text)
      when map_size(text) == 2,
      do: ">"

  def value(%{__struct__: __MODULE__, token: :expanded} = text)
      when map_size(text) == 2,
      do: "▾"

  def value(%{__struct__: __MODULE__, token: :expanded_ascii} = text)
      when map_size(text) == 2,
      do: "v"

  def value(%{__struct__: __MODULE__, token: :check} = text)
      when map_size(text) == 2,
      do: "✓"

  def value(%{__struct__: __MODULE__, token: :check_ascii} = text)
      when map_size(text) == 2,
      do: "+"

  def value(%{__struct__: __MODULE__, token: :fail} = text)
      when map_size(text) == 2,
      do: "✕"

  def value(%{__struct__: __MODULE__, token: :fail_ascii} = text)
      when map_size(text) == 2,
      do: "x"

  def value(%{__struct__: __MODULE__, token: :gauge_on} = text)
      when map_size(text) == 2,
      do: "▬"

  def value(%{__struct__: __MODULE__, token: :gauge_on_ascii} = text)
      when map_size(text) == 2,
      do: "#"

  def value(%{__struct__: __MODULE__, token: :gauge_off} = text)
      when map_size(text) == 2,
      do: "▭"

  def value(%{__struct__: __MODULE__, token: :gauge_off_ascii} = text)
      when map_size(text) == 2,
      do: "-"

  def value(%{__struct__: __MODULE__, token: :waiting} = text)
      when map_size(text) == 2,
      do: "!"

  def value(%{__struct__: __MODULE__, token: :waiting_ascii} = text)
      when map_size(text) == 2,
      do: "!"

  def value(%{__struct__: __MODULE__, token: :jump_title} = text)
      when map_size(text) == 2,
      do: "Go to"

  def value(%{__struct__: __MODULE__, token: :jump_top} = text)
      when map_size(text) == 2,
      do: "g   Top"

  def value(%{__struct__: __MODULE__, token: :jump_bottom} = text)
      when map_size(text) == 2,
      do: "G   Bottom"

  def value(%{__struct__: __MODULE__, token: :jump_next_run} = text)
      when map_size(text) == 2,
      do: "t   Next run"

  def value(%{__struct__: __MODULE__, token: :jump_previous_run} = text)
      when map_size(text) == 2,
      do: "T   Previous run"

  def value(%{__struct__: __MODULE__, token: {:braille, bits}} = text)
      when map_size(text) == 2 and is_integer(bits) and bits in 0..255,
      do: <<0x2800 + bits::utf8>>

  def value(%{__struct__: __MODULE__, token: {:external, binary}} = text)
      when map_size(text) == 2 and is_binary(binary) do
    # Re-running the sanitizer must be an identity. In particular, raw control
    # bytes and standalone invisible characters cannot enter through a struct.
    limit = Limits.content().escaped_bytes

    if byte_size(binary) <= limit and sanitized_identity?(binary, limit),
      do: binary,
      else: raise(ArgumentError, "invalid external SafeText representation")
  end

  @spec external(binary(), Limits.t()) ::
          {:ok, t()} | {:error, :input_too_large | :escaped_output_too_large}
  def external(binary, %Limits{} = limits) when is_binary(binary) do
    validate_limits!(limits)

    if byte_size(binary) > limits.input_bytes do
      {:error, :input_too_large}
    else
      case sanitize(binary, limits.escaped_bytes, limits.tab_width, limits.ambiguous_width) do
        {:ok, output} -> {:ok, %__MODULE__{token: {:external, output}}}
        error -> error
      end
    end
  end

  @spec external_chunks(Enumerable.t(), Limits.t()) :: Enumerable.t()
  def external_chunks(chunks, %Limits{} = limits) do
    validate_limits!(limits)

    Stream.map([:field], fn :field ->
      chunks
      |> Enum.reduce_while({[], 0}, fn chunk, {acc, bytes} when is_binary(chunk) ->
        if byte_size(chunk) > limits.input_bytes - bytes,
          do: {:halt, {:error, :input_too_large}},
          else: {:cont, {if(chunk == "", do: acc, else: [chunk | acc]), bytes + byte_size(chunk)}}
      end)
      |> case do
        {:error, _} = error -> error
        {acc, _bytes} -> acc |> Enum.reverse() |> IO.iodata_to_binary() |> external(limits)
      end
    end)
  end

  @spec concat([t()]) :: t()
  def concat(texts) when is_list(texts) do
    {parts, _bytes} =
      Enum.reduce(texts, {[], 0}, fn text, {acc, bytes} ->
        part = value(text)
        total = bytes + byte_size(part)

        if total > Limits.content().escaped_bytes,
          do: raise(ArgumentError, "SafeText concatenation too large")

        {[part | acc], total}
      end)

    binary = parts |> Enum.reverse() |> IO.iodata_to_binary()
    safe = %__MODULE__{token: {:external, binary}}
    value(safe)
    safe
  end

  @spec number(non_neg_integer()) :: t()
  def number(number) when is_integer(number) and number >= 0 do
    binary = Integer.to_string(number)

    if byte_size(binary) > Limits.content().escaped_bytes,
      do: raise(ArgumentError, "SafeText number too large")

    %__MODULE__{token: {:external, binary}}
  end

  defp validate_limits!(limits) do
    unless Limits.valid?(limits), do: raise(ArgumentError, "invalid SafeText limits")
  end

  defp sanitized_identity?(binary, limit),
    do: sanitize(binary, limit, 8, :narrow) == {:ok, binary}

  defp sanitize(binary, limit, tabs, width) do
    binary
    |> repair_invalid_utf8()
    |> scan(limit, tabs, width, 0, [])
  end

  defp scan(<<>>, _remaining, _tabs, _width, _column, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}

  defp scan(binary, remaining, tabs, width, column, acc) do
    {grapheme, rest} = String.next_grapheme(binary)

    case sanitize_grapheme(grapheme, remaining, tabs, width, column) do
      {:ok, visible, remaining, next_column} ->
        scan(rest, remaining, tabs, width, next_column, [visible | acc])

      error ->
        error
    end
  end

  defp repair_invalid_utf8(binary) do
    case :unicode.characters_to_binary(binary, :utf8, :utf8) do
      ^binary ->
        binary

      {:error, valid, rest} ->
        {_, tail} = split_invalid_byte(rest)
        IO.iodata_to_binary([valid, "�", repair_invalid_utf8(tail)])

      {:incomplete, valid, rest} ->
        {_, tail} = split_invalid_byte(rest)
        IO.iodata_to_binary([valid, "�", repair_invalid_utf8(tail)])
    end
  end

  defp split_invalid_byte(<<byte, rest::binary>>), do: {byte, rest}
  defp split_invalid_byte(<<>>), do: {0, <<>>}

  defp sanitize_grapheme("\t", remaining, tabs, _width, column) do
    spaces = tabs - rem(column, tabs)

    if spaces > remaining,
      do: {:error, :escaped_output_too_large},
      else: {:ok, String.duplicate(" ", spaces), remaining - spaces, column + spaces}
  end

  defp sanitize_grapheme(grapheme, remaining, _tabs, width, column) do
    context = grapheme_context(grapheme)
    # Only source-bounded grapheme context is inspected ahead of time. The
    # expanded representation is produced one scalar/invalid byte at a time,
    # and no over-limit token is retained in the output iodata.
    case escape_scalars(grapheme, context, nil, remaining, []) do
      {:ok, parts, remaining} ->
        visible = parts |> Enum.reverse() |> IO.iodata_to_binary()

        next_column =
          case :binary.matches(visible, "\n") |> List.last() do
            nil ->
              column + Width.cells(visible, width)

            {offset, 1} ->
              Width.cells(
                binary_part(visible, offset + 1, byte_size(visible) - offset - 1),
                width
              )
          end

        {:ok, visible, remaining, next_column}

      error ->
        error
    end
  end

  defp grapheme_context(grapheme) do
    if String.valid?(grapheme) do
      cps = String.to_charlist(grapheme)
      base = hd(cps)

      %{
        combining: base != 0xFFFD and printable_base?(base),
        join: valid_emoji_join?(cps),
        keycap:
          cps in [[?#, 0xFE0F, 0x20E3], [?*, 0xFE0F, 0x20E3]] or
            (base in ?0..?9 and cps == [base, 0xFE0F, 0x20E3]),
        tags: valid_flag_tags?(cps)
      }
    else
      %{combining: false, join: false, keycap: false, tags: false}
    end
  end

  defp escape_scalars(<<>>, _context, _previous, remaining, acc), do: {:ok, acc, remaining}

  defp escape_scalars(<<cp::utf8, rest::binary>>, context, previous, remaining, acc) do
    token = scalar_token(cp, context, previous)
    append_scalar(token, rest, context, cp, remaining, acc)
  end

  defp escape_scalars(<<_byte, rest::binary>>, context, _previous, remaining, acc),
    do: append_scalar("�", rest, context, nil, remaining, acc)

  defp append_scalar(token, rest, context, previous, remaining, acc) do
    bytes = IO.iodata_length(token)

    if bytes > remaining,
      do: {:error, :escaped_output_too_large},
      else: escape_scalars(rest, context, previous, remaining - bytes, [token | acc])
  end

  defp scalar_token(cp, context, previous) do
    cond do
      cp == 10 ->
        "\n"

      cp < 32 or cp in 127..159 ->
        named(control_name(cp))

      name = invisible_name(cp) ->
        named(name <> " U+" <> hex(cp))

      cp == 0x200D and not context.join ->
        named("ZWJ U+200D")

      cp in 0xE0000..0xE007F and not context.tags ->
        named("TAG U+" <> hex(cp))

      variation?(cp) and not (context.keycap or valid_variation?(cp, previous)) ->
        named(variation_name(cp) <> " U+" <> hex(cp))

      mark?(cp) and not context.combining ->
        named("COMBINING U+" <> hex(cp))

      zero_width_untrusted?(cp, context) ->
        named("ZERO WIDTH U+" <> hex(cp))

      true ->
        <<cp::utf8>>
    end
  end

  defp zero_width_untrusted?(cp, context),
    do:
      Width.cells(<<cp::utf8>>, :narrow) == 0 and
        not mark?(cp) and cp != 0x200D and not variation?(cp) and
        not (context.tags and cp in 0xE0020..0xE007F)

  defp named(name), do: ["⟦", name, "⟧"]

  defp valid_flag_tags?([0x1F3F4 | tags]) do
    case Enum.reverse(tags) do
      [0xE007F | letters] when length(letters) in 2..6 ->
        Enum.all?(letters, &(&1 in 0xE0061..0xE007A))

      _ ->
        false
    end
  end

  defp valid_flag_tags?(_), do: false

  defp hex(cp), do: cp |> Integer.to_string(16) |> String.pad_leading(4, "0")
  # pass72 G14 (QA Q7): on OTP 28 a `~r` module attribute is compiled again
  # on every use, and this ran for every character of every frame (about a
  # third of the overlay's projection). No mark is below U+0300; the rest use
  # a regex compiled once per VM.
  defp mark?(cp) when cp < 0x300, do: false
  defp mark?(cp), do: Regex.match?(mark_regex(), <<cp::utf8>>)

  defp mark_regex do
    case :persistent_term.get({__MODULE__, :mark_regex}, nil) do
      nil ->
        regex = Regex.compile!(@mark_regex.source, @mark_regex.opts)
        :persistent_term.put({__MODULE__, :mark_regex}, regex)
        regex

      regex ->
        regex
    end
  end

  defp variation?(cp),
    do: cp in [0x180B, 0x180C, 0x180D, 0x180F] or cp in 0xFE00..0xFE0F or cp in 0xE0100..0xE01EF

  defp variation_name(0x180B), do: "FVS1"
  defp variation_name(0x180C), do: "FVS2"
  defp variation_name(0x180D), do: "FVS3"
  defp variation_name(0x180F), do: "FVS4"
  defp variation_name(0xFE0E), do: "VS15"
  defp variation_name(0xFE0F), do: "VS16"
  defp variation_name(_), do: "VS"
  defp valid_variation?(_cp, nil), do: false

  defp valid_variation?(cp, base), do: Variants.valid?(base, cp)

  defp printable_base?(cp),
    do:
      cp >= 32 and cp not in 127..159 and is_nil(invisible_name(cp)) and
        cp != 0x200D and not variation?(cp) and not mark?(cp) and
        Width.cells(<<cp::utf8>>, :narrow) > 0

  # Use the same pinned Unicode data as terminal measurement. Emoji
  # presentation sequences and default emoji cover the eligible bases; ASCII
  # keycaps are admitted only by the separately validated complete grapheme.
  defp emoji_base?(cp),
    do:
      cp not in [?#, ?*] and cp not in ?0..?9 and
        (Table.starts_emoji_presentation_seq?(cp) or
           elem(Table.width_info(cp, :narrow), 1) == 0x0005)

  defp valid_emoji_join?(cps) do
    parts = Enum.chunk_by(cps, &(&1 == 0x200D))

    length(parts) >= 3 and rem(length(parts), 2) == 1 and
      parts
      |> Enum.with_index()
      |> Enum.all?(fn
        {part, index} when rem(index, 2) == 1 ->
          part == [0x200D]

        {[base | tail], _} ->
          emoji_base?(base) and retained_emoji_tail?(tail, base)
      end)
  end

  defp retained_emoji_tail?([], _previous), do: true

  defp retained_emoji_tail?([cp | rest], previous) do
    retained =
      is_nil(invisible_name(cp)) and
        cond do
          variation?(cp) -> valid_variation?(cp, previous)
          mark?(cp) -> true
          cp in 0x1F3FB..0x1F3FF -> Table.emoji_modifier_base?(previous)
          true -> false
        end

    retained and retained_emoji_tail?(rest, cp)
  end

  defp control_name(0), do: "NUL"
  defp control_name(1), do: "SOH"
  defp control_name(2), do: "STX"
  defp control_name(3), do: "ETX"
  defp control_name(4), do: "EOT"
  defp control_name(5), do: "ENQ"
  defp control_name(6), do: "ACK"
  defp control_name(7), do: "BEL"
  defp control_name(8), do: "BS"
  defp control_name(9), do: "HT"
  defp control_name(10), do: "LF"
  defp control_name(11), do: "VT"
  defp control_name(12), do: "FF"
  defp control_name(13), do: "CR"
  defp control_name(14), do: "SO"
  defp control_name(15), do: "SI"
  defp control_name(16), do: "DLE"
  defp control_name(17), do: "DC1"
  defp control_name(18), do: "DC2"
  defp control_name(19), do: "DC3"
  defp control_name(20), do: "DC4"
  defp control_name(21), do: "NAK"
  defp control_name(22), do: "SYN"
  defp control_name(23), do: "ETB"
  defp control_name(24), do: "CAN"
  defp control_name(25), do: "EM"
  defp control_name(26), do: "SUB"
  defp control_name(27), do: "ESC"
  defp control_name(28), do: "FS"
  defp control_name(29), do: "GS"
  defp control_name(30), do: "RS"
  defp control_name(31), do: "US"
  defp control_name(127), do: "DEL"
  defp control_name(128), do: "PAD"
  defp control_name(129), do: "HOP"
  defp control_name(130), do: "BPH"
  defp control_name(131), do: "NBH"
  defp control_name(132), do: "IND"
  defp control_name(133), do: "NEL"
  defp control_name(134), do: "SSA"
  defp control_name(135), do: "ESA"
  defp control_name(136), do: "HTS"
  defp control_name(137), do: "HTJ"
  defp control_name(138), do: "VTS"
  defp control_name(139), do: "PLD"
  defp control_name(140), do: "PLU"
  defp control_name(141), do: "RI"
  defp control_name(142), do: "SS2"
  defp control_name(143), do: "SS3"
  defp control_name(144), do: "DCS"
  defp control_name(145), do: "PU1"
  defp control_name(146), do: "PU2"
  defp control_name(147), do: "STS"
  defp control_name(148), do: "CCH"
  defp control_name(149), do: "MW"
  defp control_name(150), do: "SPA"
  defp control_name(151), do: "EPA"
  defp control_name(152), do: "SOS"
  defp control_name(153), do: "SGCI"
  defp control_name(154), do: "SCI"
  defp control_name(155), do: "CSI"
  defp control_name(156), do: "ST"
  defp control_name(157), do: "OSC"
  defp control_name(158), do: "PM"
  defp control_name(159), do: "APC"
  defp invisible_name(0x034F), do: "CGJ"
  defp invisible_name(173), do: "SHY"
  defp invisible_name(1564), do: "ALM"
  defp invisible_name(6158), do: "MVS"
  defp invisible_name(8203), do: "ZWSP"
  defp invisible_name(8204), do: "ZWNJ"
  defp invisible_name(8206), do: "LRM"
  defp invisible_name(8207), do: "RLM"
  defp invisible_name(8234), do: "LRE"
  defp invisible_name(8235), do: "RLE"
  defp invisible_name(8236), do: "PDF"
  defp invisible_name(8237), do: "LRO"
  defp invisible_name(8238), do: "RLO"
  defp invisible_name(8288), do: "WJ"
  defp invisible_name(8289), do: "FUNCTION APPLICATION"
  defp invisible_name(8290), do: "INVISIBLE TIMES"
  defp invisible_name(8291), do: "INVISIBLE SEPARATOR"
  defp invisible_name(8292), do: "INVISIBLE PLUS"
  defp invisible_name(8294), do: "LRI"
  defp invisible_name(8295), do: "RLI"
  defp invisible_name(8296), do: "FSI"
  defp invisible_name(8297), do: "PDI"
  defp invisible_name(65279), do: "BOM"
  defp invisible_name(_), do: nil
end
