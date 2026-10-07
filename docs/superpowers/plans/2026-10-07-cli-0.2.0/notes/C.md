# Lane C notes (cli020/C)

Branch `cli020/C` in `~/dev/swarm-code-cli-wt/cli020-C`, from M1 `3008f352`. Tasks C1-C23 (C21 is
merged into C11), one commit per task or small group, then `cli020 C: done`.

## Transcript item module (X11)

Shell commands (`!cmd`, C15) are NOT transcript items: the transcript is run-centric
(`TranscriptItem.run_id` is required and the records join runs). They travel as their own
entity, `SwarmCodeCLI.UI.DataSource.DTO.ShellItem` (fields `id, conversation_id, command,
output (2 KB), state :running|:done|:stopped|:failed, exit_code, at, revision, detail_ref`;
`ShellItem.exit/1` returns integer | :stopped | nil, §8.2's `exit`). Workspace snapshot field
`shells` (≤ 50), deltas `:shell_upsert` / `:shell_remove`, `ReadModel.shells` (id => ShellItem).
E15/B21 merge `read_model.shells` into the transcript by `at`. The default watch slot excludes
the shell kinds.

## Stubs the finisher removes (§8.1)

1. `PersistedBackend.shell_message_role/0` returns `"swarm"`; flip to `"shell"` once F3 lands
   (the projection's `shell_messages/3` filters by that role and by content `"$ %"`).
2. `Settings.Values.override_source/1` (private) calls `SessionConfiguration.override_source/1`
   when exported, else reads `override[:source]` (default `:flag`). Replace with the direct call
   after B13.
3. `Rewind.supersede/2` calls `Conversations.supersede_from/2` when exported (F2 via A'1), else a
   loop of `Conversations.supersede/2` over every non-superseded user message from the target on,
   newest first. Replace with the direct call.

## Hand-offs to other lanes

- **E (core/settings/** is E's):** `SwarmCode.Settings.WireBounds` `@views`
  (`core/settings/wire_bounds.ex:13`) must gain `"project_config.summary"` for a client
  `settings.query` of C23's summary to pass the wire bounds. The service routes
  `{"project_config.summary", nil}` (settings/router.ex) to `ProjectConfig.query/4`; the Fake
  answers it. Answer: `%{"hooks" => [%{"event", "command" (first 120 bytes)}], "permissions" =>
  %{"allow", "ask", "deny" => [valid rules]}}`.
- **E1:** the validator registry entries. Values resolves them generically: storages
  `{:setting_pair, :default_validator_provider_id, :default_validator_model}`,
  `{:setting, :default_validator_effort}` with `dynamic_choices: {:effort_of, :validator_default}`,
  `{:conversation_pair, :validator_provider_id, :validator_model}`; session effort source
  `:session_validator`. `models.validator` is in `@pair_entries` (AT4). `values.patch` cannot be
  round-tripped here until the entries exist (it looks keys up in the registry); the changesets
  cast the columns.
- **E3 (parser):** the dispatcher's parsed shapes this lane added:
  `%{action: :rename_conversation, title: <rest>}`, `:delete_conversation`, `:fork_conversation`,
  `%{action: :show_effort, target: :chat | :swarm}` (bare `/effort`, `/swarm_effort`),
  `:undo_turn` (`/undo`), `:select_rewind`. Tests use `CommandDispatcher.execute_parsed/3`
  (`@doc false`) until the parser lands.
- **E/B (C13 "changed" counts):** the counts are computed client-side
  (`ui/settings/sections/overview.ex` changed_rows, `ui/settings/search.ex` `:modified`,
  `release/config_command.ex --modified`). C ships the data: every SettingValue has `modified`
  (DTO field, nil from an older daemon). Count `modified == true`; fall back to the winner check
  when nil. Non-resettable entries are never modified.
- **D19/E9 (C20):** the intent is `{:history_search, conversation_id, query}` (see deviations).

## Deviations

- C1: the CLI domain has no `LLM.Fake`; daemon tests use loopback model servers
  (`SwarmCode.Test.C020Backend`). The workspace already had `queued` (count); `queued_count` is
  the same value under the §8.2 name. The handshake capability list bound went 20 -> 32. The
  drain after init/switch is a message to self, not done inside init. The queue pauses only when
  it is non-empty at the stop; a user-started turn lifts the pause.
- C2/C14: `Attachments.max_bytes/0` is 5,000,000 in the synced domain (spec 74 BUGS-31), not
  6,000,000; limits and sentences follow the real value.
- C3: `cli_command_ledger` has no epoch column (pinned schema); "earlier epochs" = processing rows
  touched before this backend's start. Deleting them at once broke persisted_backend_test
  ("unfinished durable reservation stays unknown after backend restart"); they are pruned only
  when more than 1 h older than the session start.
- C4: `DesktopWatch` lives under `Daemon.Service` and starts only for a PersistedBackend; off in
  test builds (`:desktop_watch` env turns it on). Probe measured 0.22-0.25 s warm, 1.04 s cold,
  so the 10 s interval stays (X16). The shell hears a new Delta kind `:desktop_running`
  (`DTO.DesktopPresence{running}`, `ReadModel.desktop_running`).
- C6: the client resolver keeps "retry needs a failed run" (neutral_contracts_test pins it; the
  switcher offers "Retry failed run"); the service also retries stopped runs.
- C8: `Conversations.search/2` (synced) takes no project; `Daemon.Service.MessageSearch` repeats
  its SQL with the project filter before LIMIT (the FTS builder copies the private
  `sanitize_fts/1`).
- C10: "killed at quit" is not produced: the quit reaper (daemon/shutdown.ex, not C's) records
  nothing; a later session reads such an item as "ended (exit not recorded)".
- C11: `/delete` while live refuses `{:busy, words}` (wire code "busy"; the closed error enum has
  no busy, so the error is `:not_allowed`).
- C13: the flag note is "this launch only" (contract), was "for this launch only" (c74 test and
  Fake updated).
- C14: LiveBackend refuses the new ops with its existing `:not_allowed` (no `not_supported` in the
  closed enum). The service atom of `attachment.attach_slot` is `:attachment_attach`; the client
  intent is `{:attach_slot, conv, token}` as §8.2 says.
- C16: `rewind.turns` and `history.search` are backend reads (`@reads`: jobs, no ledger, no
  response cache); the client asks them as conversation commands (expected `:outcome`, the answer
  in `result`). `/undo`: the dispatcher answers `%{type: :undo, message_id}` and the backend
  rewinds (so it can restage the images). The rewind function is `Rewind.run/3`, not `apply/3`
  (it would shadow `Kernel.apply/3`).
- C18: a model none of whose runs has a price reports `cost_usd: nil` ("price unknown" in the
  text). Rows carry `runs` too; the total row is `name: "Total"`.
- C20: the intent is `{:history_search, conversation_id, query}` (§8.2 wrote
  `{:history_search, query}`): every conversation command names the conversation of its scope
  (`Request.conversation_command/4` checks it); the search spans the project. A row's
  `detail_ref` is set only for a prompt of the open conversation (detail reads are scoped to it).
- C22: the Git read updates only the metadata map and broadcasts `workspace_metadata`, no
  projection reload (a reload changed pass71's projection counts). A request while a read runs
  sets `pending` (one re-read after it); file changes wait out the 10 s gap with one timer.
- C23: `"permissions"` is NOT added to `@top_level`: in project_config.ex `@top_level` is the
  list of top-level keys ncode IGNORES (D40; AT8 "entries ncode ignores"; `remove_top_level` may
  delete them), and F10 reads `"permissions"`. It is a known key (`@known`) and its shape is
  validated into `ignored_entries`: not an object (error), a list other than allow/ask/deny
  (warning), not a list (error), each rule `Engine.Rules.parse/1` drops (error), more than 100
  rules (warning). The rule byte bound is 256 (the desktop's `Rules` `@max_rule_bytes`), not the
  contract's 300, so the list reports exactly what the engine drops. The summary view is named
  `project_config.summary` (kind nil).
- C23: `RunSummary.plan` is `[%DTO.PlanItem{text, status}] | nil`, read by
  `PersistedProjection.plans/2` (the newest `update_plan` op whose parent is the lead, by
  `inserted_at` then id), one query per full projection; a partial reload keeps the plans it read.

## Tests run (focused, one app per call)

- Daemon: c020_dispatcher_test, c020_projection_test, c020 settings values and project_config
  tests, clipboard_inbox_test, shell_escape_test, rewind_test, history_search_test,
  command_ledger tests, desktop_watch tests, persisted_backend_test, pass70_*/pass71_* service
  tests, wire_contract_test, command_dispatcher_test, settings c74_values/c74_connection/
  c74_project_config/c74_router tests; protocol tests (core). Last focused daemon run: 196 tests,
  0 failures (23 files); settings: 30 + 16 tests, 0 failures.
- CLI: ui/data_source (285), plain (with data_source, 335), c74 settings integrations/codec,
  settings sections touching the project file and the acceptance test (80), 0 failures.
- Gates before the done commit (§9.1): `mise exec -- mix format --check-formatted` clean;
  `mise exec -- mix compile --force --warnings-as-errors` exit 0, no warnings;
  `mix swarm_code.provenance.verify` "provenance verified";
  `mix swarm_code.provenance.sync --check` "every synced file derives from the pinned commit"
  (command_dispatcher.ex was repinned in C7, C8, C9, C11, C16, C17 and C18, each in its commit).
- `scripts/dev/test_live_session_pty.py`: 1 test, OK (4.4 s), own terminal, scratch HOME,
  NCODE_CONFIG_DIR and an empty SWARM_ENV_FILE under `~/.cache/ncode/cli020/C/pty`.
- No full suite was run (§4.4).

## AGENTS.md text for the finisher

- Lane C (cli020) service facts: the composer's `!cmd` runs in an owned task of the backend
  (`Daemon.Service.ShellEscape`, no approval: the user typed it) and is persisted as a shell
  message, sent as `DTO.ShellItem` entities, not transcript items. Clipboard images go through
  `Daemon.Service.ClipboardInbox` slots (`<config_dir>/cli-inbox`, 0700, 4 slots, 60 s); the path
  is always rebuilt from the token, never taken from the client. Rewind (`rewind.turns`,
  `rewind.apply`) lives in `Daemon.Service.Rewind`; history search (`history.search`) and
  conversation search in `Daemon.Service.MessageSearch`, both project-filtered in SQL before the
  limit. Git facts (`git_branch`, `git_dirty`) come from one owned task at a time, 2 s bound;
  never read Git in a backend callback.
