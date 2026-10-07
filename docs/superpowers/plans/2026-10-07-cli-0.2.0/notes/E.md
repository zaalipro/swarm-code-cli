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

### E2 Honest Ultra
- `commands.ex` mode hint and `/ultra` description per the contract; the status chip says
  `Ultra · workflows` (`Projector.Composer.mode_title/2`); the help sheet ends with a `Modes`
  section from `Commands.modes/0` (Ultra as `Ultra · workflows`). The composer label and the
  welcome keep `Ultra`. `Dialog.help_lines/2` is public (`@doc false`) for the tests.

### E3 Command registry additions
- `core/commands.ex`: `/rename <title>` (`:rename_conversation`, `%{title}`; empty →
  `missing_argument`, control characters → `invalid_argument`), `/delete`
  (`:delete_conversation`), `/fork` (`:fork_conversation`), `/undo` (`:undo_turn`); bare
  `/effort`/`/swarm_effort` → `:show_effort` `%{target: :chat | :swarm}`; reworded `/rewind`,
  `/consensus`, `/quit`. Small extra: the effort args hint is now `[low|medium|high|max]` (the
  argument is optional now). Repinned.
- C's dispatcher must handle `:rename_conversation`, `:delete_conversation`,
  `:fork_conversation`, `:undo_turn`, `:show_effort` (§3); until C lands they reach its fallback.
- `slash_palette.ex` `@local`: `queue` (`<text> | clear | drop N`), `rewind`, `undo`, `delete`,
  `effort`, `swarm_effort`. Deviation (smallest change that keeps the intent): the rows of core
  commands (`rewind undo delete effort swarm_effort`) keep the catalogue's position (`@in_place`)
  with the local words, instead of moving to the top with the other local rows, so `/sw` still
  selects `/swarm` (the existing `slash_palette_test` pins that).
- Tests: `swarm_code_core/test/swarm_code/cli020_e_commands_test.exs`,
  `cli020/e3_palette_rows_test.exs`; `commands_test.exs` updated (builtin list, bare
  `/swarm_effort`). The ui test directory: 2419 tests, 0 failures.
