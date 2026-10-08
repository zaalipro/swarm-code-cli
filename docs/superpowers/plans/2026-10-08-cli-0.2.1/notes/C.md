# Lane C notes (daemon and wire), CLI 0.2.1

Branch `cli021/C` from CLI main `b6f8c79a`, worktree `~/dev/swarm-code-cli-wt/cli021-C`. Not merged.

## C1 fetch models: root cause and fix

Reproduced first (`cli021_c1_fetch_models_test.exs`): the same reducer, real service socket and
persisted backend the settings screen uses, against a loopback `/v1/models` answering
`ms/glm-5.2`, `ms/deepseek-v4.1flash`, `nv/glm-5.3`, `plain-model`.

- Ids that contain `/` were never the problem (`OpenAI.list_models`, `difference/3`, the wire and
  `Providers.update` all keep them).
- Nothing was ever saved. `provider.fetch_all` (the "Fetch every provider's models" row) only
  computed a difference per provider, reported `N changed lists` and had no way to apply it (it
  dropped the models list from its summary). `provider.fetch_models` stopped at a preview that
  needed a second step (`a` on the provider page, `provider.apply_models`), which the model
  picker's `f` never reaches. So the llmotions row kept its 2026-09-12 list (pass 74 decision D25
  said "writes nothing" on purpose).
- Fix (`daemon/service/settings/providers.ex`): both tasks save. `attributes.apply` is `replace`
  (default, the desktop's Fetch models: the stored list is replaced, a renamed model's old id
  disappears), `add` (new ids only, hand-added ids stay) or `none` (the old preview, applied later
  with `provider.apply_models`). One transaction against the stored row (`Repo.retry` +
  `Repo.transaction`), `Providers.broadcast/0` after commit, so an open page refreshes through the
  existing `settings_update` (tested). A list over 2 000 is never replaced: it is added up to the
  ceiling and the words say `2000 of 2500 kept`.
- The result in words, for U3: task summary `words` = `12 models · 3 new · 2 removed`
  (`no change` when nothing differs; ` · N conversation(s) named a removed model` when a removed id
  is still named). Also `saved` (bool) and `stored` (count). `fetch_all` summary: `words`
  (`3 providers · 2 updated · 1 failed`), `saved`, `failed`, `changed`, `count`; every row has
  `saved` and `message` (the per-provider words, or the error sentence, redacted). An error is the
  task's `message` (`Unauthorized (401): check the API key for provider "x"`) and nothing is
  written (tested with a loopback 401).
- Deviation to know: the client's `Fake` (`fake/settings_integrations.ex`) still defaults to the
  preview-then-apply flow so U's and the other lanes' screen tests keep passing; it answers the
  same keys (`words`, `saved: false`). The real service defaults to saving. The screens already
  handle both (`pending_fetch` is nil once the record has the ids). Texts still saying "shows each
  difference before it changes a list" / "N changed lists" in `ui/settings/sections/providers.ex`
  are U's (U3): use `summary.words`.
- K5 (desktop `Providers.fetch_models/1`) is K's; the CLI path above is independent of it.

## C2 vitals (wire for U1)

Delta, not a request op (deviation from the brief's "op"): a push needs no timer in the client and
the daemon measures only while a shell watch exists. Registered where a delta kind must be:
`DTO.Vitals` + `DTO.ModelSpeed` (`ui/data_source/dto/`), `Delta` (`@bodies`, `@kinds`, type,
`correlated_body?`, `valid_body?`), `Daemon.Codec` (`scoped_delta?`, optional `ShellSnapshot.vitals`),
`PersistedBackend` (shell-only routing, snapshot field, `{:vitals, body}`), `ReadModel`, and the
Fake (`Source.vitals/2`, `Session.initial/2` seeds a steady reading, `Script.apply_delta`).

Read it in the client as `state.read_model.vitals` (`%DTO.Vitals{} | nil`):

- `conversation_id`, `sampled_at` (unix ms).
- `models`: up to 8 `%DTO.ModelSpeed{slot: :main | :worker | :validator | :other, model, tps | nil,
  live, ttft_ms | nil, at | nil, history: [0..12 ints, oldest first]}`. `tps` is the newest output
  tokens/second; `live: true` means the estimate of a call still streaming (and `history` ends with
  it); idle models have `tps: nil`. Rows follow the desktop's speed monitor modes: Ultra lists main,
  worker, validator; a consensus conversation or one whose newest run is a swarm lists main and
  worker; otherwise main. A slot with a sample is always listed. `other` = models its recent runs
  used outside the slots (at most 3, never measured).
- Memory: `beam_bytes` (Erlang VM total), `os_rss_bytes` (that VM's OS resident size),
  `children_rss_bytes` (processes the VM started: the terminal renderer, tool commands), both nil
  until the first reading; `machine_bytes` (the bar's scale, nil when unknown).
- Fact for the design: the daemon and the TUI client run in ONE Erlang VM (`Release.PersistedSession`
  starts both under one supervisor), so "daemon BEAM" and "TUI client" are the same `beam_bytes`; the
  separate OS process worth showing is the Rust renderer, which is inside `children_rss_bytes`.
- Cadence: at most one update per second, a change only (memory compared to a MiB); every second
  while a call streams or finished less than 3 s ago, every 5 s otherwise; nothing at all without a
  shell watch (headless, `-p`). Unsaved (live-launcher) sessions have no vitals (`nil`), the panel
  should draw its idle form.
- The shell snapshot carries the same body (`ShellSnapshot.vitals`, optional on the wire) so a new
  watch or a conversation switch (the backend refocuses and re-snapshots) starts with data.
- Owned work: `Daemon.Service.Vitals` (GenServer linked to the backend, monitors it), one config
  task (conversation models, every 10 s) and one OS task (`ps` bounded to 1 MiB, every 5 s, killed
  after 4 s) under `Domain.TaskSupervisor`; `Vitals.OsMemory` is the pure parser + reader.

## C3 context window

`Daemon.Service.ContextWindow.window/2`: the model's configured `context_window` (Settings,
Pricing; the pricing handler already validates 8 000..2 000 000 and writes it) else the default
window. The wire `context_window` of the workspace (and of the agent detail) is now the WINDOW, no
longer the 75 % trim budget: U2 should draw `used/window` (`8k/1M`); a percent-of-budget colouring
keyed on the old number needs the old ratio (budget = 0.75 x window) if wanted.

- Until K1 is synced the default is the domain's current budget (120 000, Claude 160 000, `[1m]`
  900 000). K1's default budget is 750 000 (75 % of 1 M): `ContextWindow` already reads exactly
  that budget as a 1 000 000 window (pinned by `cli021_context_window_test.exs`), so the K7 sync
  needs no edit here; verify by the first test case after K7.
- A model without a pricing row cannot get a window alone: a pricing row needs input and output
  rates (domain `Setting` validation, same on the desktop). U3's row for an unpriced model has to
  create the row with rates (it can send the existing `pricing.put_row`).

## Parity items taken (lane C, S size or M with my files)

- P1 `/profile [name]` (M): `commands.ex` (builtin + parser clause, repinned), dispatcher
  `:apply_profile`, backend line `Profile: <sentence>`. The desktop's three sentences, plus
  `Switched to profile: x` and, for what cannot apply, ` · skipped swarm_effort turbo (not offered),
  model m (no provider lists it)`. Models resolve like `/model` (provider chosen, override cleared).
  commands.ex is B's file: my change is one builtin line (after `approval`) and one `parse_known`
  clause; B2/B3 conflicts there are line-local. `commands_test.exs` list gained `profile`.
- P2 (S): `Dispatcher.workflow_launch_attrs/5` adds `approval_mode` to `Workflows.launch/1`'s map
  (the helper `approval/1` chat and swarm launches use). Inert until K3 is synced (the CLI domain
  ignores unknown keys; verified `attrs[:key]` access). After K7 re-run the `ncode -p --approval auto
  /workflow ...` check.
- P3 (S): `/resume-run` = `Dispatcher.resumable_run/1` (not superseded, no continuation per the
  desktop's `continued_ids`), refusal text `Nothing to resume.`.
- P4 is U's (`ui/library.ex`), not taken.

## Stubs and handoffs

- No stubs of other lanes remain in my code. B's `worker_*` names do not touch my files; the
  status-line words and settings words are U's.
- Handoff to U1: `state.read_model.vitals`; to U2: `workspace.context_window` is the window; to U3:
  `summary.words` / rows' `message`, `attributes.apply` (`"none"` keeps the preview).
- Handoff to K7/integrator: re-run `mix swarm_code.provenance.repin` on `commands.ex` and
  `command_dispatcher.ex` after merging B; `provenance.verify` and `sync --check` after.
- Open: `LiveBackend` (unsaved sessions) has no vitals and no `/profile` project (it has no
  project). `Task` memory-bound note: `ps` listing cut at 1 MiB while read.

## Gates run (worktree cli021-C)

See the final answer of the lane; `mix format`, `compile --warnings-as-errors`, the focused tests
(`cli021_*`), `provenance.verify`, `sync --check`, the full `mix test` under the slot rule and
`scripts/dev/test_saved_session_pty.py` (2 tests OK).
