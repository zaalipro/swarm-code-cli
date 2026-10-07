# Lane E notes (cli020, CLI 0.2.0)

Branch `cli020/E` from M1 `3008f352`, worktree `~/dev/swarm-code-cli-wt/cli020-E`.

## Per task

### E1 Worker and Validator words
- Labels only; keys unchanged. Every `sub-agent model/effort` string in `apps/*/lib` is gone
  (`cli020/e1_worker_words_test.exs` greps all three apps).
- New entries `models.validator`, `efforts.validator`, `session.validator_model` (registry 171 →
  174, scalar keys 131 → 134; `c74_registry_test` updated). `applies: :desktop` (only the ncode
  app's missions read them).
- Deviation/handoff: `efforts.validator` uses `dynamic_choices: {:effort_of, :validator_default}`.
  The daemon's `Settings.Values` (`@global_models`, C's file) has no `validator_default` key yet,
  so it falls back to the chat default model (which is the validator's null meaning, "the main
  model"). For exact levels of a set validator model, C or the finisher adds
  `validator_default: {:default_validator_provider_id, :default_validator_model, :chat}` to
  `@global_models` in `dmn/daemon/service/settings/values.ex`.
- `core/commands.ex` repinned.
