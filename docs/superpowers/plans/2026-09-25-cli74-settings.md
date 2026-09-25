# CLI pass 74 — `/settings`: a full settings TUI for the SwarmCode CLI (spec)

Architect: Opus 5.5, 2026-09-25 (revision 2 after two critiques — see the *Critique log* at the end).
Target repo `/Users/zaali/dev/swarm-code-cli` (main `fb99d0f`); the desktop repo `/Users/zaali/dev/swarm-code`
(main `6dd8d82e`, the CLI's pinned upstream) is a read-only reference. Worktrees (all existing, at
`fb99d0f`): `/Users/zaali/dev/swarm-code-cli-wt/c74-{S1,S2,U1,U2,U3,F}` on branches `c74/S1 c74/S2
c74/U1 c74/U2 c74/U3 c74/integrate`. S1, U1 and F start at once; S2 fast-forwards to tag
`c74-S1-core`; U2 and U3 fast-forward to tag `c74-U1-api` (which contains `c74-S1-wire`) — §5.0.

Contents: §0 how to read · §1 goals, non-goals, decisions D1–D40 · §2 the catalogue (170 entries in 22
sections, 19 record kinds + 6 task row kinds, 18 attention sources, 24 not-ported items, coverage check) · §3 architecture
(registry, daemon service, wire, integration handlers, client data source, client layer, cli.json,
keys, entry points, secrets, bounds) · §4 the TUI (amendments to the frames, geometry, keys, values,
detail, toasts, confirmations, async words, states, NO_COLOR/ASCII, help, words, pages, sketches of the
unframed pages) · §5 owners and 86 tasks · §6 acceptance A1–A63 · Appendix A fixture data · Critique
log.

The owner's request (2026-09-25): *a full-featured, production-ready `/settings` in the CLI; configure
every tiny detail; port the other integrations, provider configurations and search configurations from
the web settings page; one single-shotted settings command that opens a new settings TUI.*

This spec is final. Five owners (S1, S2, U1, U2, U3) and a finisher (F) implement it without asking
questions. Where the spec and an input document disagree, the spec wins. Where the spec is silent on a
detail, follow the input it cites, in this order: `frames.md` (look), `inv-tui-design.md`
(behaviour), `inv-desktop-settings.md` / `inv-desktop-integrations.md` (desktop facts, exact messages),
`inv-cli-architecture.md` (CLI facts, file:line).

## 0. How to read this spec

### 0.1 Inputs (all under `/Users/zaali/.cache/c74/`)

| Tag | File | Use it for |
|---|---|---|
| `D§n` | `inv-desktop-settings.md` | every desktop Settings field: label, column, default, exact validation message |
| `I§n` | `inv-desktop-integrations.md` | MCP, search, LSP, project config, agents, skills, commands, memory, trust, keybindings, themes, storage |
| `A§n`, `Rn` | `inv-cli-architecture.md` | the CLI's wire, backend, client toolkit, keymap, cli.json, env; risks R1–R19 |
| `T§n` | `inv-tui-design.md` | the TUI design (rationale, geometry, editors, words) |
| `F1`–`F16` | `frames.md` (+ `frames.html`) | the visual contract, glyph for glyph |

### 0.2 Path abbreviations (relative to the CLI repo root)

| Abbrev | Path |
|---|---|
| `CORE/` | `apps/swarm_code_core/lib/swarm_code/` |
| `DOM/` | `apps/swarm_code_daemon/lib/swarm_code/domain/` (synced desktop domain — **no edits in this pass**) |
| `SVC/` | `apps/swarm_code_daemon/lib/swarm_code/daemon/service/` |
| `DMN/` | `apps/swarm_code_daemon/lib/swarm_code/daemon/` |
| `UI/` | `apps/swarm_code_cli/lib/swarm_code_cli/ui/` |
| `REL/` | `apps/swarm_code_cli/lib/swarm_code_cli/release/` (+ `release.ex` beside it) |
| `CLIT/` | `apps/swarm_code_cli/test/swarm_code_cli/` |
| `DMNT/` | `apps/swarm_code_daemon/test/swarm_code/` |
| `CORET/` | `apps/swarm_code_core/test/swarm_code/` |

Module prefixes: `SwarmCode.Settings.*` (core registry), `SwarmCode.Daemon.Service.Settings.*` (daemon
service, "the service"), `SwarmCodeCLI.UI.Settings.*` (client), `SwarmCodeCLI.Release.*` (launcher).

### 0.3 Glossary

- **setting** — one value with a registry key (`limits.max_concurrent_agents`).
- **record** — a thing with several fields (a provider, an MCP server, a pricing row, a hook, a file).
- **layer** — where a value comes from: `flag`, `env`, `session` (this conversation), `project` (a
  project's DB row), `cli` (`cli.json`, this machine's terminal), `global` (the settings row and global
  records, shared with the desktop app), `project_file` (`.swarm_code/config.json`), `default`.
- **home layer** — the one layer an edit of that setting writes to.
- **the layer** (UI) — the full-screen `/settings` screen (`state.settings`).
- **task** — an async settings action owned by the backend (test, fetch, probe, measure, cleanup…).
- **CAS** — compare-and-set: a write carries what the writer last saw; a mismatch is a conflict.
- **wire value** — the JSON form of a setting's value (§3.2.3).

---

## 1. Goals, non-goals, decisions

### 1.1 Goals

1. `/settings` opens a full-screen settings TUI over the chat (runs keep running under it) from which
   **every** value the desktop Settings page edits can be viewed and changed, plus every CLI-only
   preference, every per-conversation and per-project setting, and the integrations (providers, models,
   efforts, pricing, search, MCP, LSP, storage, memory, the project instructions file, library files,
   project config file).
2. Every value shows its **effective value and where it comes from** (the provenance stack), and every
   editable row says where a write goes before it happens.
3. Writes are validated by the same rules as the desktop, applied instantly (undoable), protected by
   CAS (a concurrent change becomes a visible conflict, never a silent overwrite), and reach the running
   session (status line, model list) at once.
4. Secrets are paste-only, never displayed (masked with at most their last 4 characters), never logged,
   never exported, stored exactly where the desktop stores them.
5. Async actions (test a provider, fetch models, test search, probe/reconnect MCP, check LSP, measure
   and clean storage, doctor, export/import) are owned work with visible progress, a timeout and cancel.
6. Works at 160×45, 120×36, 90×30, 80×24, under both ambiguous-width policies, in truecolor, 256, 16
   colours, `NO_COLOR` and `SWARM_ASCII=1`.
7. A shell twin, `swarmcode config …` (scalars, records and secrets from stdin — enough to provision a
   machine without the TUI), and a direct entry `swarmcode settings [QUERY]` that works even before any
   provider exists.
8. One registry generates rows, search, palette entries, deep links, the headless command, validation
   hints and `docs/settings.md`.

### 1.2 Non-goals (this pass)

- No DB migration, no new table or column, no change to `DMN/schema/*` exact-set validators.
- No edit of any synced domain file under `DOM/` (no new `provenance/patches/*`), no edit of the
  desktop repo.
- No macOS Keychain (the desktop has none; both apps must read the same store).
- No terminal notifications (bell, OSC 9/777, window title): the Rust port has no command for them
  (see §2.24).
- No terminal ports of the desktop's 8 web themes as palettes (§2.24); the CLI stays Carbon dark/light
  with an optional accent override.
- No change to `/approval`, `/trust`, `/model`, `/effort`, `/theme`, `/diff`, `/mouse`, `/panel`
  semantics (they keep working; only their toasts gain a `/settings …` hint).
- No running of the desktop Scheduler in the CLI (retention gets a manual "apply now").

### 1.3 Decisions (final)

| # | Decision |
|---|---|
| D1 | **Surface.** `/settings` is a full-screen state slot `state.settings` (like the pass-72 agent overlay `state.overlay`), not a `LayerSpec` modal. The palette (Ctrl-P) and the settings layer's own popovers (pickers, confirmations, help) draw over it. Runs, approvals and deliveries continue under it. |
| D2 | **Entry points.** `/settings [ARG]` (aliases `/config`, `/prefs`), `F2` (main, composer, inspector contexts), palette rows (one per section, one per scalar setting, ranked below every existing palette kind, §3.10.1), `swarmcode settings [QUERY]`, `swarmcode config …` (headless, §3.10.3), and `/settings <key>` hints in settings-related toasts. The `--plain` presenter and `-p` one-shots answer `/settings needs the full-screen terminal; use swarmcode config here.` |
| D3 | **One registry** in core: `SwarmCode.Settings.Registry` (data only, compiled, no closures), shared by the daemon (validation, snapshots, writes), the client (rows, editors, search, deep links), the headless command and the docs generator. A value that is not in the registry does not exist. |
| D4 | **Sections** (rail order, 21 + Overview): Overview · *models* Models & effort, Providers, Pricing · *tools* Search & web, Deep research, MCP servers, Language servers · *agents* Agents & limits, Approvals & trust, Project file, Memory & instructions, Library · *this terminal* Appearance, Layout & transcript, Keys & input, Session & startup · *data* Storage, Budget & usage · *more* Desktop app, Files & environment, Import & export. (T§5.0 with Notifications removed and Deep research split out of Search.) The section id of *Memory & instructions* stays `memory`. |
| D5 | **Storage without migration.** `global` = columns of the singleton `settings` row and global records (`providers`, `search_providers`, global `mcp_servers`); `session` = `conversations` columns; `project` = `projects` columns and project-scoped `mcp_servers`; `cli` = `<config_dir>/cli.json` through `SwarmCode.Settings.CliFile` (core, S1; wrapped by `UI.Init.Preferences`, U1); `project_file` = `<root>/.swarm_code/config.json`; files = MEMORY.md, the project instructions file (AGENTS.md…), commands, agent definitions, skills, workflows. |
| D6 | **Secrets = desktop storage, exactly.** Provider keys in `providers.api_key`, search keys in `search_providers.api_key`, MCP secrets inside `mcp_servers.env` / `mcp_servers.headers` — plaintext SQLite, as the desktop writes them, so both apps read them. A stored secret never leaves the daemon: the wire carries `{"set": bool, "hint": "a1b2" \| null}` where `hint` = the last 4 characters only when the secret is ≥ 12 characters, else null. Secrets enter only by bracketed paste (typing only where the terminal cannot mark pastes, or after `Ctrl-T type instead` in the paste target, never echoed) or `swarmcode config secret … --stdin` (§3.10.3); they travel in the dedicated `secrets` request parameter once per write attempt, are never ledgered, cached beyond the task that needs them, logged, drawn, undone, searched, toasted or exported. An MCP env/header entry is secret by `SecretPattern.secret_kv?/2` (§3.2.5), a strict superset of the desktop's `Server.secrets/1` (masking only changes what the terminal shows, so the CLI may be stricter than the desktop). Replacing a key that is already set tests the new key first and keeps the old one when the test fails (§3.5.1). Rows say `stored in SwarmCode's database · shared with the desktop app`. |
| D7 | **Writes go through the daemon with CAS.** Every `global`/`session`/`project`/`project_file`/record/file write is a `settings.command` carrying `expected` (what the client last read). The service re-reads the current value from the database (never the cache) inside the write's transaction and refuses a mismatch with `conflict` + the current value. A conflict is drawn on the row (keep mine / take theirs); nothing is overwritten silently. `cli` writes go through `CliFile.write_changes/3` with per-key CAS against the file and a fingerprint re-check just before the rename (§3.8.1). "Keep mine" after a conflict re-sends with `expected` = the value the conflict reported (a fresh CAS, §3.7.9). `expected: {"$any": true}` is used only by `swarmcode config set` without `--expect` and by `provider.delete` for the replaced defaults. |
| D8 | **Instant apply, few drafts.** Toggles, enums, pickers, typed numbers/texts, list edits, record fields of existing records save when committed (undoable, toasted). Drafts (saved with `Ctrl-S`) only for: a new record, the effort-levels table, a new pricing row until both prices are valid, and MCP connection fields (staged; applied once on leaving the record page or with `R restart now`, because every MCP update restarts the client; `r` reverts a staged field like every other reset). |
| D9 | **Async actions are backend-owned tasks** (§3.3.8): start → `settings_task` deltas (state, elapsed ms, progress, a ≤ 16 KB summary — never the full result) → done/failed/timeout/cancelled; the full result is read with `settings.query view=task` (paged); correlated by `task_id`; one per `{action, target}` (a new one replaces the old); ≤ 8 running; a bounded result cache per session; cancel by `task.cancel`; closing the layer cancels the cancellable ones. Non-cancellable tasks (storage run, vacuum, apply retention, import apply) are never killed by a timer: they get a reporting deadline (`still running after N s`). Quitting while one runs asks first (§4.8). |
| D10 | **Live updates.** The backend subscribes to the `settings`, `providers`, `search_providers`, `projects`, `mcp` and `storage` topics, emits coalesced `settings_update` deltas (sections touched, origin, revision — never values) and re-projects the workspace metadata (fixes R3). The layer re-queries what it shows. Engine caches are invalidated again **after** every settings commit (never only inside the transaction, §3.3.4). |
| D11 | **Provider-less start.** `swarmcode settings` opens even when no provider is usable. A provider is *usable* when its key is non-blank or its base URL is a private host (`SwarmCode.Domain.Tools.WebFetch.private_host?/1`: loopback, RFC 1918, link-local, `.local`, `.internal`, `.home.arpa`); `SessionConfiguration.usable?/1` (S1, made public) is the one predicate for launch, dispatch and attention. A send is refused with words (not a crash, not a failing run) whenever the conversation's effective chat provider is not usable — also when `effective_model` succeeds, as on a fresh database whose seeded llmotions provider has no key. The exit-3 sentence (only for `{:error, :provider_required}`) names `swarmcode settings providers`. |
| D12 | **Any project.** Approvals, always-allowed families, project memory, the instructions file, project file and MCP scope can be edited for any non-scratch project in `Projects.list/0` through a project picker (desktop parity: Settings shows all projects' families). Default = the session's project. |
| D13 | **Untrust exists** (CLI-local, no domain edit): `trusted_at = nil` and `approval_mode = "read_only"`, behind a confirmation. |
| D14 | **Escalations confirm in settings:** approvals → full access, trusting a project, a new or changed hook command (also when the command arrives through an external edit of config.json, §3.5.7). `/approval full` keeps today's behaviour. |
| D15 | **Project-file top-level `effort`/`swarm_effort`/`model`/`swarm_model`** have no runtime effect today (I§5.4). They are shown as `SwarmCode ignores this key` with `x remove`; `merge_defaults/2` stays unwired; the layer is carried with `ignored: true` and never wins (D40). |
| D16 | **Unset vs default.** A nullable column can be cleared (choice "same as …" writes null; fixes D§18 #7). For non-nullable columns "changed" means `value ≠ registry default`; reset writes the default. |
| D17 | **One home layer per key; no `S` chooser.** Session values and their global defaults are separate adjacent rows (e.g. *Effort · this conversation* and *Default effort*). The status row always says `writes to <layer>`. |
| D18 | **Theme.** `terminal.theme` = follow desktop · dark · light (live, as `/theme`); `terminal.accent` overrides the accent roles at the next launch; the desktop's 8 themes/mode/motion are editable in *Desktop app* ("no effect in the terminal", except `desktop.mode`, which the terminal follows live when `terminal.theme` is "follow desktop", §3.8.5). |
| D19 | **Key overrides** live in cli.json `"keys"` (`binding id → [key names]`; `[]` = unbound). Fixed (never remappable, never unbound): Esc, Enter, the arrow keys, Ctrl-C, `?`/F1, Ctrl-S, the approval letters `y Y A d D n`, and the bindings active inside hint mode (`hint_again`, `hint_pick`, `hint_run`, `hint_runs_dashboard`, `hint_cancel`, `hint_backspace`). Everything else is remappable, including the hint leader `hint_mode` and the settings page letters. The recovery path is `swarmcode config reset terminal.keys`. `docs/keybindings.md` documents defaults; every printed hint reads the effective keys. |
| D20 | **cli.json** grows from 16,384 to 65,536 bytes, becomes registry-driven, keeps unknown keys, writes atomically 0600 with per-key CAS (`SwarmCode.Settings.CliFile`, S1). Existing keys `panel`, `show_diffs`, `theme`, `mouse` keep their names and values. |
| D21 | **NO_COLOR** means present **and non-empty** (no-color.org), in the TUI and the exit summary alike (fixes R9). |
| D22 | **The generic library settings form is retired from the client.** The palette's "Settings" row opens the layer; `:settings` leaves `Library.features/0`, the `{:library, :settings}` / `{:feature_form, :settings, _}` layer specs are removed. The daemon's `feature settings` stays for wire compatibility (unused by the client). |
| D23 | **Fix R1:** `FeatureRequest` errors use the canonical messages the client decodes. **Fix R5:** the client decodes up to 400 workspace models. **Fix R7:** settings MCP updates never re-scope a server implicitly. |
| D24 | **No DB write on read.** Settings reads never call `Search.all/0` (it inserts placeholder rows) or `Settings.get/0` (it inserts a missing row); missing search kinds are synthesised in memory and created on first write. |
| D25 | **Fetch shows a difference before writing.** Fetching a provider's models lists them (no write) and shows `+ new / − gone (N conversations use it) / unchanged`; *apply* writes the cached fetch (the list never travels back from the client). *Test connection* (NEW) lists models and writes nothing. |
| D26 | **Files are written atomically** with `SwarmCode.Domain.AtomicFile.replace/3`, confined to their owning root, with a content fingerprint CAS; external edits go through a private temporary copy, never the file in place. |
| D27 | **Storage retention** needs the desktop scheduler; the page says so and offers `▸ Apply retention now` (a task holding the `:storage_cleanup` registration, §3.5.5). |
| D28 | **LiveBackend** (unsaved `run_live_session.sh` sessions) answers settings requests `unavailable`; terminal sections (cli.json) still work. |
| D29 | **Words** follow T§18: no "daemon", "refused" (except quoting a server), "invalid", "error occurred", "Are you sure?", UUIDs or column names in rows. Failures read `Couldn't <verb>: <reason>`. |
| D30 | **Budget** stays whole dollars (desktop parity); blank = no budget; a stored float without a fraction reads as that integer (§3.3.3). |
| D31 | **Honest numbers**: times are the measured request's, counts are real, `no price` when Pricing lacks a row, "fetched this session HH:MM" (no fetch timestamps survive a restart: there is no column for them), level times are this machine's medians or `not measured yet`. |
| D32 | **Registry keys** are dotted lowercase strings; atoms exist only as compiled registry ids; runtime input is looked up in string tables, never `String.to_atom/1`. |
| D33 | **Small answers.** No `settings_result` or delta carries file content or a whole task result: a file conflict returns the fingerprint only (the client re-reads the file), task results are read with `view=task`, and every settings_result is capped (§3.4.2) and guarded below the ledger's 128 KiB bound before `CommandLedger.complete/3`. |
| D34 | **A stored value the CLI does not understand is a row, not a failure.** A scalar outside the registry's type (a newer desktop's theme, a legacy out-of-range number) arrives as `state: "invalid"` with `value: null`; the row says `✗ stored value not understood: <v>`, stays writable, `r` resets it, and Overview flags it (AT18). Only secret-shape violations reject a whole response. |
| D35 | **The conversation mode is one value**: `session.mode` = build · plan · consensus · ultra · workflow, written as the four columns together exactly like `/plan`, `/consensus`, `/ultra`, `/create-workflow` (`CommandDispatcher.mode_fields/1`); no settings write can produce a combination the commands never produce. |
| D36 | **The project instructions file** (AGENTS.md, else SWARMCODE.md, else CLAUDE.md; created as AGENTS.md) is edited on *Memory & instructions* for the page's project, with the loading facts (root + 3 levels, ≤ 12 files, ≤ 32 000 characters, never read in an untrusted project, I§9.2). |
| D37 | **Long lists filter in place.** In a list sub-page, record table or checklist of more than 20 rows, `/` filters that list; `/` on an empty local filter (or `:goto`) opens the global search. Provider models and MCP tools are indexed per record in the global search. |
| D38 | **Undo survives closing the layer**: the undo/redo history and the changelog live in `State.settings_history` for the whole session. |
| D39 | **One bound per thing**, stated once in §3.12 and referenced everywhere else (models per provider ≤ 2 000, MCP tools ≤ 512, coalescing 100 ms, progress ≤ 4 per second per task, `values.patch` ≤ 256 changes). A fetch longer than a bound never truncates silently and never deletes: `replace` is refused, only `add new` is offered. |
| D40 | **Ignored layers never win.** A layer the runtime does not honour (a project-file key D15 ignores, an env value outside the entry's value space such as `SWARM_CONVERSATION=<uuid>`) is carried as `{"set": true, "ignored": true, "raw": …, "value": null, "note": …}` and is shown in the provenance list, never as the winner. |

---

## 2. The settings catalogue

### 2.0 Conventions

- One table per section (the section is the table's heading). **Every row is one registry entry**
  (§3.2) unless it is marked *record field* (fields of a record kind, §2.23), *fact* (read-only) or
  *action* (`▸`, a task or command).
- Columns: **id** (registry key; record fields use `<kind>.<field>`) · **label — description** ·
  **scope · layers** · **storage** · **type · values / bounds** · **default** · **validation** (the
  exact message; *svc* = checked only by the service, *cli* = CLI addition, else the desktop changeset's
  own) · **effect · applies** · **parity** (`D§`/`I§`/`A§` reference, `NEW` = no desktop equivalent,
  `CLI` = existing CLI-only) · **secret**.
- Scope codes: `G` global (shared with the desktop app) · `S` session (this conversation) · `P`
  project (DB row) · `C` cli.json · `PF` project file · `R` record · `X` fact (read-only) · `A` action.
- Layer codes, strongest first; `→` marks the home layer: `F` flag · `E` env · `S` session · `P`
  project · `C` cli.json · `G` global · `PF` project file · `D` default. A code in parentheses, e.g.
  `(PF)`, is a layer that is shown in the provenance list but **ignored** (D40): it never wins.
- Applies vocabulary: *at once*, *next turn*, *next spawn*, *next request*, *next research*, *new
  conversations*, *new clients* (language servers), *restart* (MCP client restart), *next launch*,
  *desktop* (only the desktop app reads it).
- Changeset messages are Ecto's text; the TUI shows them as `✗ <message>` under the row (e.g.
  `✗ must be between 1 and 16`). Default Ecto texts used below: inclusion `is invalid`, format
  `has invalid format`, required `can't be blank`, `validate_number` without a custom message
  `must be greater than or equal to N` / `must be less than or equal to N`, length
  `should be at most N character(s)`.
- Model wire value: `{"provider_id": "<uuid>", "model": "<model id>"}` or `null`. Effort wire value: a
  level key string or `null`. Durations are integers in the **stored** unit.

### 2.1 Overview (`overview`, U1) — no settings; attention sources

The Overview page (F1) lists *needs attention*, *at a glance*, *changed from default* (first 9, from the
values snapshot), *where values come from* (count per winning layer) and *changed in this session* (from
`State.settings_history`, so it survives closing the layer, D38).

*Usable* below is D11's predicate (`SessionConfiguration.usable?/1`: a non-blank key, or a private-host
base URL).

| # | Attention item (title · reason) | Severity | Computed by | Target (Enter goes to) |
|---|---|---|---|---|
| AT1 | `<name> MCP server failed to start` · the status reason (redacted) | error | S2 `Settings.MCP.attention/1`: enabled server with status `{:error, _}` | the server's record page |
| AT2 | `<name> did not answer its last test` · words of the error | error | S2 providers: last `provider.test`/`fetch` of this session failed | provider page |
| AT3 | `<name> has no key` · `a default model uses it` | warning | S2 providers: provider referenced by a `models.*` default, not usable | provider page, key row |
| AT4 | `The <label> points to a provider that is gone` | warning | S1 values: a `models.*`/`research.*_model` pair whose provider id is missing | the row |
| AT5 | `N models in use have no price` · `a, b count as $0.00 in every cost` | warning | S2 pricing: models in defaults or used by conversations in the last 30 days without a pricing row | Pricing, unpriced group |
| AT6 | `Agents cannot search the web` · `no search engine is on` | warning | S2 search: no enabled engine kind | Search & web |
| AT7 | `.swarm_code/config.json is not valid JSON` · `line L, column C` | error | S2 project config (session project) | Project file |
| AT8 | `ailogic's project file has entries SwarmCode ignores` · `effort, 1 hook: unknown event post_edit` (≤ 3 items, then `+N`) | warning | S2 project config: denied keys, the four ignored top-level keys, or `ignored_entries` (§3.5.8) present | Project file |
| AT9 | `Hooks will not run until you trust <project>` | warning | S2 project config: hooks present, project untrusted | Approvals & trust, Trusted row |
| AT10 | `No provider can answer` · `add a key or a local server` / `The chat model's provider <name> has no key` | error | S1: no usable provider, or the effective chat provider of new conversations (`Providers.effective_model(%Conversation{}, :chat)`) is not usable | Providers / the `models.chat` row |
| AT11 | `Retention has not run for N days` · `it runs in the desktop app · ▸ apply now` | warning | S1: a retention policy set and `storage_last_cleanup_at` older than 7 days (or nil) | Storage, retention |
| AT12 | `<file>: <reason>` agent definition not read | warning | S2 library: `Agents.parse/1` error for a user/project file | Library › agents |
| AT13 | `cli.json could not be read` / `is readable by other users (0644)` / `is larger than 64 KB` | error / warning | U1 (client read of cli.json) | Files & environment |
| AT14 | `N key overrides in cli.json were ignored` · first reason | warning | U3 `Keymap.Overrides.compile/1` errors | Keys & input › Key bindings |
| AT15 | `Page reader is Firecrawl but it has no key` · `pages use the plain fetch` | warning | S2 search: `web.reader = firecrawl` and the Firecrawl row has no key | Search & web › Firecrawl |
| AT16 | `Default effort xhigh is not a level of deepseek-v4-pro` · `turns use medium` | warning | S1 values: an `efforts.*`/`session.*effort`/`research.*_effort` value that is not in the entry's dynamic choices (what `Efforts.normalise_key` would silently replace) | the row |
| AT17 | `<Engine> did not answer its last test` · words of the error | warning | S2 search: the last `search.test` of an enabled engine this session failed | the search provider's record |
| AT18 | `<Label> holds a value this CLI does not understand` · `r resets it` | warning | S1 values: a SettingValue with `state: "invalid"` (D34) | the row |

Glance lines (F1, "at a glance"): providers (count · N answered their last test this session · N never
tested), search (engines on · reader), MCP (servers · connected · failed · tools on/total), agents
(`<max concurrent> at once · depth <d> · <turns> turns · <sub-agent limit> each`), approvals (session
project: mode · trusted · N always-allowed commands), storage (`last sweep <ago>`; size only if measured
this session), budget (`$spent of $budget this month` + gauge, only when a budget is set).

### 2.2 Models & effort (`models_effort`, U3)

Groups in page order: **new conversations**, **default efforts**, **this conversation**, **consensus ·
this conversation** (a sub-page `Enter open`, listed only while `session.mode` is `consensus`; its rows
stay editable through search and `:set` in any mode, with the continuation `used only in consensus
mode`), and link rows `this project's file · N keys SwarmCode ignores → Project file` (when the project
file sets any of the four ignored keys) and `from the environment → Files & environment` (when a §2.25
variable feeding this page is set).

| id | label — description | scope · layers | storage | type · values / bounds | default | validation | effect · applies | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `models.chat` | Chat model — the model a new conversation's chat turns use | G · G→ D | `settings.default_chat_provider_id` + `default_chat_model` | model (picker over every provider × model; typed model allowed) | first-boot seed: provider "llmotions" · `gemini-3.7-flash-high` (only on an empty providers table), else null | svc: `that provider no longer exists`; svc: `pick a model` (provider without model) | new conversations; `Providers.effective_model(conv, :chat)` fallback chain | D§1a | no |
| `models.sub_agent` | Sub-agent model — model of spawned workers and `/swarm` runs | G · G→ D | `default_swarm_provider_id` + `default_swarm_model` | model | as chat | as chat | new conversations, next spawn; judge falls back to it | D§1a | no |
| `models.scheduled` | Scheduled task model — tasks without their own model | G · G→ D | `default_scheduled_provider_id` + `default_scheduled_model` | model, nullable: `the chat model` | null | as chat | desktop (schedules run only while the desktop app runs; the row says so) | D§1a, I§13 | no |
| `models.workflow` | Workflow model — workflow runs without their own model | G · G→ D | `default_workflow_provider_id` + `default_workflow_model` | model, nullable: `the chat model` | null | as chat | next workflow run | D§1a | no |
| `models.implementer` | Implementer model (consensus) — who implements a judged plan | G · G→ D | `default_implementer_provider_id` + `default_implementer_model` | model, nullable: `the planner implements` | null | as chat | next consensus implementation | D§1a | no |
| `models.fetch_all` | ▸ Fetch every provider's models | A | task `provider.fetch_all` | action | — | — | per-provider difference, apply per provider (§3.5.1) | D§1c | no |
| `efforts.default` | Default effort — reasoning effort of chat turns | G · G→ (PF) D | `default_effort` | effort (levels of the chat default model's provider ∪ low medium high max) | `"medium"` | `has invalid format` (`^[a-z0-9][a-z0-9_-]{0,23}$`) | next turn of conversations without their own effort | D§1b | no |
| `efforts.sub_agent` | Sub-agent effort | G · G→ (PF) D | `default_swarm_effort` | effort (levels of the sub-agent default) | `"medium"` | as above | next spawn | D§1b | no |
| `efforts.scheduled` | Scheduled effort | G · G→ D | `default_scheduled_effort` | effort, nullable: `same as the default effort` | null | as above | desktop | D§1b | no |
| `efforts.workflow` | Workflow effort | G · G→ D | `default_workflow_effort` | effort, nullable: `same as the default effort` | null | as above | next workflow run | D§1b | no |
| `efforts.implementer` | Implementer effort | G · G→ D | `default_implementer_effort` | effort, nullable: `medium (not set)` | null | as above | next consensus implementation | D§1b | no |
| `session.model` | Model · this conversation | S · F S→ G D | `conversations.chat_provider_id` + `chat_model` | model, nullable: `the chat model` | null | svc: `that provider no longer exists` | next turn; a write also clears the `--model` session override (as `/model`) | CLI `/model` | no |
| `session.effort` | Effort · this conversation | S · S→ G D | `conversations.effort` | effort (levels of this conversation's effective chat model, after the `--model` overlay), nullable: `the default effort` | null | `has invalid format`; svc: `is not a level of <model>: <k1>, <k2>, …` | next turn; a running turn keeps its level | CLI `/effort` | no |
| `session.sub_agent_model` | Sub-agent model · this conversation | S · F S→ G D | `swarm_provider_id` + `swarm_model` | model, nullable: `the sub-agent model` | null | as `session.model` | next spawn; a write also clears the `--model` session override (as `/swarm_model`) | CLI `/swarm_model` | no |
| `session.sub_agent_effort` | Sub-agent effort · this conversation | S · S→ G D | `swarm_effort` | effort (levels of the effective sub-agent model, after the overlay), nullable | null | as `session.effort` | next spawn | CLI `/swarm_effort` | no |
| `session.mode` | Mode — build makes changes; plan only plans; consensus plans, judges, then implements; ultra works harder on each turn; workflow sends your messages to `/create-workflow` | S · S→ D | `{:conversation_mode}`: the four columns `mode`, `consensus`, `ultra`, `authoring_workflow`, written together with `CommandDispatcher.mode_fields/1`'s mapping and read in `current_mode/1`'s order (consensus > ultra > workflow > plan > build) | enum `build` "Build" · `plan` "Plan" · `consensus` "Consensus" · `ultra` "Ultra" · `workflow` "Writing a workflow" | `"build"` | `is invalid` | next turn (workflow: next message) | CLI `/plan` `/consensus` `/ultra` `/create-workflow` (D35) | no |
| `session.title` | Title | S · S→ D | `conversations.title` | text ≤ 120 | `"New conversation"` | `should be at most 120 character(s)` | at once | NEW | no |
| `session.pinned` | Pinned — storage cleanup never deletes a pinned conversation | S · S→ D | `conversations.pinned_at` (now / nil) | toggle | off | — | at once | NEW | no |
| `session.consensus_checks` | Consensus checks — what the judge looks at | S · S→ D | `conversations.consensus_checks` (nil = defaults) | checklist of the 12 `Engine.Consensus.checks/0` keys: `over_engineering`✓ `judge_plan`✓ `judge_changes` `minimal`✓ `codebase`✓ `scope`✓ `edge_cases`✓ `risk` `tests` `alternatives` `decision_complete` `gate`✓ (✓ = default on) | null (the 7 defaults) | svc: `unknown check: <key>` | next consensus turn | D§15a | no |
| `session.consensus_rounds` | Consensus rounds | S · S→ D | `conversations.consensus_rounds` | enum 1 · 2 · 3 | 2 | `is invalid` | next consensus turn | D§15a | no |
| `session.judge_model` | Judge model | S · S→ G D | `judge_provider_id` + `judge_model` | model, nullable: `the sub-agent model` | null | as `session.model` | next consensus turn | D§15a | no |
| `session.judge_effort` | Judge effort | S · S→ D | `judge_effort` | effort, nullable: `the default` | null | `has invalid format` | next consensus turn | D§15a | no |
| `session.implementer_model` | Implementer model · this conversation | S · S→ G D | `implementer_provider_id` + `implementer_model` | model, nullable: `the default implementer` | null | as `session.model` | next consensus implementation | D§15a | no |
| `session.implementer_effort` | Implementer effort · this conversation | S · S→ G D | `implementer_effort` | effort, nullable | null | `has invalid format` | next consensus implementation | D§15a | no |
| `session.profile` | ▸ Apply a profile — the project file's profiles | A | writes `effort`, `swarm_effort`, `chat_model`, `swarm_model` of the conversation from the profile (`/profile` semantics, I§5.2) | action (picker of profile names) | — | svc: `Unknown profile "<name>"` | next turn | I§5.4 | no |

Notes. The `F` layer of `session.model` and `session.sub_agent_model` is `--model`
(`SWARM_MODEL_OVERRIDE`, in memory, `SessionConfiguration.overlay/1` overlays both chat and sub-agent
provider/model); its value is shown with `for this launch only`, and a write of either row clears the
whole override (as `/model` and `/swarm_model` do). The dynamic effort choices of the session rows are
computed from the overlaid model. The `(PF)` layer of `efforts.default` / `efforts.sub_agent` shows the
project file's `effort` / `swarm_effort` when present, ignored, with the note `SwarmCode ignores this
key` (D15, D40). The session group is hidden (one info row `There is no conversation in this
session.`) when the session has no conversation. A change of `session.mode` made elsewhere (a `/plan`
typed before the layer opened) arrives through the `conversation_updated` refresh like any other row.

### 2.3 Providers (`providers`, U2)

The page lists provider records (§2.23 `provider`), a virtual read-only row *from the environment*
(when first-run onboarding variables `SWARM_BASE_URL`/`SWARM_MODEL`/`SWARM_API_KEY` or
`OPENAI_*`/`ANTHROPIC_*` are set: "used only when no provider can answer; nothing is saved from them"),
and actions:

| id | label — description | scope | storage / call | type | effect | parity |
|---|---|---|---|---|---|---|
| `providers.add` | ▸ Add a provider — draft from a preset | A | `provider.create` | action (preset picker, in this order: Anthropic `https://api.anthropic.com` kind anthropic, effort preset `anthropic_adaptive` · OpenAI `https://api.openai.com/v1`, `openai` · OpenRouter `https://openrouter.ai/api/v1`, `openrouter` · DeepSeek `https://api.deepseek.com/v1`, `deepseek` · llmotions `https://cli.llmotions.com/v1`, built-in levels · Ollama `http://localhost:11434/v1` (no key), built-in · LM Studio `http://localhost:1234/v1` (no key), built-in · Other (blank, openai_compatible), built-in) | new record draft whose *Effort levels* row reads `<preset name> · from the preset` (built-in: `built-in levels`); `Ctrl-S` creates it with `effort_levels` = the preset's levels (null for built-in) and runs the test | D§4c, D§4d |
| `providers.fetch_all` | ▸ Fetch every provider's models | A | task `provider.fetch_all` | action | per-provider difference, apply per provider | D§1c |

Record fields and record actions: §2.23 *provider*, *effort_level*. After a create, when the new
provider is usable and the provider of `models.chat` is not (AT10), the created record's page shows
`▸ Use <name> · <default model> for new chats` first (one `values.patch` of `models.chat` and
`models.sub_agent`, undoable); the same action row stays on every usable provider's record page.

### 2.4 Pricing (`pricing`, U2)

Pricing rows are records (§2.23 *pricing_row*) stored in the one map column `settings.pricing`. The
page shows a first group **used but unpriced** (`unpriced_model` records, `warning`) then the rows
sorted by model, columns in this order everywhere: `model · in $/M · out $/M · cache read · cache write
· context`. `a` adds a draft row, `x` removes a row (undoable), cells commit one by one; `/` filters
the rows when there are more than 20 (D37). Sketch: §4.15.

### 2.5 Search & web (`search_web`, U2)

| id | label — description | scope · layers | storage | type · values | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `web.reader` | Page reader for web_fetch — every agent's web_fetch, not only research | G · G→ D | `settings.research_reader` | enum `web_fetch` "Plain fetch (strip HTML)" · `jina` "Jina Reader" · `firecrawl` "Firecrawl" (+ ` — no key, falls back` when Firecrawl has no key) | `"web_fetch"` | `is invalid` | next web_fetch call; an unconfigured reader falls back to the plain fetch | D§2b | no |
| `web.fetch_facts` | web_fetch facts — `private and localhost pages are fetched directly, never through a reader · pages over 4 MB are refused · 20 000 characters by default` | X | hard-coded (`DOM/tools/web_fetch.ex`) | fact | — | — | — | I§3 | no |

Search providers: six `search_provider` records (§2.23), engines first in fallback order (Tavily, Exa,
Brave, Serper), then readers (Jina, Firecrawl). A link row goes to *Agents & limits › Tool timeout* (it
bounds web_search, web_fetch and search HTTP calls).

### 2.6 Deep research (`deep_research`, U3)

| id | label — description | scope · layers | storage | type · values / bounds | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `research.level` | Default level | G · G→ D | `research_level` | enum `low` "Fastest" (1 round · 4 agents) · `medium` "Medium" (2 rounds · 3 agents each) · `high` "High" (3 · 4) · `ultra` "Ultra" (4 · 10); each option's hint = this machine's median time from `Research.estimates/0` or `not measured yet` | `"medium"` | `is invalid` | next research | D§2c | no |
| `research.max_live` | Agents in flight at once — research's own cap | G · G→ D | `research_max_live` | int 1–32 | 10 | `must be between 1 and 32` | next round | D§2d | no |
| `research.max_sources` | Pages each agent must read | G · G→ D | `research_max_sources` | int 1–20 | 5 | `must be between 1 and 20` | next round | D§2d | no |
| `research.recency_days` | Only sources newer than — research searches only | G · G→ D | `research_recency_days` | int days 1–3650, nullable: `any age` | null | `must be between 1 and 3650` | next research search | D§2d | no |
| `research.agent_timeout` | Seconds an agent may take — the reporter gets twice this | G · G→ D | `research_agent_timeout_s` | duration, stored s, 60–3600 | 600 | `must be between 60 and 3600` | next round | D§2d | no |
| `research.max_retries` | Retries after a timeout | G · G→ D | `research_max_retries` | int 0–3 | 1 | `must be between 0 and 3` | next round | D§2d | no |
| `research.retry_timeouts` | Retry timed-out agents — off: the partial note is what the round gets | G · G→ D | `research_retry_timeouts` | toggle | true | — | next round | D§2d | no |
| `research.headlines` | A headline per round — one small call per round at the lead tier | G · G→ D | `research_headlines` | toggle | true | — | next round | D§2d | no |
| `research.auto_design` | Designed HTML report | G · G→ D | `research_auto_design` | enum `deep` "After every deep research" · `all` "After every research, Fastest too" · `never` "Only when I ask" | `"deep"` | `is invalid` | when a research finishes | D§2e | no |
| `research.include_domains` | Only these domains — research searches only | G · G→ D | `research_include_domains` | list<domain> ≤ 64 items | `[]` (`any domain`) | normalised: split on whitespace/commas, trimmed, `http(s)://` and trailing `/` stripped, blanks dropped, duplicates refused cli: `already in the list` | next research search | D§2f | no |
| `research.exclude_domains` | Never these domains | G · G→ D | `research_exclude_domains` | list<domain> ≤ 64 | `[]` (`none`) | as above | next research search | D§2f | no |
| `research.lead_model` | Lead model — plans each round, writes the headline | G · G→ D | `research_lead_provider_id` + `research_lead_model` | model, nullable: `the sub-agent model`; a pair whose provider is gone shows `(provider removed) · <model>` | null | svc: `that provider no longer exists` | next research | D§2g | no |
| `research.lead_effort` | Lead effort | G · G→ D | `research_lead_effort` | effort, nullable: `default` | null | `has invalid format` | next research | D§2g | no |
| `research.worker_model` | Worker model — searches and reads; an ultra research runs forty | G · G→ D | `research_worker_provider_id` + `research_worker_model` | model, nullable: `the sub-agent model` | null | as lead | next research | D§2g | no |
| `research.worker_effort` | Worker effort | G · G→ D | `research_worker_effort` | effort, nullable | null | as lead | next research | D§2g | no |
| `research.reporter_model` | Reporter model — writes result.md and report.html | G · G→ D | `research_reporter_provider_id` + `research_reporter_model` | model, nullable: `the sub-agent model` (desktop: unset falls back to the swarm default) | null | as lead | next research | D§2g | no |
| `research.reporter_effort` | Reporter effort | G · G→ D | `research_reporter_effort` | effort, nullable | null | as lead | next research | D§2g | no |
| `research.root` | Research folder — `o` opens it, `y` copies the path | X | app env `:research_root` (`~/.swarmcode/research`) | fact (path) | — | — | — | D§2h | no |

Each tier row shows "Runs per research" beside the model (D§2g `tier_runs/2`), computed client-side from
`research.level`, `research.headlines` and `research.auto_design` with `Research.Levels` numbers carried
in the snapshot (`facts.research_levels`, §3.4.6).

### 2.7 MCP servers (`mcp`, U2)

The list page groups servers `every project` (global) and `<project> only` (servers of the page's
project), each row `name · transport · state · tools on/total`. Records: §2.23 *mcp_server*,
*mcp_tool*. Page actions:

| id | label — description | scope | call | parity |
|---|---|---|---|---|
| `mcp.add` | ▸ Add an MCP server — draft (`transport: stdio`, enabled) | A | `mcp.create` on `Ctrl-S` | D§6c |
| `mcp.import` | ▸ Import from .mcp.json — reads `<project root>/.mcp.json` or a path you type (`mcpServers` object, Claude/`.mcp.json` shape); ticked servers are created; secret-looking env/header values arrive masked | A | task `mcp.import.read` (preview) then `mcp.import.apply` with the ticked names and per-value choices | NEW |

The import preview (sketch §4.15) is one row per server (`name · transport · command or url · N env ·
N headers`, ticked unless its name exists — `a server named github exists · x skip / n import as
github-2`) with its variable rows underneath:

- **Variables.** SwarmCode never expands variables (I§1.2: what is stored is sent). An env/header value
  that is `${NAME}` or `$NAME` (`^\$\{[A-Za-z_][A-Za-z0-9_]*\}$` or `^\$[A-Za-z_][A-Za-z0-9_]*$`) shows
  `${GITHUB_TOKEN} · SwarmCode does not expand variables` with a per-value choice: `v take it from this
  shell now (set|not set)` — the service reads `System.get_env/1` of the environment `swarmcode` was
  started with, at apply time, and a not-set variable cannot be chosen; `p paste a value` (a paste
  target, D6); `k keep it literally` (the default only when neither of the others is possible). The
  choice is sent as `values: {"<server>": {"env.GITHUB_TOKEN": "shell" | "paste" | "literal"}}` with
  pasted bytes in `secrets` (slot `import:<server>:env:<NAME>`).
- **Transports.** `"type": "sse"` entries are unticked and cannot be ticked: `SSE servers are not
  supported; use the server's streamable http URL`. `"type": "http"`/`"streamable-http"` or a `url`
  make an http server; otherwise stdio.

Environment note shown in the detail of every stdio server (I§1.10): `MCP servers get the default secret
scrub, not yours: put the keys a server needs in its own environment.`

### 2.8 Language servers (`language_servers`, U2)

One row per language (13). Value wire: `null` = the built-in command, `"off"` = disabled, any other
string = a custom command line (split on whitespace; paths with spaces cannot be written — the detail
says so). Editor: enum `default · off · custom` + a text field for custom. All are `G · G→ D`, storage
`settings.lsp_servers["<language>"]` (key absent = default), validation `every key and value must be a
string` (desktop) plus cli: `can't be blank` for an empty custom command, `should be at most 1024
character(s)`, `one line only`. Effect: *new clients* — a running language server keeps its command
until it idles out (300 s) or `▸ Stop running servers` stops it. Parity I§4 (first UI anywhere). Not
secret.

| id | language (extensions) | built-in command |
|---|---|---|
| `lsp.elixir` | Elixir (`.ex .exs`) | `elixir-ls --stdio` |
| `lsp.erlang` | Erlang (`.erl .hrl`) | none — `no default: set a command` (attention-free, shown as `no default`) |
| `lsp.typescript` | TypeScript (`.ts .tsx`) | `typescript-language-server --stdio` |
| `lsp.javascript` | JavaScript (`.js .jsx .mjs .cjs`) | `typescript-language-server --stdio` |
| `lsp.python` | Python (`.py`) | `pyright-langserver --stdio` |
| `lsp.rust` | Rust (`.rs`) | `rust-analyzer` |
| `lsp.go` | Go (`.go`) | `gopls serve` |
| `lsp.c` | C (`.c .h`) | `clangd --log=error` |
| `lsp.cpp` | C++ (`.cpp .cxx .cc .hpp`) | `clangd --log=error` |
| `lsp.ruby` | Ruby (`.rb .rake`) | `solargraph stdio` |
| `lsp.java` | Java (`.java`) | `jdtls` |
| `lsp.swift` | Swift (`.swift`) | `sourcekit-lsp` |
| `lsp.zig` | Zig (`.zig`) | `zls` |

Keys in `lsp_servers` that are not one of the 13 languages (a newer desktop's language, a typo) are
kept on every write and shown after the 13 rows as `<key> · not a known language · x remove` (`x`
writes the map without that key, undoable).

Actions: `lsp.check` (▸ Check which are installed — task, runs on page open, `System.find_executable/1`
of each effective command's first word, plus running clients per project), `lsp.stop` (▸ Stop running
servers — for the page's project or `every project`; applies overrides now). Row state after a check:
`✓ installed` / `✗ not installed: <exe>` / `no default` / `off`, and `N running in <project>`.

### 2.9 Agents & limits (`agents_limits`, U3)

| id | label — description | scope · layers | storage | type · bounds | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `limits.max_concurrent_agents` | Max concurrent agents — per run: sub-agents of one swarm or one chat turn working at once; research has its own cap | G · G→ D | `max_concurrent_agents` | int 1–16 | 4 | `must be between 1 and 16` | next spawn | D§12 | no |
| `limits.max_agent_depth` | Max agent depth — nesting of spawn_agent | G · G→ D | `max_agent_depth` | enum 1 · 2 · 3 | 2 | `must be between 1 and 3` | next spawn | D§12 | no |
| `limits.max_agent_turns` | Max agent turns — think/act loops per agent | G · G→ D | `max_agent_turns` | int 1–200 | 60 | `must be between 1 and 200` | next spawn | D§12 | no |
| `limits.sub_agent_timeout` | Sub-agent time limit — a worker that runs longer is stopped and its partial work reported | G · G→ D | `sub_agent_timeout_s` | duration, stored s; special `0` = `no limit`; else 60–86 400 | 1800 | `must be 0 (no limit) or between 60 and 86400` | next spawn | D§12 | no |
| `limits.workflow_budget` | Workflow agent budget — the most agents one workflow run may spend | G · G→ D | `workflow_budget` | int 1–1024 | 128 | `must be between 1 and 1024` | next workflow run; a project file cannot set it | D§12 | no |
| `limits.workflow_max_live` | Max live workflow agents — at the same time (RAM) | G · G→ D | `workflow_max_live` | int 1–64 | 16 | `must be between 1 and 64` | next workflow step | D§12 | no |
| `limits.command_timeout` | Command timeout — the least every shell command gets; a call may ask for more | G · G→ D | `command_timeout_ms` | duration, stored ms, 1 000–600 000 (shown 1 s – 10 min) | 120 000 | `must be between 1000 and 600000` | next command | D§12 | no |
| `limits.tool_timeout` | Tool timeout — web fetch, web search, MCP and language-server calls | G · G→ D | `tool_timeout_ms` | duration, stored ms, 1 000–600 000 | 120 000 | `must be between 1000 and 600000` | next tool call | D§12 | no |
| `isolation.worktrees` | Isolate sub-agents — each sub-agent works in its own copy; the lead merges with integrate_agent; git projects only | G · G→ D | `worktrees_enabled` | toggle | true | — | next spawn | D§12 | no |
| `isolation.backend` | How to isolate | G · G→ D | `isolation_backend` | enum `auto` "Auto (APFS clone when available, else git worktree)" · `clone` "APFS clone" · `worktree` "Git worktree" | `"auto"` | `is invalid` | next spawn | D§12 | no |
| `shell.env_scrub` | Hide secrets from commands — drops variables named like `API_KEY`, `*_KEY`, `SECRET`, `TOKEN`, `PASSWORD`, `PASSWD`, `CREDENTIAL`, `*_PAT` | G · G→ D | `shell_env_scrub` | toggle | true | — | next command (run_command only; MCP servers and hooks always use the default scrub) | D§12 | no |
| `shell.env_keep` | Keep these variables — names kept despite the scrub | G · G→ D | `shell_env_keep` | list<env name> ≤ 64 | `["GITHUB_TOKEN", "GH_TOKEN"]` | cli: `use a variable name: A–Z, 0–9 and _` (`^[A-Za-z_][A-Za-z0-9_]*$`); duplicates `already in the list` (the changeset also splits on commas, trims, uniq) | next command | D§12 | no |
| `shell.path` | Shell — blank detects `$SHELL` | G · E G→ D | `shell_path` (nil = detect) | path (executable), nullable: `detect (<$SHELL value>)` | null | svc: `is not an executable file` / `is not a file on this machine` | next command; `SWARM_CODE_SHELL` wins while set | D§12 | no |
| `shell.login` | Login shell — `-lc`, so `.zprofile`/`.profile` PATH additions (mise, asdf, nvm, brew) apply | G · G→ D | `shell_login` | toggle | true | — | next command | D§12 | no |

Link rows: `Agent definitions → Library`, `Always-allowed commands → Approvals & trust`.

### 2.10 Approvals & trust (`approvals`, U3)

The page has a project picker row at the top (`ailogic ▾`, every non-scratch project; default the
session's project; a scratch session shows `There is no project in this session…` until one is picked).

| id | label — description | scope · layers | storage | type · values | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `project.approval_mode` | Approvals | P · P→ D | `projects.approval_mode` | enum `read_only` "Read-only · nothing runs or changes without asking" · `auto` "Auto · edits go ahead, commands ask first" · `full_access` "Full access · commands and edits go ahead" | `"read_only"` | `is invalid` | at once for new tool calls; raising to full access asks (D14) | A§2.10, `/approval` | no |
| `project.trusted` | Trusted — reads AGENTS.md, lets hooks run | P · P→ D | `projects.trusted_at` (on = `Projects.trust/1`; off = CLI-local untrust, D13) | toggle with `since <date>` | off | — | at once; both directions ask (trust lists the hooks that will start running; untrust says approvals go back to read-only) | `/trust`, I§10 | no |
| `project.allow` | Always-allowed commands — a command whose first words match runs without asking, in this project only | P · P→ D | `projects.auto_approve_prefixes` | list<command family> ≤ 64 × ≤ 200 bytes | `[]` (`none yet`) | cli: `can't be blank`, `one line only`, `already in the list`; svc: `a dangerous command is never remembered` (`CommandSafety.classify/1 == :dangerous`); svc: `the scratch project keeps no always-allowed commands` | next command | D§12a | no |
| `project.name` | Name | P · P→ D | `projects.name` | text ≤ 120 | the folder name | `can't be blank` | at once (the desktop sidebar shows it) | NEW | no |
| `project.root` | Folder | X | `projects.root_path` | fact (path, `~`) | — | — | — | I§10 | no |
| `project.last_opened` | Last opened | X | `projects.last_opened_at` | fact | — | — | — | I§10 | no |
| `project.approval_env` | From the environment — `SWARM_APPROVAL` (read only by unsaved live sessions; it has no effect here, D40) | X | env | fact | — | — | — | A§6.2 | no |

A collapsed group **other projects** lists the always-allowed families of every other project with
`Enter` switching the page's project (the desktop's Approved commands section shows them all).

### 2.11 Project file (`project_file`, U3)

For the page's project (same picker as §2.10). The page header shows the path
`<root>/.swarm_code/config.json`, `✓ read` / `✗ not valid JSON (line L, column C)` / `no file yet`, and
`R reload` when the fingerprint changed since the page loaded. Records: §2.23 *hook*, *profile*.

| id | label — description | scope · layers | storage | type | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `project_file.effort` | effort — `SwarmCode ignores this key` (D15) · `x` removes it | PF | config.json `"effort"` | fact + remove action | absent | — | none | I§5.4 | no |
| `project_file.swarm_effort` | swarm_effort — ignored, as above | PF | `"swarm_effort"` | fact + remove | absent | — | none | I§5.4 | no |
| `project_file.model` | model — ignored, as above | PF | `"model"` | fact + remove | absent | — | none | I§5.4 | no |
| `project_file.swarm_model` | swarm_model — ignored, as above | PF | `"swarm_model"` | fact + remove | absent | — | none | I§5.4 | no |
| `project_file.denied` | Keys a project file may not set — `tavily_api_key`, `default_chat_provider_id`, `default_swarm_provider_id`, `default_scheduled_provider_id`, `default_workflow_provider_id`, `monthly_budget_usd`, `workflow_budget` (one row each when present, `x` removes) | PF | config.json | fact + remove | — | — | stripped with a warning when read | I§5.2 | no |
| `project_file.edit` | ▸ Edit the whole file in your editor (`e`/Ctrl-X) | A | `file.save` kind `project_config` | action | — | JSON errors are reported after save and the file is saved as typed; a new or changed hook command in a trusted project asks first (D14, §3.5.7) | next read (the engine's hook cache is invalidated after the save, §3.5.8) | NEW | no |

Unknown keys are preserved on every structured write (`Jason.OrderedObject` read and pretty write,
§3.5.8; values stay semantically equal, formatting is normalised). Entries the domain drops or bends
when it reads the file are listed under the tables as `ignored_entries` rows (§3.5.8): `✗ hooks.post_edit
· unknown event · x remove`, `! hooks.pre_tool_use[0] matcher "*.ex" is not a regular expression · runs
for every tool`, `✗ hooks.post_tool_use[2] · no command · dropped`, `! timeout 50000 · used as 30000`,
`! profiles.fast.mode · not a profile key`, `✗ profiles["bad name"] · not a profile name · dropped`;
`x` removes the entry (a structured write), Enter on a matcher/timeout row edits it. Sketch: §4.15.

### 2.12 Memory & instructions (`memory`, U2)

Three file records (§2.23 *file*), with the project picker of §2.10 at the top:

- **this project's memory** (`memory_project`: the path `Memory.file(:project, root)` gives,
  `<root>/.swarm_code/MEMORY.md`) and **global memory** (`memory_global`: `Memory.file(:global, nil)`,
  the domain's global memory path — never built by hand). Each shows line count and size, edits in
  place when ≤ 16 384 bytes (multi-line editor, `Ctrl-S` saves), else `e`/`Ctrl-X` only; `C` clears
  (asks, names the line count). Writes via `Memory.write/3` (atomic). Parity D§7, I§9.1. Detail:
  `Facts the agents saved with the remember tool. They are added to every system prompt (project memory
  even in untrusted projects).`
- **project instructions** (`instructions`, D36): the file `ProjectContext.instructions_path/1` names —
  the first existing regular, root-confined file of `AGENTS.md`, `SWARMCODE.md`, `CLAUDE.md`, else
  `<root>/AGENTS.md` (row `AGENTS.md · no file yet · Enter creates it`). The row shows the winning
  name, lines and size, plus the facts line `loaded at run start from the root and 3 levels below
  (AGENTS.override.md first in each folder) · 12 files · 32 000 characters`. In an untrusted project the
  row adds `not read until you trust <project>` (`warning`) with a link to *Approvals & trust ›
  Trusted*. Edit in place ≤ 16 384 bytes or `e`/`Ctrl-X`; saved with `AtomicFile.replace/3` confined to
  the project root and a fingerprint CAS; no `C` clear (an empty instructions file is written by
  editing). Parity I§9.2 (the desktop edits it in its workspace editor, not in Settings).

### 2.13 Library (`library`, U2)

Four groups of file records (§2.23): **commands** (`/name · scope · swarm · mode · description`),
**agent definitions** (all three tiers, with `shadows the bundled one` / `shadowed`, parse errors as `✗`
rows), **skills** (`name · scope · description · files`), **workflows** (`name · scope · smoke`). Keys:
`Enter` open in the editor (external edit round trip, D26), `n` new from template (asks tier/scope and
name), `x` delete (user/project only; asks; bundled/built-in cannot be deleted), `o` open the folder
(§3.7.2 `{:open_folder}`; a missing folder is not created by opening it), `y` copy the path (§3.7.2 `{:copy}`), `t`
run the workflow smoke check, `/` filter a group of more than 20 files (D37). A command whose name is
`settings`, `config` or `prefs` shows `shadowed by the built-in /settings · rename the file to use it`
(`warning`). Parity D§9, D§11, I§6–I§8. Sketch: §4.15.

### 2.14 Appearance — this terminal (`appearance`, U3)

All `C` keys live in `<config_dir>/cli.json` (json name in *storage*). "Next launch" rows show
`applies at the next launch` in the detail and toast.

| id | label — description | scope · layers | storage | type · values | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `terminal.theme` | Theme | C · E C→ G D | `"theme"`: `"dark"`/`"light"`, absent = follow desktop | enum `follow` "Follow the desktop app (<its mode>)" · `dark` "Dark" · `light` "Light" | follow (absent) | `is invalid` | at once (live repaint, `{:terminal_preferences, %{theme: _}}`); `SWARM_THEME` wins at the next launch (T2 wording); G = `desktop.mode` | CLI `/theme` | no |
| `terminal.colors` | Colours | C · E C→ D | `"colors"` | enum `auto` "auto: <probe>" · `truecolor` · `256` · `16` · `none` | auto | `is invalid` | next launch; `NO_COLOR` (present and non-empty) wins; auto = `COLORTERM`/`TERM` probe | NEW | no |
| `terminal.glyphs` | Glyphs | C · E C→ D | `"glyphs"` | enum `auto` "auto: <tier>" · `rich` · `measured` · `ascii` | auto | `is invalid` | next launch; `SWARM_ASCII=1` wins (ascii); forcing `rich` under wide ambiguous width warns | NEW | no |
| `terminal.ambiguous_width` | Ambiguous-width characters | C · C→ D | `"ambiguous_width"` | enum `narrow` · `wide` | narrow | `is invalid` | next launch | NEW | no |
| `terminal.reduced_motion` | Reduced motion | C · C→ D | `"reduced_motion"` | toggle | off | — | next launch (`Capabilities.reduced_motion?`) | NEW | no |
| `terminal.accent` | Accent colour — the focus bar, caret, hint badges and the assistant's colour | C · C→ D | `"accent"`: `"#RRGGBB"`, absent = Carbon `#FF6A1A` | color (hex; shows 256/16-colour twins and WCAG contrast on the page colour) | absent | cli: `a colour such as #FF6A1A` (accepts `#RRGGBB`, `RRGGBB`, `#RGB`, stored as `#RRGGBB` upper-case) | next launch; below 4.5:1 contrast warns, never blocks | NEW | no |
| `terminal.desktop_theme_link` | The desktop app's theme → Desktop app | X | — | link | — | — | — | — | no |

### 2.15 Layout & transcript — this terminal (`layout`, U3)

| id | label — description | scope · layers | storage | type · bounds | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `terminal.panel` | Side panel | C · C→ D | `"panel"` | enum `full` · `compact` · `hidden` | full | `is invalid` | at once; Ctrl-B cycles it | CLI `/panel` | no |
| `terminal.composer_rows` | Composer height — rows at launch; Ctrl-↑/↓ still adjust it | C · C→ D | `"composer_rows"` | int 1–8 | 3 | `must be between 1 and 8` | at once (sets the current height too) | NEW | no |
| `terminal.inspector_width` | Inspector width | C · C→ D | `"inspector_width"` | enum `compact` (38) · `default` (46) · `wide` (56) | default | `is invalid` | at once | NEW | no |
| `terminal.show_diffs` | Show diffs — off draws every tool row on one line | C · C→ D | `"show_diffs"` | toggle | on | — | at once | CLI `/diff` | no |
| `terminal.notice_seconds` | Notices stay for | C · C→ D | `"notice_seconds"` | duration, stored s, 2–30 | 6 | `must be between 2 and 30` | at once (`State.notice_ms/0` becomes state-driven) | NEW | no |
| `terminal.diff_lines` | Diff lines shown — lines of each diff hunk drawn before `… N more lines · Enter opens` | C · C→ D | `"diff_lines"` | int 4–200, big step 10 | 12 | `must be between 4 and 200` | at once (the transcript's `@diff_preview` becomes `prefs["diff_lines"]`) | NEW | no |

### 2.16 Keys & input — this terminal (`keys`, U3)

| id | label — description | scope · layers | storage | type · values | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `terminal.keymap` | Keymap — vim adds NORMAL/VISUAL modes to the composer | C · E C→ D | `"keymap"` | enum `standard` · `vim` | standard | `is invalid` | at once; `SWARM_KEYMAP` wins at the next launch; the palette's "Vim mode" toggle now writes this key | CLI | no |
| `terminal.mouse` | Wheel scrolling — off gives the terminal its own selection back | C · E C→ D | `"mouse"` | toggle | on | — | at once; `SWARM_MOUSE` wins at the next launch | CLI `/mouse` | no |
| `terminal.wheel_lines` | Lines per notch | C · C→ D | `"wheel_lines"` | int 1–10 | 3 | `must be between 1 and 10` | at once; disabled (`only when Wheel scrolling is on`) when mouse is off | NEW | no |
| `terminal.editor` | Editor for Ctrl-X | C · C→ E D | `"editor"` (absent = `$VISUAL`, then `$EDITOR`, then `vi`) | text ≤ 1024, a command line | absent | cli: `can't be blank`, `one line only`; soft check (owned work): `not found on your PATH: <word>` (warns, saves) | at once | NEW | no |
| `terminal.hint_letters` | Hint letters — Ctrl-F badges, in order | C · C→ D | `"hint_letters"` | text of letters | `"sfghjklwertuiop"` | cli: `only lowercase letters a–z`, `each letter once`, `use at least 8 letters`, `y a d n q answer approvals or close; they cannot be hint letters` | at once | NEW | no |
| `terminal.keys` | Key bindings — sub-page (F11, sketch §4.15) | C · C→ D | `"keys"`: `{"<binding id>": ["Ctrl-L", …]}` (overrides only; `[]` = unbound) | keys map, ≤ 256 bindings × ≤ 4 keys | `{}` | per binding (§3.9.3): `<key> is fixed`, `this terminal cannot report <key>`, `<key> is taken by "<label>" in <contexts>`, `"<label>" cannot be remapped`, `"<label>" cannot be unbound`, `not a key name`, `4 keys at most` | at once; every printed hint follows; an unbound binding disappears from hints and footers and reads `unbound` in help | NEW | no |
| `terminal.terminal_facts` | This terminal reports — bracketed paste, focus, wheel, enhanced keys (never) | X | `Capabilities` | fact | — | — | — | T§5.15 | no |

### 2.17 Session & startup — this terminal (`startup`, U3)

| id | label — description | scope · layers | storage | type · values | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `terminal.startup_conversation` | On launch | C · F E C→ D | `"startup_conversation"` | enum `latest` "Continue the latest conversation" · `new` "Start a new conversation" · `ask` "Ask (the resume picker, as --resume)" | latest | `is invalid` | next launch; `--new`/`--continue`/`--resume` and `SWARM_CONVERSATION` win (`SWARM_CONVERSATION=latest\|new` is an env layer; a conversation id is outside this row's values, so it is carried as an ignored layer, D40, with the note `this launch opened one named conversation`) | NEW | no |
| `terminal.companion` | Visual companion — the loopback web mirror (palette "Open visual companion") | C · E C→ D | `"companion"` | toggle | on | — | next launch; `SWARM_COMPANION=0` wins | NEW | no |
| `terminal.project_root` | Project folder — the DIR argument, else the current directory | X | launch fact | fact | — | — | — | A§6.3 | no |
| `terminal.launch_flags` | This launch — the flags it was started with | X | launch fact | fact | — | — | — | A§6.3 | no |

### 2.18 Storage (`storage`, U2)

| id | label — description | scope · layers | storage | type · values | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `storage.retention_days` | Automatically delete sessions older than | G · G→ D | `storage_retention_days` | int days 7–3650, nullable `off`; quick picks Off · 30 · 60 · 90 · 180 | null | `must be between 7 and 3650` | the daily sweep of the desktop app, or `▸ Apply retention now` | D§8b | no |
| `storage.prune_days` | Prune agent details older than — keeps transcripts, tokens, cost, timings | G · G→ D | `storage_prune_days` | int days 7–3650, nullable `off`; quick picks Off · 14 · 30 · 90 | null | `must be between 7 and 3650` | as above | D§8b | no |
| `storage.last_sweep` | Last sweep | X | `storage_last_cleanup_at` | fact (`<ago>` / `never`) | — | — | — | D§8b | no |
| `storage.measure` | ▸ Measure — runs when the page opens if no measure ran this session; `▸ Re-measure` after | A | task `storage.measure` | action | — | — | overview, quick-preset previews, sessions list | D§8a | no |
| `storage.cleanup` | ▸ Clean up… — the wizard below | A | tasks `storage.plan`, `storage.run` | action | — | — | deletes/prunes; not undoable | D§8c | no |
| `storage.vacuum` | ▸ Reclaim disk space (VACUUM) | A | task `storage.vacuum` | action | — | refusals: `a run is live; stop it first`, `needs <X> free, <Y> free` | rewrites the database file; deletes nothing | D§8c | no |
| `storage.apply_retention` | ▸ Apply retention now — the desktop app normally does this daily | A | task `storage.apply_retention` | action | — | `set a retention first` when both are off; `A cleanup is already running.` | deletes/prunes by policy | NEW (D27) | no |

The page text under the title (D§8): `What SwarmCode's own database and research folders hold. Nothing
here touches your projects.` and, under the retention rows, the desktop's sentence `Pruning keeps every
transcript: a run keeps its tokens, cost and timings, and only the tool output and prompts are dropped.
Pinned sessions, open sessions and anything still running are never touched, and the sweep never
compacts the file on its own.`

**Overview** (after a measure; D§8a): a bar of the kinds with bytes > 0 (Sessions, Agent details,
Rewind snapshots, Workflow journals, Research, Index & free space) with a legend `kind · count · bytes`,
then the line `<db> on disk · <wal> write-ahead log · at least <reclaimable> reclaimable · N isolation
directories (<bytes>) · N sessions` and `measured HH:MM`. Before a measure: `◷ measuring · N s`.

**The cleanup wizard** (`CleanupWizard`, U2; sketch §4.15). Steps `choose → review → running → done`;
the *choose* step has three tabs cycled with `Tab`/`Shift-Tab` inside the wizard (the wizard is a
sub-page; Esc goes back one step, and is ignored while running):

- **Quick** — the five desktop presets as action rows with their measured preview (`N sessions · X`,
  from `storage.measure`'s previews; a preset whose preview is empty is disabled with `nothing to
  remove`): `Delete sessions older than 30 days` (note `everything they hold goes with them`) · `Keep only
  the last 2 weeks` · `Prune agent details older than 14 days` · `Delete rewind snapshots older than 30
  days` · `Reclaim disk space (VACUUM)` (`compacts the file; deletes nothing`). Enter goes straight to
  *review* with that preset's selection.
- **Sessions** — the measured sessions table `title · project · updated · size` (`records:storage_sessions`,
  paged 200, only visible rows projected); `Space` picks a row, `A` picks every *deletable* shown row
  (again: unpicks them), `s` cycles the sort `size → date → title`, `/` filters by title or project
  (`Filter by title or project…`); locked rows show `locked` (`text_muted`) with the desktop reason (`A run of
  this session is still going`, `This session is open in a window` — in the CLI `open in this
  terminal`, `Cannot be deleted`); a pinned row can be picked explicitly (the selection carries
  `include_pinned: true`, as the desktop does). `Enter review` with at least one pick.
- **Advanced** — enums with the desktop's choices and hints: `Rewind snapshots older than` off · 14 ·
  30 · 90 (`the file contents saved before an agent overwrote them`) → `checkpoint_days`; `Workflow
  journals of finished runs older than` off · 30 · 90 (`a finished run can no longer be replayed or
  resumed without them`) → `journal_days`; `Agent details older than` off · 14 · 30 · 90 (`keeps every
  transcript, token and cost — only tool output and prompts go`) → `prune_days`; `Research reports and
  their folders older than` off · 30 · 90 (`removes the row and ~/.swarmcode/research/<id>`) →
  `research_days`; toggle `Empty sessions` (`no messages and no runs`) → `empty_sessions`; toggle
  `Reclaim disk space afterwards (VACUUM)` (`at least <reclaimable> would come back; deletes nothing`) →
  `vacuum`. Every change re-plans through `storage.plan` (the task key is `{storage.plan, :wizard}`, so a
  new plan replaces the running one; a plan whose `plan_id` is not the latest is dropped).
- **Review** — the plan items `count · label · bytes`, `kept back` with the reasons (`still running`,
  `open in this terminal`, `pinned — pick it in Sessions to include it`), the warning `This cannot be
  undone. Deleted sessions, snapshots and reports are gone for good.` (+ the prune note when pruning);
  vacuum-only plans read `Nothing is deleted. SQLite rewrites the database file…` and need Enter only;
  an empty plan reads `There is nothing to remove.`; otherwise the typed confirmation `type delete N and
  Enter` (N = the item count; Enter alone never deletes).
- **Running** — `◷ deleting K of N · X freed · <step>`; `can't be stopped`.
- **Done** — `Freed X from N items.` / `Reclaimed X of disk space.` / `Nothing was removed.`; vacuum
  `The database file went from A to B.`; after a delete without vacuum the nudge `The database file is
  still X — SQLite keeps deleted space for reuse until the file is compacted. At least Y would come
  back.` + `▸ Reclaim disk space (VACUUM)`; the overview re-measures.

### 2.19 Budget & usage (`budget`, U3)

| id | label — description | scope · layers | storage | type | default | validation | effect | parity | secret |
|---|---|---|---|---|---|---|---|---|---|
| `budget.monthly_usd` | Monthly budget — a target; nothing is blocked when it runs out | G · G→ D | `monthly_budget_usd` (float column; a stored `50.0` reads as `50`, a stored `12.5` reads as `state: "invalid"`, D34) | money, whole dollars ≥ 0, nullable `no budget` | null | cli: `must be a whole number of dollars, zero or more`; changeset `must be zero or more` | at once (display only); a project file cannot set it | D§13 | no |
| `budget.month` | This month — spend with a gauge against the budget | X | usage view | fact | — | — | — | D§13 | no |
| `budget.by_model` | Last 30 days by model — tokens in/out and cost; a model without a price says `no price` | X | usage view | fact table | — | — | — | NEW | no |

### 2.20 Desktop app (`desktop`, U3) — shared, "no effect in the terminal"

Every settings-row column only the desktop app reads. All `G · G→ D`, not secret. The page says
`These change the desktop app. The terminal ignores them (except Mode, which Theme can follow).`
The **window state** group is collapsed by default; its detail says `the desktop writes these as you
drag; editing them here is rarely useful`.

| id | label | storage | type · values / bounds | default | validation | parity |
|---|---|---|---|---|---|---|
| `desktop.theme` | Theme | `theme` | enum carbon "Carbon" `#ff6a1a` · obsidian "Obsidian" `#6366f1` · graphite "Graphite & Amber" `#f5c26b` · aurora "Aurora Glass" `#2dd4bf` · ember "Ember" `#c9662f` · fjord "Fjord" `#0e9aa8` · dusk "Dusk" `#f2604e` · paper "Paper" `#d9664a` (swatch `▮▮▮` in the accent) | `"carbon"` | `is invalid` | D§3 |
| `desktop.mode` | Mode — also the terminal's theme when Theme follows the desktop | `mode` | enum dark · light | `"dark"` | `is invalid` | D§3 |
| `desktop.reduce_motion` | Reduce motion | `reduce_motion` | toggle | false | — | D§3 |
| `desktop.bench_layout` | Consensus card | `bench_layout` | enum scales "Scales" · rail "Rail — the checks on a rail" · spine "Spine — one node per phase" · scorecard "Scorecard — checks × rounds" | `"scales"` | `is invalid` | D§3 |
| `desktop.consensus_layout` | Consensus panes | `consensus_layout` | enum stacked "plan above the verdict" · side "beside it" | `"stacked"` | `is invalid` | D§14 |
| `desktop.focus_on_finish` | Bring the window to front when a run finishes | `focus_on_finish` | toggle | false | — | D§3 |
| `desktop.show_global_tasks` | Show global scheduled tasks | `sidebar_show_global_tasks` | toggle | true | — | D§3 |
| `desktop.show_reasoning` | Expand activity & reasoning by default | `show_reasoning` | toggle | false | — | D§3 |
| `desktop.keys.file_finder` | Key · File finder | `keybindings["file_finder"]` | combo (web syntax), nullable = default | `meta+p` (⌘P) | `invalid key combo`; `conflict: <a> and <b> are both bound to <combo>` | D§10 |
| `desktop.keys.new` | Key · New chat | `keybindings["new"]` | combo | `meta+n` | as above | D§10 |
| `desktop.keys.nudge_left` | Key · Resize panes left | `keybindings["nudge_left"]` | combo | `shift+alt+ArrowLeft` | as above | D§10 |
| `desktop.keys.nudge_right` | Key · Resize panes right | `keybindings["nudge_right"]` | combo | `shift+alt+ArrowRight` | as above | D§10 |
| `desktop.keys.quit` | Key · Quit | `keybindings["quit"]` | combo | `meta+q` | as above | D§10 |
| `desktop.keys.search` | Key · Search | `keybindings["search"]` | combo | `meta+k` | as above | D§10 |
| `desktop.keys.settings` | Key · Settings | `keybindings["settings"]` | combo | `meta+,` | as above | D§10 |
| `desktop.keys.side` | Key · Toggle side chat | `keybindings["side"]` | combo | `meta+shift+s` | as above | D§10 |
| `desktop.keys.sidebar` | Key · Toggle panel | `keybindings["sidebar"]` | combo | `meta+b` | as above | D§10 |
| `desktop.sidebar_collapsed` | Sidebar hidden | `sidebar_collapsed` | toggle | false | — | D§14 |
| `desktop.sidebar_width` | Sidebar width (px) | `sidebar_width` | int 280–440 | 280 | `must be between 280 and 440` | D§14 |
| `desktop.sidebar_sections` | Folded sidebar groups | `sidebar_sections` | map, read-only; `r` resets to `{}` | `{}` | — | D§14 |
| `desktop.sidebar_scroll` | Sidebar scroll (px) | `sidebar_scroll` | int ≥ 0 | 0 | `must be greater than or equal to 0` | D§14 |
| `desktop.pane_view` | Agents pane tab | `pane_view` | enum cards · timeline · changes | `"cards"` | `is invalid` | D§14 |
| `desktop.agents_view` | Agents layout | `agents_view` | enum tree · grid | `"tree"` | `is invalid` | D§14 |
| `desktop.agents_density` | Agent card density | `agents_density` | enum full · compact | `"full"` | `is invalid` | D§14 |
| `desktop.side_w_2col` | Side chat width, two columns (px) | `side_w_2col` | int 320–1200 | 440 | `must be greater than or equal to 320` / `must be less than or equal to 1200` | D§14 |
| `desktop.side_w_3col` | Side chat width, three columns (px) | `side_w_3col` | int 320–1200 | 380 | as above | D§14 |
| `desktop.pane_w` | Agents pane width (px) | `pane_w` | int 300–1200 | 420 | `must be greater than or equal to 300` / `…1200` | D§14 |
| `desktop.composer_h` | Composer height (px) | `composer_h` | int 44–900, nullable `grows with the text` | null | `must be greater than or equal to 44` / `…900` | D§14 |
| `desktop.side_composer_h` | Side composer height (px) | `side_composer_h` | int 44–900, nullable | null | as above | D§14 |
| `desktop.prompt_size` | Prompt drawer size | `prompt_size` | enum sm · md · lg | `"md"` | `is invalid` | D§14 |

The desktop key rows use U3's `KeyCapture` editor in *desktop mode* (§3.7.8): a modifier is required except
`Escape`; `meta` is written for ⌘ — a terminal cannot report ⌘, so the capture offers `Ctrl` and the
row's detail offers a typed combo (`meta+shift+s`) as the fallback; `r` resets one action; `▸ Reset all
desktop keys` writes `{}`.

### 2.21 Files & environment (`files_env`, U3) — facts and checks

| id | label | source | shows | actions |
|---|---|---|---|---|
| `files.cli_json` | cli.json | client: `Release.preferences_path/0` | path, mode (`0600 ✓` / `✗ 0644: others can read it`), size / 64 KB, `changed on disk since this session read it`, unknown keys (listed, kept) | `▸ Make it private` (a no-change rewrite, 0600, owned work), `y` copy, `o` open folder, `e` edit in the editor: a private 0600 copy is edited; on return it is parsed with `CliFile.read_all/1` rules — not JSON → `cli.json is not valid JSON (line L) · e edit again · d discard your edit` and the file is not replaced; known keys with bad values are listed as warnings (`theme: is invalid · the default is used`) and the text is still written as typed (CAS on the fingerprint read before the edit; a changed file → the §3.7.9 file conflict) |
| `files.database` | Database | daemon facts | path, size | `y`, `o` |
| `files.config_dir` | Config folder | daemon facts (`Paths.config_dir/0`) | path | `y`, `o` |
| `files.log` | Log | client launch facts (`~/Library/Logs/SwarmCode/cli.log`, Linux `$XDG_STATE_HOME/swarm-code/cli.log`) | path, size | `y`, `o` |
| `files.project_dir` | This project's `.swarm_code/` | daemon facts | path | `y`, `o` |
| `files.research` | Research folder | daemon facts | path | `y`, `o` |
| `files.user_agents` | Your agent definitions | daemon facts (`~/.swarm_code/agents`) | path | `y`, `o` |
| `env.*` | Environment | client launch facts + daemon facts | every variable of §2.25 list B that is set, its value (secrets `set`), the setting it overrides (`Enter` goes there); developer variables only when set, headed `developer` | Enter |
| `launch.*` | This launch | client launch facts | flags, conversation, project | — |
| `terminal.*` | This terminal | `Capabilities` | size, colour mode, glyph tier, ambiguous width, paste, focus, wheel, enhanced keys, `TERM`, `TERM_PROGRAM` | — |
| `versions` | Versions | client + daemon facts | CLI version, service version, protocol body version, OTP, Elixir | `y` copies all |
| `files.doctor` | ▸ Check everything | task `doctor` + client checks | checklist `✓`/`✗` | Esc stops waiting |

### 2.22 Import & export (`import_export`, U3)

| id | label — description | scope | call | parity |
|---|---|---|---|---|
| `transfer.export` | ▸ Export settings… — path (default `~/swarmcode-settings-YYYY-MM-DD.json`), scope toggles: global values · terminal (cli.json) · this project (approvals, families) · providers (no keys) · search providers (no keys) · MCP servers (every env/header value written as `"<secret: set>"` unless the toggle *include plain MCP values* is on, default off; secret values by `SecretPattern.secret_kv?/2` are always `"<secret: set>"`) · pricing · language servers · desktop keys. Never secrets. Atomic write, 0600. | A | task `export` (client sends its cli.json values in `attributes.terminal`) | NEW |
| `transfer.import` | ▸ Import settings… — reads a file, validates it against the registry, shows `key · now · after` with ticks (sketch §4.15), applies the ticked rows (scalars as one undoable batch; records are matched by name/kind and never carry keys: `paste the key after import`); > 20 changes needs the table as its confirmation | A | tasks `import.preview`, `import.apply` (+ client-side cli.json apply) | NEW |
| `transfer.reset_everything` | ▸ Reset everything to defaults… — typed confirmation `reset`; clears cli.json keys (keeps unknown keys) and writes every global scalar's default; never touches secrets, records, sessions or projects | A | `values.reset` with `scope: "all"` + client cli.json reset | NEW |

Each section page ends with a **danger** group containing `▸ Reset this section…` (asks, lists the
values that change; undoable as one step) when the section has resettable scalars.

### 2.23 Record kinds and their fields

Record kinds are declared in the core registry (`SwarmCode.Settings.RecordKind`, §3.2.5); the client
decodes records generically against these declarations. *edit* = how the TUI edits the field; *svc*
messages come from the service (S2), others from the desktop changeset or `cli` checks.

**provider** (table `providers`; S2 `Settings.Providers`; U2 Providers page; parity D§4)

| field | wire | edit | validation | notes |
|---|---|---|---|---|
| `id` | uuid | — | — | never drawn |
| `name` | string ≤ 120 | text, instant | `can't be blank`; `has already been taken` | shown in model labels `<name> · <model>` |
| `kind` | `"openai_compatible"` \| `"anthropic"` | enum, instant | `is invalid` | built-in effort levels follow the kind; custom levels stay (toast says so) |
| `base_url` | string | text (URL), instant | `can't be blank`; `must start with http:// or https://` | trimmed, trailing `/` stripped; localhost/private allowed (`local` tag); a change clears the last test result |
| `api_key` | secret `{set, hint}` | paste target → `provider.set_key`; `x` → `provider.clear_key` (asks) | none (an empty key is valid for local servers) | no key yet (and in drafts): save, then test automatically; a key already set: **test first** (`provider.set_key` with `attributes.test_first: true`, §3.5.1) — `◷ checking the new key…`; success saves (`DeepSeek API key replaced · the new key listed 12 models`); a refusal keeps the old key: `The new key was refused (401). s save it anyway · Esc keep the old key` |
| `models` | [string] ≤ 2 000 (§3.12) | list editor (a x J K), instant, only visible rows projected, `/` filters in place (D37); `f` fetch → difference → apply | trimmed, blanks dropped, duplicates `already in the list`, `2 000 models at most` | order = the order given |
| `default_model` | string \| null | model picker limited to this provider, or typed; instant | — | the provider's own model when a pair names only the provider (`Providers.effective_model/2`'s fallback) |
| `fallbacks` | bool | toggle, instant; **shown only for `anthropic`** | — | "Fallback on a refusal" (server-side refusal fallback) |
| `effort_levels` | [level] \| null | sub-page draft, `Ctrl-S` | `Efforts.validate/1` per row | null = built-in levels of the kind |
| `model_effort_levels` | {model: [level]} ≤ 64 models | sub-page, per-model scope | `must be a map of model to levels` + per row | a model's override |
| `updated_at` | iso8601 | — | — | CAS token for delete |
| derived | `usable`, `models_count`, `last_test`, `last_fetch` (`{state, at, count, ms, message}` this session), `used_by` (`{defaults: [registry keys], research: [registry keys], conversations: n, scheduled_tasks: n}` — record view only), `caps` (`{effort_rejected, prefix_cache_rejected, fallbacks_rejected}` this session, from `ProviderCaps`), `builtin_levels`, `presets` (record view) | — | — | — |

Record actions: `▸ Test connection` (`t`, task `provider.test`), `▸ Fetch models` (`f`, task
`provider.fetch_models` → difference → `a` apply all / `+` add new only / Esc keep; a list longer than
2 000 offers only `+`, D39), `▸ Use <name> · <model> for new chats` (usable providers with a default
model, §2.3), `▸ Forget what this session learned` (only when a cap was rejected;
`provider.forget_caps`), `▸ Delete this provider…` (`D`, F12: in-use counts, a replacement picker for
every default it serves, `not undoable`).

**effort_level** (inside `provider.effort_levels` / `model_effort_levels`; U2 sub-page; D§4d)

| field | wire | validation (exact, from `Efforts.validate/1` / `from_rows/1`) |
|---|---|---|
| `key` | string | `key: lowercase letters, digits, - or _ (24 max)`; `key: already used` |
| `label` | string (blank → `Efforts.label(key)`) | — |
| `hint` | string | — |
| `body` | JSON object (edited as multi-line JSON) | `body: must be a JSON object`; `body: <JSON parse error>` (line and column shown) |
| `drop` | [string] | list of top-level keys |

Presets (`effort_preset`: `id, name, kinds, levels`) come from `Efforts.presets/0` filtered by the
provider's kind (14 presets, D§4d).

**search_provider** (table `search_providers`, one per kind; S2 `Settings.Search`; I§2)

| field | wire | edit | validation | notes |
|---|---|---|---|---|
| `kind` | `tavily` `exa` `brave` `serper` `jina` `firecrawl` | — | — | label and hint per I§2.3 |
| `role` | `engine` \| `reader` | — | — | readers have no order |
| `enabled` | bool | `Space`, instant | `is needed to enable <kind>` (enabling a key-needing kind without a key — the TUI opens the key paste first) | engines only matter for `web_search`; a reader's `enabled` is not read (the row says so) |
| `api_key` | secret `{set, hint}`, `needs_key` | paste → `search.set_key` (test first when a key is already set, as `provider.api_key`); `x` → `search.clear_key` (asks; NEW: the desktop cannot clear) | — | Jina: optional |
| `base_url` | string \| null (`default_base_url` shown faint) | text, instant; blank = default | cli: `must start with http:// or https://` | trimmed, trailing `/` stripped |
| `position` | int | `J`/`K` on engines → `search.move` | — | fallback order |
| derived | `last_test` (`{state, at, count, ms, message}`) | — | — | — |

Record action: `▸ Test search` (`t`, task `search.test`): engines `searches "swarmcode deep research test"
· uses 1 search from your <Label> plan`, readers `reads example.com`.

**mcp_server** (table `mcp_servers`; S2 `Settings.MCP`; I§1, D§6)

| field | wire | edit | validation | notes |
|---|---|---|---|---|
| `id`, `updated_at` | uuid, iso | — | — | — |
| `name` | string ≤ 64 | staged (D8) | `can't be blank`; `has already been taken`; `shares the tool prefix mcp__<slug>__ with "<other>"`; cli `should be at most 64 character(s)` | tool prefix `mcp__<slug>__` shown |
| `enabled` | bool | `Space`, instant (`mcp.toggle`) | — | off stops the client at once |
| `project_id` | uuid \| null | scope picker `every project` · `<project> only`, staged | svc: `no such project` | never changed implicitly (D23) |
| `transport` | `stdio` \| `http` | enum, staged | `is invalid` | rows below follow it |
| `command` | string | text + PATH check, staged | `is required for stdio servers` | stdio |
| `args` | [string] ≤ 64 | one line shell-quoted **or** list editor (exact argv), staged | — | stored as the list; never re-joined and re-split |
| `env` | [{name, secret, value \| null, hint}] ≤ 64 | key-value editor, staged; secret values paste-only; `s` on a shown entry = *treat as secret* (this session only: the value is masked from then on and the row becomes a paste target) | cli: `use a variable name: A–Z, 0–9 and _`; `already in the list` | secret = `SecretPattern.secret_kv?/2` (§3.2.5): the desktop's `Server.secrets/1` rule, or the name matches `env_name_regex`, or the value starts with a known token prefix, or holds `://user:password@` |
| `url` | string | text, staged | `is required for http servers`; `must start with http:// or https://` | http |
| `headers` | [{name, secret, value \| null, hint}] ≤ 64 | key-value, staged | cli: `not a header name` (`^[A-Za-z0-9-]+$`); `already in the list` | same secret rule |
| `disabled_tools` | via tools | tool checklist `Space`; `A` all on, `N` all off (instant, undoable); `/` filters the checklist (D37) | — | no reconnect needed |
| derived | `status` (`ready`, `connecting`, `error`, `stopped`), `status_message`, `slug`, `tools_total`, `tools_enabled`, `tools` (record view: `mcp_tool` ≤ 512, §3.12), `output` (≤ 20 redacted lines) | — | — | — |

`mcp_tool`: `name` (raw), `published_name`, `description` (≤ 512), `enabled`, `read_only`.
Record actions: `▸ Test` (`t`, task `mcp.test`, probe without saving), `R restart now` (applies the
staged fields in one `mcp.update`, or reconnects when nothing is staged — task `mcp.reconnect`; a
disabled server answers `turn it on first`), `r` reverts the focused staged field (on the record head:
discards every staged field), `o` all server output (pager), `D` delete (asks: `Agents lose its N tools;
conversations that used them keep their history`).

**pricing_row** (map `settings.pricing`; S2 `Settings.Pricing`; D§5)

| field | wire | validation (exact desktop row texts) | notes |
|---|---|---|---|
| `model` | string ≤ 256 | `duplicate model`; blank row ignored | Tab completes from known model ids |
| `input`, `output` | number ≥ 0 (4 decimals in edit, 2 shown) | `input: must be a number ≥ 0` / `output: must be a number ≥ 0` | $ per M tokens |
| `cache_read`, `cache_write` | number ≥ 0 \| null | `cache read: must be a number ≥ 0` / `cache write: must be a number ≥ 0` | null shows the derived rate faint: read = input × 0.1 (× 0.025 for ids starting `claude-fable-5-1` / `claude-mythos-5-1`), write = input × 1.25 |
| `context_window` | int \| null | `context window: a whole number of tokens between 8000 and 2000000` | null = family default |

`unpriced_model`: `model`, `conversations_30d`, `in_defaults`.

**project** (table `projects`; S1 `Settings.Projects`): `id`, `name`, `root` (with `~`),
`approval_mode`, `trusted`, `trusted_at`, `prefixes`, `scratch`, `last_opened_at`, `current`.

**hook** (config.json `hooks.<event>[i]`; S2 `Settings.ProjectConfig`; I§5)

| field | wire | validation | notes |
|---|---|---|---|
| `event` | `session_start` \| `pre_tool_use` \| `post_tool_use` | — | three lists; order = run order (`J K`) |
| `command` | string | cli: `can't be blank` | a new or changed command asks (D14) |
| `matcher` | regex \| null | cli+svc: `not a valid regular expression: <reason>` | null = every tool; ignored for session_start |
| `timeout_ms` | int | `must be between 1 and 30000` | default 10 000 (the domain clamps; the TUI refuses instead) |
| `output_cap` | int | `must be between 1 and 16384` | default 4 096 bytes |

**profile** (config.json `profiles.<name>`): `name` (`\A[\w-]+\z`, 1..32 bytes: `1 to 32 letters, digits, _ or -`, unique
`already used`), `effort`, `swarm_effort` (effort keys or null, `has invalid format`), `model`,
`swarm_model` (model id strings — `/profile` writes them to the conversation's `chat_model` /
`swarm_model`).

**project_config** (meta): `path`, `exists`, `parse` (`ok` \| `invalid` \| `missing`), `error`
(`line L, column C: <reason>`), `fingerprint`, `top_level` (the four ignored keys), `denied`,
`unknown_keys`, `ignored_entries` (`[{path, reason, severity}]` ≤ 64, §3.5.8).

**file** (memory, instructions and library files; S2 `Settings.Files`): `file_kind` (`memory_project`,
`memory_global`, `instructions`, `command`, `agent`, `skill`, `workflow`, `project_config`), `ref` (opaque string,
§3.4.5), `path` (with `~`), `bytes`, `lines`, `fingerprint` (`{"sha256": hex, "size": n}` or
`{"missing": true}`), `editable_in_place` (≤ 16 384 bytes), `too_large` (> 262 144 bytes: external
editor only). The file view adds `content`. `instructions` files add `winner` (`AGENTS.md` \|
`SWARMCODE.md` \| `CLAUDE.md`, or `AGENTS.md` with `exists: false`), `exists` and `trusted`.

**command**: `name` (`lowercase letters, digits, ., _ or - (64 max)`), `scope` (`project` \|
`global`), `description`, `swarm`, `mode` (`plan` \| `build` \| null), `overrides_global`,
`shadowed_by_builtin` (the names `settings`, `config`, `prefs`), `path`.
Template = the desktop's (D§9).

**agent_def**: `name` (≤ 24), `tier` (`project` \| `user` \| `bundled`), `description`,
`tools_label` (`all tools` \| `no tools` \| comma list), `model`, `effort`, `prewalk`, `max_turns`,
`shadows` (tier) \| null, `shadowed`, `parse_error`, `path`. Template:
`---\nname: <name>\ndescription: What this agent is for\ntools: read_file,grep,find_files\neffort: medium\nmax_turns: 30\n---\nWrite the instructions this agent adds to its system prompt here.\n`.

**skill**: `name` (`^[A-Za-z0-9._-]+$`), `scope` (`project` \| `user` \| `builtin`), `description`,
`files`, `bytes`, `shadowed`, `path`. Template SKILL.md: `# <name>\n\nDescribe what this skill does in the first line.\n`.

**workflow**: `name` (`Workflows.valid_name?/1`), `scope` (`project` \| `user` \| `builtin`), `path`,
`smoke` (null \| `ok` \| error text). Created only by `/create-workflow` (link row); edit, delete and
smoke here.

**lsp_language** (task result `lsp.check`): `language`, `extensions`, `default`, `override`,
`effective`, `installed` (bool \| null), `executable`, `running` ([{project, count}]).

**storage_session** (from the measure cache): `id`, `title`, `project`, `updated_at`, `messages`,
`runs`, `bytes`, `running`, `open`, `pinned`, `deletable`, `reason`.

**model_option**: `provider_id`, `provider_name`, `provider_kind`, `model`, `price`
(`{input, output, cache_read, cache_write}` \| null), `context_window` \| null, `in_last_fetch`
(bool \| null when never fetched this session), `provider_default` (bool).

**usage_row**: `model`, `input_tokens`, `output_tokens`, `cost_usd` \| null.

**Task row kinds** (declared in `records.ex` like record kinds; `view=task` rows are decoded against
the kind of their action, with the same secret rules): `model_diff_row` (`provider.fetch_models`:
`model`, `change` new\|gone\|same, `conversations`), `import_row` (`import.preview`: `id`, `scope`,
`key_or_record`, `now`, `after`, `status`, `message`), `mcp_import_draft` (`mcp.import.read`: `name`,
`transport`, `command`, `args`, `env`, `url`, `headers` — env/headers in the masked wire form —
`conflict`, `unsupported`, `variables`), `plan_item` (`storage.plan`: `label`, `count`, `bytes`),
`check` (`doctor`: `id`, `ok`, `message`), `smoke_row` (`workflow.smoke`: `ref`, `name`, `smoke`), and
`lsp_language` above (`lsp.check`).

### 2.24 Not ported (with the reason)

| # | Desktop/app item | Why not | What the TUI shows instead |
|---|---|---|---|
| N1 | `settings.tavily_api_key` (legacy) | `Search.adopt_legacy_key/0` moves it into the Tavily row and nils it at every boot (CLI `DMN/boot.ex`); editing it would be undone at the next launch | nothing (the Tavily search provider row owns the key) |
| N2 | Editing `storage_last_cleanup_at` | written only by the retention sweep | read-only `storage.last_sweep` |
| N3 | Terminal notifications (bell, desktop notification, window title) | the Rust terminal port has no command for BEL/OSC 9/OSC 777/title (only OSC 52); adding one is a port wire change outside this pass | — (deferred; `focus_on_finish` stays a desktop row) |
| N4 | The desktop's 8 themes as terminal palettes | the CLI's colour contract is Carbon (CLI AGENTS.md "never invent a palette"); derived roles (faint, ghost, chips, lanes) need a design pass | `terminal.accent` + the desktop rows |
| N5 | macOS Keychain | the desktop stores keys in the database and has no Keychain code; both apps must read the same store (D6) | `stored in SwarmCode's database · shared with the desktop app` |
| N6 | Per-search-provider knobs (Tavily `search_depth`, Exa text length), `web_fetch` limits, private-host policy | hard-coded in synced domain/tool modules; no column; editing them needs domain edits (non-goal) | facts (`web.fetch_facts`) |
| N7 | MCP constants (backoff 5/15/60 s, ping 10 s, handshake 30 s, 16 MB caps, 20 output lines) | app env/constants in synced code | listed in the MCP record detail as facts |
| N8 | MCP import from `~/.codex/config.toml` | needs a TOML parser dependency (CLI AGENTS: no casual deps) | `.mcp.json` import (§2.7) |
| N9 | Database path, config dir, research root, backups folder | paths chosen by the app; moving them is a migration | facts with `y` copy / `o` open |
| N10 | `LLMOTIONS_API_KEY` seeding | boot-time seed of an empty providers table only | env fact |
| N11 | Per-conversation `bench_layout` override | lives in the desktop's in-memory UIState, not the database | `desktop.bench_layout` |
| N12 | Scheduled-task *form* defaults (kind, mode, 09:00, timezone, colour) | defaults of the desktop's schedule form, not settings | — |
| N13 | Fixed client tunables: double Ctrl-C window 1.5 s, prompt history bounds, frame interval, request deadlines, watch/queue/transcript byte bounds, bare-Esc 40 ms, slash popup rows, companion open wait, log file size | safety (the quit ladder), memory bounds (AGENTS resource rules), the pass-70/72 layout contracts, or the Rust port | listed in help/docs, not settings |
| N14 | Side panel width in cells | the panel widths are the R13 layout contract; only the panel mode (full/compact/hidden) is a preference | `terminal.panel` |
| N15 | The 120-column narrow threshold and the overlay's narrow threshold | the size classes are the geometry contract (T§6, R17) every frame and scene test is drawn against; a movable threshold makes them untestable | — |
| N16 | Transcript timestamps, prose wrap width | the transcript row grammar has no time column and prose wraps to the pane width; either is a transcript redesign, not a preference | — |
| N17 | Enter sends vs Enter breaks the line | the second key it would need (Shift-Enter, Ctrl-Enter) cannot be reported without the enhanced keyboard protocol the CLI never enables (§3.9.3); the composer's existing line-break key stays | — |
| N18 | Alternate screen off | the full-screen contract (the pass-72 overlay, this layer, the scene paint) needs the alternate screen | — |
| N19 | Confirm quit while runs are live | the quit ladder (double Ctrl-C within 1.5 s, N13) is the confirmation; a second stage changes a safety contract. Only a running non-cancellable settings task asks (§4.8) | — |
| N20 | Budget "warn at %" | the budget is display-only in both apps (D§13); a CLI-only warning threshold has no desktop counterpart; the gauge shows the spend | `budget.month` gauge |
| N21 | Log level | the release's log handler level (`:info`) is part of the redaction contract (§3.11 rule 6); debug logging is a developer tool | `files.log` path fact |
| N22 | Companion port | the companion binds a fresh loopback port per launch (`port: 0`); a fixed port collides between sessions | the companion URL in `launch.*` facts |
| N23 | Run a hook once from settings (I§5.5 candidate) | a hook runs for an engine event (`SWARMCODE_TOOL`, the matcher against a tool name, exit 2 blocks a tool) inside the run tree (`Hooks.run/3`); outside a turn there is no event to run it for | the hooks table and AT9 |
| N24 | Hint leader as its own setting | it is the `hint_mode` binding, remappable on Key bindings (D19) | Key bindings |

### 2.25 Deliberately not settings; environment variables shown as facts

Not settings (T§5.23): the approval letters and card grammar; Esc, Ctrl-C, F1; showing or copying a
secret; the honesty rules; the panel lane window and cells; colour meanings; test/developer variables.

**List B — variables Files & environment shows** (value shown unless secret; *→* the setting it feeds):
`SWARM_THEME` → terminal.theme · `SWARM_MOUSE` → terminal.mouse · `SWARM_KEYMAP` → terminal.keymap ·
`SWARM_ASCII` → terminal.glyphs · `NO_COLOR`, `COLORTERM`, `TERM`, `TERM_PROGRAM` → terminal.colors /
glyphs · `VISUAL`, `EDITOR` → terminal.editor · `SWARM_COMPANION` → terminal.companion ·
`SWARM_CONVERSATION` → terminal.startup_conversation · `SWARM_PROJECT_ROOT` (dev launchers) ·
`SWARM_MODEL_OVERRIDE` (`--model`) → session.model · `SWARM_MODEL`, `SWARM_PROVIDER`, `SWARM_BASE_URL`,
`SWARM_API_KEY`*, `OPENAI_API_KEY`*, `OPENAI_BASE_URL`, `OPENAI_MODEL`, `ANTHROPIC_API_KEY`*,
`ANTHROPIC_BASE_URL`, `ANTHROPIC_MODEL` → first-run onboarding (providers) · `SWARM_EFFORT`,
`SWARM_APPROVAL` (unsaved sessions) · `LLMOTIONS_API_KEY`* (seed) · `SWARM_ENV_FILE` · `SWARM_CODE_CONFIG_DIR`
→ files · `SWARM_CODE_SHELL` → shell.path · `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`,
`XDG_RUNTIME_DIR`, `XDG_CACHE_HOME` (Linux) · `TMPDIR` (temporary copies for external edits). `*` = secret: shown `set` / `not set`. Any variable whose name matches
`(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)` (case-insensitive) is secret.
**Developer** (listed only when set, never editable): `SWARM_TEST_EXPECTED`, `SWARM_SCENE_DUMP`,
`SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT`, `SWARM_CODE_DEMO_AUDIT_FD`, `SWARM_RELEASE_TUI`,
`SWARM_RELEASE_MODE`, `SWARM_PERSISTED`, `SWARM_CODE_UPSTREAM`, `SWARM_TERMINAL_PORT`,
`SWARM_USER_UMASK`, `SWARM_PLAIN_FORMAT`, `SWARM_SETTINGS_OPEN`, `SWARM_SETTINGS_ONLY`.

### 2.26 Coverage check (nothing from the desktop page is missing)

**The 79 settings-row fields** (`DOM/settings/setting.ex`) → registry: `theme`, `mode`,
`reduce_motion`, `show_reasoning`, `focus_on_finish`, `sidebar_show_global_tasks`, `bench_layout`,
`consensus_layout`, `keybindings` (9 entries), `sidebar_collapsed`, `sidebar_width`,
`sidebar_sections`, `sidebar_scroll`, `pane_view`, `agents_view`, `agents_density`, `side_w_2col`,
`side_w_3col`, `pane_w`, `composer_h`, `side_composer_h`, `prompt_size` → `desktop.*`;
`default_effort`, `default_swarm_effort`, `default_scheduled_effort`, `default_workflow_effort`,
`default_implementer_effort` → `efforts.*`; `default_{chat,swarm,scheduled,workflow,implementer}_provider_id`
+ `_model` → `models.*`; `monthly_budget_usd` → `budget.monthly_usd`; `max_concurrent_agents`,
`max_agent_depth`, `max_agent_turns`, `sub_agent_timeout_s`, `workflow_budget`, `workflow_max_live`,
`command_timeout_ms`, `tool_timeout_ms` → `limits.*`; `worktrees_enabled`, `isolation_backend` →
`isolation.*`; `shell_env_scrub`, `shell_env_keep`, `shell_path`, `shell_login` → `shell.*`;
`pricing` → `pricing_row` records; `research_level`, `research_max_live`, `research_max_sources`,
`research_recency_days`, `research_include_domains`, `research_exclude_domains`,
`research_auto_design`, `research_headlines`, `research_agent_timeout_s`, `research_retry_timeouts`,
`research_max_retries`, `research_{lead,worker,reporter}_{provider_id,model,effort}` → `research.*`;
`research_reader` → `web.reader`; `storage_retention_days`, `storage_prune_days` → `storage.*`;
`storage_last_cleanup_at` → `storage.last_sweep` (fact); `lsp_servers` → `lsp.*`; `tavily_api_key` →
N1. (`id`, `inserted_at`, `updated_at` are not settings.)

**Desktop sections** → CLI sections: General → Models & effort (+ Fetch all); Deep research → Search &
web (search providers, reader) + Deep research; Appearance → Desktop app (+ terminal Appearance);
Providers & models → Providers (+ effort levels); Pricing → Pricing; MCP servers → MCP servers; Memory →
Memory & instructions; Storage → Storage; Commands → Library › commands; Keybindings → Desktop app › keys (+ terminal
Keys & input); Agents → Library › agent definitions (all three tiers, fixes D§18 #12); Limits → Agents &
limits (+ always-allowed commands → Approvals & trust); Budget → Budget & usage. Outside the page but
ported: the workspace editor's instructions file (I§9.2) → Memory & instructions; `.swarm_code/config.json`
(I§5) → Project file; `lsp_servers` (I§4, no desktop UI) → Language servers.

**The 32 desktop action controls** (D§17) → CLI: 1 fetch all → `models.fetch_all`/`providers.fetch_all`;
2 save defaults → instant model rows; 3–5 search move/save/test → search record; 6 research limits →
instant rows; 7 domains add/remove → list editor; 8 research models → tier rows; 9 open research folder →
`o`; 10–13 provider add/edit/show-key/fetch/efforts/delete → provider record + sub-page (no show-key:
D6); 14 pricing → pricing rows; 15–21 MCP add/edit/test/reconnect/toggle/tool/delete/folds → MCP
record; 22 memory → Memory; 23–25 storage measure/retention/cleanup → Storage; 26 commands open/new →
Library; 27 keybindings → Desktop app keys; 28–29 limits/approved commands → Agents & limits, Approvals
& trust; 30 budget → Budget; 31 appearance → Desktop app; 32 effort selects → `efforts.*`.

**Conversation columns** reachable (A§1.13): `mode` + `ultra` + `consensus` + `authoring_workflow`
(together, `session.mode`, D35), chat/swarm/judge/implementer provider+model, `effort`, `swarm_effort`,
`judge_effort`, `implementer_effort`, `consensus_checks`, `consensus_rounds`, `title`, `pinned_at` →
`session.*`. **Files**: MEMORY.md (project, global), the project instructions file (I§9.2) → Memory &
instructions.
**Project columns**: `approval_mode`, `trusted_at`, `auto_approve_prefixes`, `name` → `project.*`;
`root_path`, `last_opened_at` facts; `scratch` hidden.

---

## 3. Architecture

### 3.1 Shape and module map

```
                     core (both sides)                         SwarmCode.Settings.Registry  (entries, record kinds,
                                                               sections, validators, wire values, secret patterns)
UI (client, pure)                          wire (socket)                         daemon (SVC/)
┌────────────────────────────┐   settings.query  ┌──────────────────────────────┐   ┌──────────────────────────────┐
│ Reducer.Settings / Layer   │ ───────────────▶  │ PersistedBackend              │──▶│ Service.Settings (facade)     │
│ sections (U1/U2/U3)        │   settings.command│  jobs · ledger · tasks ·      │   │  Values (S1) · Router          │
│ editors · search · undo    │ ◀───────────────  │  settings_update/_task deltas │   │  handlers (S2): Providers …    │
│ Projector.Settings         │  result frames:   │  topic subscriptions           │   │  → SwarmCode.Domain.* (as is)  │
└─────────────┬──────────────┘  settings_snapshot└──────────────────────────────┘   └──────────────────────────────┘
              │                 settings_result
              │ {:settings_cli_write|read} effects
┌─────────────▼──────────────┐                    REL: swarmcode settings / swarmcode config (calls Service.Settings
│ SessionRuntime → Preferences│  cli.json (0600)    directly for DB layers and SwarmCode.Settings.CliFile for cli.json)
└────────────────────────────┘
```

| Area | Files | Owner |
|---|---|---|
| Registry | `CORE/settings/{entry,record_kind,sections,validate,wire_value,text_value,secret_pattern,registry,wire_bounds,cli_file}.ex`, `CORE/settings/registry/{models,research,web,limits,session,project,project_file,lsp,storage,budget,desktop,facts,actions}.ex` | S1 |
| Registry (terminal entries) | `CORE/settings/registry/terminal.ex` | S1 creates by `c74-S1-core`, **U3 owns after `c74-U1-api`** (S1 does not edit it after `c74-S1-core`) |
| Registry (record kinds) | `CORE/settings/registry/records.ex` | S1 creates by `c74-S1-core`, **S2 owns after** |
| Protocol | `CORE/protocol/service_request.ex`, `CORE/protocol/service_handshake.ex` | S1 |
| Daemon frame | `SVC/settings.ex`, `SVC/settings/{context,command,result,error,task_spec,handler,router,values,layers,cas,tasks,task_cache,probe_runner,deltas,overview,facts,usage,projects,transfer,doctor,wire}.ex` | S1 |
| Daemon handlers | `SVC/settings/{secrets,providers,efforts,models,pricing,search,mcp,mcp_import,storage,lsp,files,library,project_config}.ex` | S2 |
| Backend wiring | `SVC/persisted_backend.ex`, `SVC/live_backend.ex`, `SVC/connection.ex`, `DMN/service.ex`, `SVC/feature_request.ex`, `SVC/session_configuration.ex` | S1 |
| Client wire | `UI/data_source/{request,delta,daemon}.ex`, `UI/data_source/daemon/codec.ex`, `UI/effect_runner.ex`, `UI/data_source/dto/{schema,settings_snapshot,settings_value,settings_record,settings_file,settings_result,settings_update,settings_task,settings_open,settings_task_view}.ex`, `UI/data_source/dto/{workspace_metadata,workspace_snapshot}.ex` (R5 and `chat_provider`, S1-11), `UI/data_source/fake.ex`, `UI/data_source/fake/settings.ex` (values, overview, facts, projects, generic task lifecycle, a data-driven record store); **`UI/effect.ex` only for the one clause `{:command, %Request{expected_response: :settings_result}}` in S1-6** (U1 owns the file after merging `c74-S1-wire`, §5.0) | S1 |
| Client shell | `UI/settings/*.ex` except the U2/U3 files below, **including `UI/settings/sections/overview.ex`**; `UI/reducer/settings.ex`; `UI/projector/settings.ex`, `UI/projector/settings/*.ex`; edits of `UI/{state,reducer,projector,keymap,init,hint,field_key,effect,session_runtime,slash_palette,switcher,library,layer_spec}.ex`, `UI/keymap/{bindings,context,docs}.ex`, `UI/init/preferences.ex` (a wrapper over `CliFile`), `UI/layout/preferences.ex`, `UI/reducer/display.ex`, `UI/projector/{status,dialog,composer,hive_strip}.ex`, `UI/renderer/ratatui_port/owner.ex` (only its `format_status/1`, §3.11), `docs/keybindings.md` | U1 |
| Keymap overrides | `UI/keymap/overrides.ex`, `UI/keymap/key_name.ex` | U1 creates pass-through by `c74-U1-api`, **U3 owns after** |
| Integration sections | `UI/settings/sections/{providers,pricing,search_web,mcp,language_servers,storage,memory,library}.ex`, `UI/settings/{model_picker,effort_levels,cleanup_wizard,key_value_secrets,mcp_import}.ex`, `UI/data_source/fake/settings_integrations.ex` (the Fake's simulation of the S2 actions: providers, efforts, models, pricing, search, MCP, storage, LSP, files, library, project config) | U2 |
| General sections | `UI/settings/sections/{models_effort,deep_research,agents_limits,approvals,project_file,appearance,layout,keys_input,session_startup,budget_usage,desktop_app,files_env,import_export}.ex`, `UI/settings/editors/{key_capture,color}.ex`, `UI/theme.ex`, `UI/capabilities.ex`, `REL/terminal_preferences.ex`, `UI/projector/workspace/turns.ex` (only `@diff_preview` → `prefs["diff_lines"]`) | U3 |
| Launcher, headless, docs | `apps/swarm_code_cli/lib/swarm_code_cli/release.ex`, `REL/persisted_session.ex`, `REL/config_command.ex`, `rel/overlays/bin/swarmcode`, `apps/swarm_code_cli/lib/mix/tasks/swarm_code.settings.ex`, `docs/settings.md` | S1 |

**Hand-offs** (a file created by one owner and owned by another after an interface tag) are the only
shared files; after the tag the creator never edits it again: `CORE/settings/registry/terminal.ex` (S1
→ U3), `CORE/settings/registry/records.ex` (S1 → S2), `UI/keymap/{overrides,key_name}.ex` (U1 → U3),
and `UI/effect.ex` (one S1 clause in S1-6, then U1). `records.ex` at `c74-S1-core` carries **every
field of §2.23** as this revision specifies it; S2's later edits are additive and never add a field the
client would receive without first noting it (`notes/S2.md`) — the client decoder rejects unknown record
fields (§3.4.6 rule 2), so U2's `Fake.SettingsIntegrations` emits only §2.23 fields. `Fake.Settings` dispatches every action it does
not simulate itself to `Fake.SettingsIntegrations` (U2) when that module is loaded, else answers
`unsupported` — so S1 never simulates S2's behaviour. Cross-module references to modules an
owner does not have yet use `@compile {:no_warn_undefined, [...]}` plus `Code.ensure_loaded?/1`
fallbacks (the pattern `release.ex` already uses), so every branch compiles with
`--warnings-as-errors` on its own.

### 3.2 Core registry (S1; `SwarmCode.Settings.*`, pure data, no dependencies beyond Elixir)

#### 3.2.1 `SwarmCode.Settings.Entry`

```elixir
defmodule SwarmCode.Settings.Entry do
  @enforce_keys [:key, :id, :section, :label, :scope, :storage, :type]
  defstruct [
    :key,                 # "limits.max_concurrent_agents" — ^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$, ≤ 64 bytes, unique
    :id,                  # :limits_max_concurrent_agents (compile-time atom, unique)
    :section,             # a SwarmCode.Settings.Sections id atom
    :label,               # ≤ 40 chars (desktop label where one exists)
    :scope,               # :global | :session | :project | :cli | :project_file | :fact | :action | :link
    :storage,             # §3.2.2
    :type,                # §3.2.3
    group: nil,           # lowercase heading inside the page, ≤ 24 chars
    description: "",      # ≤ 400 chars, consequence first, no "Note:"
    choices: [],          # [%{value: wire, label: String.t(), hint: String.t() | nil}]
    dynamic_choices: nil, # nil | {:effort_of, :chat_default | :swarm_default | :scheduled_default | :workflow_default | :implementer_default | :session_chat | :session_swarm | :session_judge | :session_implementer | :research_lead | :research_worker | :research_reporter}
    item: nil,            # :domain | :env_name | :command_family | :model_id | :text (for :list)
    min: nil, max: nil, step: 1, big_step: nil,   # big_step: Shift-←/→ (and PgUp/PgDn in an open number editor); set for every numeric entry whose range exceeds 50 steps
    unit: nil,            # stored unit: :ms | :s | :days | :usd | :rows | :lines | :letters
    special: %{},         # %{0 => "no limit"}
    nullable: false, null_label: nil,
    default: nil,         # wire value
    example: nil,         # a valid wire value ≠ default (tests, docs, `swarmcode config` help); for :model entries a symbolic
                          #   {:model, "DeepSeek", "deepseek-v4-pro"} resolved against Appendix A by the tests
    layers: [],           # strongest first, subset of [:flag, :env, :session, :project, :cli, :global, :project_file, :default]
    home: nil,            # the layer writes go to; nil for :fact/:action/:link
    env: [],              # variable names feeding :env
    flag: nil,            # "--model"
    follows: nil,         # key of another entry whose value is this entry's :global layer (terminal.theme → "desktop.mode")
    applies: :at_once,    # :at_once | :next_turn | :next_spawn | :next_request | :next_research | :new_conversations | :new_clients | :restart | :next_launch | :desktop
    shared: false, desktop_only: false, scheduler_only: false,
    secret: false,
    resettable: true,
    confirm: nil,         # nil | {:escalate, [wire values]} | :always
    validate: [],         # §3.2.4
    messages: %{},        # validator atom => exact message (desktop strings)
    synonyms: [],         # search/deep-link words
    stored_name: nil,     # "max_concurrent_agents" / "cli.json \"panel\"" — detail line and search
    parity: nil,          # "D§12"
    since: :existing      # :existing | :c74
  ]
end
```

#### 3.2.2 Storage descriptors

| Descriptor | Meaning | Read | Write (service unless noted) |
|---|---|---|---|
| `{:setting, field}` | one settings-row column | `Repo.one(from s in Setting, order_by: s.inserted_at, limit: 1)` (fresh; never `Settings.get/0` on a read, it inserts a missing row — D24); no row → registry defaults | `Settings.get/0` then `Settings.update/1` inside the CAS transaction |
| `{:setting_pair, provider_field, model_field}` | model pair | both columns | both columns in one update; null → both nil |
| `{:setting_map, field, entry}` | one entry of `lsp_servers`/`keybindings` | `Map.get(map, entry)`; absent = null | fresh map; put or delete the entry; write the whole map |
| `{:conversation, field}` / `{:conversation_pair, pf, mf}` / `:conversation_pinned` | session columns | `Conversations.get/1` (fresh) | `Conversations.update/2`; pinned writes `pinned_at` now/nil |
| `{:conversation_mode}` | `session.mode` (D35) | the four columns → the mode by `consensus > ultra > authoring_workflow > mode == "plan" > build` | one `Conversations.update/2` with `%{mode: if(m == "plan", "plan", "build"), ultra: m == "ultra", consensus: m == "consensus", authoring_workflow: m == "workflow"}` (the `mode_fields/1` mapping, copied by value; a daemon test asserts both agree for the five modes) |
| `{:project, field}` / `:project_trust` | project columns | `Projects.get/1` (fresh) | `Projects.update/2`; trust → `Projects.trust/1`; untrust → D13 |
| `{:cli, json_name}` | cli.json key | `CliFile.read_all/1` (client through `Preferences`; `swarmcode config` directly) | `CliFile.write_changes/3` (§3.8.1) |
| `{:project_file_key, json_name}` | config.json top-level key | S2 `ProjectConfig` | removal only (S2) |
| `{:fact, source}` | read-only fact | facts/usage views or client launch facts | — |
| `{:action, action}` / `{:link, section, key}` | action / link row | — | — |

#### 3.2.3 Types and wire values

| Type | Wire value | Client editor (§3.7.8) |
|---|---|---|
| `:toggle` | boolean | toggle |
| `:enum` | string or integer from `choices` | segmented (≤ 5 choices that fit) else picker |
| `:checklist` | `[string]` (subset of choices, in choices order) or null (= defaults) | checklist |
| `:integer` | integer | number |
| `:duration` | integer in the stored `unit` | duration |
| `:money` | integer (whole dollars) or null | number with `$` |
| `:text` | string | text |
| `:list` | `[string]` | list (item kind from `item`) |
| `:model` | `{"provider_id": uuid, "model": string}` or null | model picker (U2 `ModelPicker`, text fallback) |
| `:effort` | string or null | enum with dynamic choices |
| `:path` | string or null | path |
| `:color` | `"#RRGGBB"` or null | color (U3) |
| `:lsp_command` | null, `"off"` or a command string | enum + text |
| `:combo` | web key combo string or null | key capture, desktop mode (U3) |
| `:keys` | `{binding_id: [key names]}` | key bindings sub-page (U3) |
| `:map_readonly` | map | read-only + reset |
| `:datetime` | ISO-8601 string or null | read-only |
| `:fact` | any bounded JSON | read-only |
| `:action`, `:link` | — | action row / link row |

`SwarmCode.Settings.WireValue`: `type_ok?(entry, value) :: boolean` (shape + bounds of the type, not the
rules), `equal?(a, b) :: boolean` (numbers compare numerically, maps compare key-sorted, lists in order),
`canonical(value)` (JSON-stable form used for CAS).

#### 3.2.4 Validators (data, checked by `SwarmCode.Settings.Validate.check(entry, wire_value) :: :ok | {:error, message}`)

| Validator | Rule | Message key → default message |
|---|---|---|
| `{:range, min, max}` | integer/number within | `:range` → `must be between MIN and MAX` |
| `{:special_or_range, specials, min, max}` | in specials or within | `:range` |
| `{:min, n}` / `{:max, n}` | Ecto-style | `must be greater than or equal to N` / `must be less than or equal to N` |
| `:inclusion` | value ∈ choices values | `is invalid` |
| `{:format, regex_source}` | `Regex.compile!/1` at compile time, stored as source | `has invalid format` |
| `{:max_length, n}` | `String.length ≤ n` | `should be at most N character(s)` |
| `:required` | non-blank | `can't be blank` |
| `:one_line` | no `\n`/`\r` | `one line only` |
| `{:list_max, n}` / `:unique_items` / `{:item, kind}` | list rules; item kinds: `:domain` (non-blank, no spaces after normalisation), `:env_name` (`^[A-Za-z_][A-Za-z0-9_]*$`), `:command_family` (non-blank, one line, ≤ 200 bytes), `:model_id`, `:text` | `too many items (N max)`, `already in the list`, per-kind messages of §2 |
| `:hex_color` | `#RRGGBB` after normalisation | `a colour such as #FF6A1A` |
| `:hint_letters` | §2.16 | §2.16 messages (checked in that order) |
| `:whole_dollars` | integer ≥ 0 | `must be a whole number of dollars, zero or more` |
| `{:svc, check}` | **service only** (client returns `:ok`): `:provider_exists`, `:executable_path`, `:effort_of_model`, `:known_checks`, `:not_dangerous`, `:not_scratch`, `:combo_conflict`, `:project_exists` | messages in §2 |

`Validate.normalise(entry, value)` applies the desktop normalisations before checking (domains: split on
whitespace/commas, strip `http(s)://` and trailing `/`; env keep: split on commas, trim; hex: upper-case
`#RRGGBB`; URLs: trim, strip trailing `/`).

#### 3.2.5 Sections, record kinds, secret patterns

- `SwarmCode.Settings.Sections`: `all/0` → the 22 maps `%{id, title, group, synonyms}` in rail order
  (§1.3 D4); `groups/0` → `[{nil, [:overview]}, {"models", […]}, {"tools", …}, {"agents", …},
  {"this terminal", …}, {"data", …}, {"more", …}]`; `fetch(string)` matches id, title or synonym
  case-insensitively with spaces/`-`/`_` folded (`"mcp"`, `"search"`, `"keys"`, `"keybindings"`,
  `"theme"`→ appearance is **not** a synonym: `theme` resolves to the key `terminal.theme`).
- `SwarmCode.Settings.RecordKind`: `%RecordKind{name: "provider", fields: [%Field{name, type, secret,
  max, editable}]}` for every kind of §2.23; `fetch(name)`.
- `SwarmCode.Settings.SecretPattern`: `kv_key_regex/0` (`(authorization|cookie|api[-_ ]?key|apikey|token|secret|password|credential)`, caseless — the desktop's `Server.secrets/1` name rule, copied by value), `kv_value_regex/0` (`^(sk-[A-Za-z0-9_\-]{4,}|Bearer\s+\S{4,})$`, caseless — its value rule), `env_name_regex/0` (`(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)`, caseless), `token_prefixes/0` (`sk_live_`, `sk_test_`, `rk_live_`, `sk-ant-`, `sk-proj-`, `ghp_`, `gho_`, `ghu_`, `ghs_`, `github_pat_`, `glpat-`, `xoxa-`, `xoxb-`, `xoxp-`, `xoxr-`, `AKIA`, `ASIA`, `AIza`, `hf_`, `tvly-`), `userinfo_regex/0` (`://[^/@\s:]+:[^/@\s]+@`), `secret_kv?(name, value)` = the desktop rule OR `env_name_regex` on the name OR the value starts with a token prefix OR matches `userinfo_regex` (a strict superset of `Server.secrets/1`; used for display, search, undo, export and the client decoder), `desktop_secret_kv?(name, value)` (the desktop rule alone; used only by the daemon's log-redaction parity test), `hint(secret) :: String.t() | nil` (last 4 characters when `String.length(secret) >= 12`, else nil).

#### 3.2.6 `SwarmCode.Settings.Registry` API

```elixir
all() :: [Entry.t()]                       # rail order, then page order
fetch(key :: String.t()) :: {:ok, Entry.t()} | :error
fetch!(key)
by_stored_name(name :: String.t()) :: [Entry.t()]
for_section(section :: atom()) :: [Entry.t()]
scalar_keys() :: [String.t()]              # scope in [:global, :session, :project, :cli, :project_file]
cli_entries() :: [Entry.t()]               # scope :cli, with their json names
synonyms() :: %{String.t() => {:key, String.t()} | {:section, atom()}}
record_kinds() :: [RecordKind.t()]
export_version() :: 1
```

A compile-time check (in `Registry`'s `__before_compile__` or a module attribute pass) raises on:
duplicate keys or ids; bad key format; unknown section; `default`/`example` failing `Validate.check`
(non-`:svc` validators; symbolic model examples are skipped) for writable entries; `example == default`
for writable entries; `home ∉ layers`; enum default not in choices; a numeric entry with more than 50
steps and no `big_step`. Examples of `:svc`-checked entries are statically valid where possible
(`shell.path` → `"/bin/sh"`); `session.effort`-like entries use a level of Appendix A's model.

Choice lists copied by value from the domain are checked by daemon-side parity tests (S1-3): desktop
themes = `Settings.themes/0`; search kinds = `Search.engine_kinds/0 ++ Search.reader_kinds/0`; the 12
consensus checks = `Engine.Consensus.checks/0`; research levels = `Research.Levels.names/0`; LSP
languages and default commands = the `LSP.Language` defaults; isolation backends and bench/consensus
layouts = the `Setting` changeset's inclusion lists (where the domain keeps a list private, the test
probes the changeset with each registry value and one value outside it).

The registry holds the 170 entries of §2 (the 168 table rows of §2.2–§2.22 plus the two
language-server actions `lsp.check` and `lsp.stop`; settings, facts, actions) plus 19 record kinds
(incl. `mcp_tool`) and 6 task row kinds (§2.23); lookups use maps built at compile time. The S1-3 test prints the exact count.

`mix swarm_code.settings --write | --check` (cli app, S1) renders `docs/settings.md` from the registry:
per section, every entry's key, label, stored name, type/values/bounds, default, layers, applies,
description, parity; `CLIT/settings/docs_test.exs` fails when the file is stale (the pattern of
`keymap_docs_test.exs`).

### 3.3 The daemon settings service (S1 frame, S2 handlers)

#### 3.3.1 Facade

```elixir
defmodule SwarmCode.Daemon.Service.Settings do
  @spec query(view :: String.t(), params :: map(), Context.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec command(Command.t(), Context.t()) :: {:ok, Result.t()} | {:task, TaskSpec.t(), Result.t()} | {:error, Error.t()}
end
```

Both are plain functions over the domain, called from backend **jobs** (never inside the backend's
`handle_call`) and directly from `REL/config_command.ex`. They never raise to the caller: a rescue
becomes `%Error{code: :unavailable, message: "Couldn't read settings right now."}` and a log line with
the action name only. Rule (§3.12): no code running inside a `Repo.transaction` calls the backend
(`GenServer.call`), so a job holding the fixture's connection can never wait on the backend.

```elixir
@derive {Inspect, except: [:env, :task_results]}
%Context{project: %Project{} | nil,        # the session's project (nil in a scratch-less headless run)
         conversation: %Conversation{} | nil,
         live?: false,                      # true in LiveBackend (never reaches the facade: D28)
         override: term() | nil,            # SessionConfiguration's --model override, read-only
         env: %{String.t() => String.t()},  # only the §2.25 list-B names that are set (never the whole environment)
         task_results: %{{action :: String.t(), key :: term()} => map()},  # only the entries the Router declares for this action/view (§3.3.2)
         seen: %{settings: DateTime.t() | nil, providers: DateTime.t() | nil,
                 search_providers: DateTime.t() | nil, projects: DateTime.t() | nil},   # §3.3.3 cache hygiene
         settings_revision: non_neg_integer(),
         now: DateTime.t(), request_id: String.t(), origin: :tui | :headless}

%Command{action: String.t(), target: map(), attributes: map(), expected: map() | nil,
         secrets: [%{slot: String.t(), value: String.t()}],   # custom Inspect: secrets: [<slot>…] only
         dry_run: boolean(), request_id: String.t()}

%Result{status: :accepted | :unchanged | :conflict | :rejected | :needs_confirmation,
        results: [%{target: String.t(), status: :accepted | :unchanged | :conflict | :rejected | :skipped,
                    value: term(), current: term(), message: String.t() | nil}],   # ≤ 256 rows (values.patch) / ≤ 64 (others)
        record: map() | nil, message: String.t() | nil, task: %{task_id: String.t(), action: String.t()} | nil,
        confirm: nil | %{kind: String.t(), items: [String.t()]}}          # needs_confirmation only (§3.5.7)

%Error{code: :invalid | :not_found | :conflict | :unavailable | :busy | :unsupported,
       message: String.t(), field_errors: [%{target: String.t(), message: String.t()}]}   # ≤ 64

%TaskSpec{action: String.t(), key: term(),                     # {action, target}: a new task with the same key replaces the old
          timeout_ms: pos_integer(),                           # cancellable: the kill deadline; not cancellable: the reporting deadline (never kills)
          cancellable?: boolean(),
          kind: :plain | :probe | :file,                       # how cancel/timeout stop it (§3.3.8 rule 8)
          run: (report :: (map() -> :ok) -> {:ok, map()} | {:error, String.t()}),
          summary: (map() -> map()) | nil,                     # the ≤ 16 KB summary a delta may carry; nil = none
          redact: [String.t()]}                                  # @derive {Inspect, except: [:redact, :run, :summary]}
```

#### 3.3.2 Handler behaviour and router

```elixir
defmodule SwarmCode.Daemon.Service.Settings.Handler do
  @callback actions() :: [String.t()]
  @callback views() :: [{view :: String.t(), kind :: String.t() | nil}]
  @callback command(Command.t(), Context.t()) :: {:ok, Result.t()} | {:task, TaskSpec.t(), Result.t()} | {:error, Error.t()}
  @callback query(view :: String.t(), kind :: String.t() | nil, params :: map(), Context.t()) :: {:ok, map()} | {:error, Error.t()}
  @callback attention(Context.t()) :: [map()]   # §2.1 items: %{id, severity, section, target, title, reason}
  @callback glance(Context.t()) :: map()        # fragments merged into the overview glance
  @callback cache_reads(action_or_view :: String.t()) :: [{action :: String.t(), :all | :target | {:param, String.t()}}]
  @optional_callbacks attention: 1, glance: 1, cache_reads: 1
end
```

`Router` holds the static table below (no runtime module selection from input: the action string is
looked up in a compile-time map). Modules not loaded (`Code.ensure_loaded?/1` false) answer
`%Error{code: :unsupported, message: "This part of settings is not available in this build."}`.

| Action prefix / view kind | Module | Owner |
|---|---|---|
| `values.patch`, `values.reset`, `profile.apply`, `task.cancel`; views `values`, `overview`, `facts`, `usage`, `open`, `records:projects`, `records:usage_rows` | `Settings.Values`, `.Overview`, `.Facts`, `.Usage`, `.Projects`, backend (`task.cancel`) | S1 |
| view `task` (a task's state and result, paged) | the backend's task cache (`SVC/settings/task_cache.ex`), answered without a handler | S1 |
| `export`, `import.preview`, `import.apply`, `doctor` | `Settings.Transfer`, `Settings.Doctor` | S1 |
| `provider.*`; `records:providers`, `record:provider` | `Settings.Providers` | S2 |
| `efforts.*`; `records:effort_presets` | `Settings.Efforts` | S2 |
| `records:model_options` | `Settings.Models` | S2 |
| `pricing.*`; `records:pricing_rows`, `records:unpriced_models` | `Settings.Pricing` | S2 |
| `search.*`; `records:search_providers`, `record:search_provider` | `Settings.Search` | S2 |
| `mcp.*` (except import); `records:mcp_servers`, `record:mcp_server` | `Settings.MCP` | S2 |
| `mcp.import.read`, `mcp.import.apply` | `Settings.MCPImport` | S2 |
| `storage.*`; `records:storage_sessions` | `Settings.Storage` | S2 |
| `lsp.*` | `Settings.LSP` | S2 |
| `file.*`, `workflow.smoke`; `file`; `records:memory_files`, `records:commands`, `records:agent_defs`, `records:skills`, `records:workflows` | `Settings.Files` (memory, generic file ops) + `Settings.Library` (lists, templates, smoke) | S2 |
| `project_config.*`; `record:project_config` | `Settings.ProjectConfig` | S2 |
| `values.patch` changes whose storage is `{:project_file_key, _}` | delegated by `Values` to `Settings.ProjectConfig.remove_top_level/3` | S2 |

**Task-cache reads are declared, never pulled.** A handler that needs earlier task results names them
in `cache_reads/1` for the action or view; the Router merges the declarations with the table's module
and the backend copies **only those entries** into `ctx.task_results` when it admits the job (`:all` =
every entry of that action, as summaries; `:target` = the entry for the command's target; `{:param,
name}` = the entry whose key is the value of that attribute or option, e.g. `import_id`, `plan_id`,
`fetch_task_id`). Declarations: `records:providers`/`record:provider`/`overview` → `[{"provider.test",
:all}, {"provider.fetch_models", :all}]` (summaries: state, at, count, ms, message); `provider.apply_models`
→ `[{"provider.fetch_models", {:param, "fetch_task_id"}}]` (the full fetched list); `records:search_providers`
→ `[{"search.test", :all}]`; `records:storage_sessions`, `storage.plan` → the sessions store (rule 7b
of §3.3.8, not the LRU); `storage.run` → `[{"storage.plan", {:param, "plan_id"}}]`; `mcp.import.apply`
→ `[{"mcp.import.read", {:param, "import_id"}}]`; `import.apply` → `[{"import.preview", {:param,
"preview_id"}}]`; `records:workflows` → `[{"workflow.smoke", :all}]` (the `lsp_language` rows are the `lsp.check`
task's own result, read with `view=task`). No declaration = an empty map. A job never calls back into the backend for
cache data.

#### 3.3.3 Values: snapshot

`Values.snapshot(ctx, keys | :all)` reads once per request: the settings row (`Repo.one(from s in
Setting, order_by: s.inserted_at, limit: 1)` — fresh, never `Settings.get/0`, which inserts a missing row;
no row → registry defaults, D24), the context conversation (`Conversations.get/1`), the requested/page
project (`Projects.get/1`), the project file (via S2 `ProjectConfig.read_top_level/1`, guarded by
`Code.ensure_loaded?`), `ctx.env`, and the session override. For every scalar entry except `:cli` ones
it emits a **SettingValue**:

```json
{"key": "limits.max_concurrent_agents",
 "value": 6,                                   // the effective value; null when state is "invalid"
 "layers": [{"layer": "global", "value": 6, "set": true, "ignored": false, "raw": null, "source": null, "note": null},
            {"layer": "default", "value": 4, "set": true, "ignored": false, "raw": null, "source": null, "note": null}],
 "winner": "global", "writable": ["global"], "base": 6,
 "choices": null, "state": "ok", "note": null}
```

Layer rules: `flag` set when the override is active (`session.model` and `session.sub_agent_model`,
`source: "--model"`, note `for this launch only`); `env` set when a listed variable is present (value
shown, `source` = the name; secret names never carry a value); `session` set when the conversation
column is non-nil (`session.mode`: when the mode is not build); `project` always set for project
entries; `global` set when the column value ≠ the registry default (nullable: non-nil; map entries:
present); `project_file` set when the key is present in config.json; `default` always set.

**Ignored layers (D40).** A layer the runtime does not honour is emitted with `set: true, ignored:
true, value: null, raw: <the raw text or JSON, ≤ 200 bytes>` and a `note`: the four project-file keys
of D15 (`SwarmCode ignores this key`); an env/flag value outside the entry's value space
(`SWARM_CONVERSATION=<uuid>` on `terminal.startup_conversation`: `this launch opened one named
conversation`; `SWARM_KEYMAP=emacs`: `not a keymap; standard is used`). `winner` = the first layer in
`entry.layers` order that is set **and not ignored**. `base` = the home layer's current wire value (CAS
token). `writable` = `[home]` (D17).

**Normalisation and invalid values (D34).** Before `WireValue.type_ok?/2`, a float with no fraction
becomes an integer (`monthly_budget_usd = 50.0` → `50`). A stored value that still fails the type
(`theme = "nord"`, `research_max_live = 40`, `monthly_budget_usd = 12.5`) is emitted with `value: null,
state: "invalid", note: "the stored value <v> is not valid here; choose a new one"` (`<v>` = the raw
value's JSON, ≤ 40 characters), its layer carries `raw`, and `base` is the raw stored value so a reset
or an edit CASes against exactly what is stored. An invalid scalar never fails the snapshot.

`choices` for `dynamic_choices` = `Efforts.levels(provider, model)` of the model named by the source
(§2.2 rules: `{:effort_of, :chat_default}` uses `models.chat`, else `Providers.effective_model(%Conversation{},
:chat)` — never the private `Providers.fallback/0`; session sources use the conversation's effective
model after the `--model` overlay; global efforts add the classic four de-duplicated, D§1b), each
`%{value: key, label, hint}`; `research.level` choices carry hints from `Research.estimates/0`
(`median 4 min on this machine` / `not measured yet`). `state: "attention"` for AT4 and AT16 rows; `note`
for `scheduler_only` entries: `schedules run only while the desktop app runs`.

**Revision.** Every snapshot carries `revision` = the backend's `settings_revision` at admission (§3.4.2);
the client re-queries a snapshot whose revision is older than the last `settings_update` it saw for
those sections (§3.7.3).

**Cache hygiene (another writer).** On every values snapshot the service compares `max(updated_at)` of
the settings row, `providers`, `search_providers` and `projects` with the values it saw last (the
backend passes its marks in `ctx.seen`; the job's finish callback stores the new marks in the backend
state before replying), and when one moved without a PubSub message (a desktop app started
after the CLI, R17 — unsupported but possible) invalidates the matching caches: `Cache.delete(:settings)`,
`Providers.broadcast/0`, `Cache.delete(:search_providers)`, `Projects.broadcast/0`. The rows whose
value changed since the last snapshot carry `note: "changed elsewhere"` once. This is the only way the
CLI can notice such a writer; CAS still protects every write.

#### 3.3.4 Values: writes and CAS (`values.patch`, `values.reset`, `profile.apply`)

`values.patch` — `attributes: {"changes": [{"key": k, "value": v, "target": {"project_id"?: uuid,
"conversation_id"?: uuid}}]}` (1..256 changes — enough for every scalar key at once: `length(Registry.scalar_keys())`
is asserted ≤ 256 at compile time), `expected: {"<key>": <wire value> | {"$any": true}}` (every changed
key must have an entry, else `invalid`/`expected is missing for <key>`). `values.reset scope: "all"` and
`import.apply` go through the same function and the same bound.

Per change, in order: registry fetch (unknown → `rejected`/`not a setting: <key>`); scope check (`:cli`
→ `rejected`/`this setting lives in cli.json and is written by the terminal`; `:fact`/`:action` →
`rejected`/`read-only`); target resolution (session keys: `conversation_id` must equal the context
conversation → else `rejected`/`only this session's conversation can be changed here`; project keys:
`project_id` must name an existing project, scratch only when it is the context project →
`not_found`/`That project no longer exists`); `Validate.normalise/2` + `Validate.check/2`; `:svc`
checks (§3.2.4).

Then CAS and write, **all-or-nothing per request**: group the changes by storage target (the settings
row; one conversation; each project; the project file), and run

```elixir
Repo.retry(:settings_values, fn ->
  Repo.transaction(fn ->
    # 1. fresh reads (the Repo.one settings read of §3.3.3, Conversations.get/1, Projects.get/1)
    # 2. for every change: current = WireValue.canonical(read value — the raw stored value when invalid);
    #    unless expected is {"$any": true} or WireValue.equal?(current, expected[key]) → collect {key, current}
    # 3. any conflict or error → Repo.rollback({:conflict | :invalid, details})
    # 4. writes: Settings.update/1 (one call with every settings-row attr; it inserts the row when it is
    #    missing — the only insert, and only on a write), Conversations.update/2 (session.mode: the four
    #    columns of {:conversation_mode}), Projects.update/2 | Projects.trust/1 | untrust (D13:
    #    change(project, trusted_at: nil, approval_mode: "read_only") |> Repo.update)
  end)
end)
# 5. after {:ok, _} — outside the transaction, never inside it (M2):
#    Cache.delete(:settings) when the settings row was written; Projects.broadcast/0 when a project was
#    written (also after trust/untrust); Providers.broadcast/0 when a model pair was written
```

Step 5 exists because the domain writers invalidate the engine caches inside the transaction (before
COMMIT): an engine `get_cached` between that bump and the commit reads the old committed row and caches
it. Invalidating again after the commit makes a lowered approval mode or a shorter timeout reach a
running agent's next operation. A test fills `get_cached` between the write and the commit (the
`:busy_write_seam` or a probe process) and asserts the new value after the command.

A changeset error is mapped back to registry keys by the column → key table (pairs map both columns to
the one key; the four mode columns map to `session.mode`) and returned as `rejected` with the
changeset's message. Results: every change gets a `results[]` row (`accepted`, `unchanged` when value
equals current, `conflict` with `current`, `rejected` with `message`, `skipped` when another change of
the request failed). Overall status is the worst. After a successful `session.model` or
`session.sub_agent_model` write call `SessionConfiguration.clear_override/0` (as `/model` and
`/swarm_model` do). The project file group is delegated to S2 (`ProjectConfig.remove_top_level/3`) with
the file fingerprint in `expected["$file"]`.

A change to `project.approval_mode` or `project.trusted` of the **session's** project reaches the chat
the same way `/approval` does: step 5's `Projects.broadcast/0` → the backend's `projects` subscription →
`schedule_refresh/1` → a new workspace snapshot whose `approval_mode` differs → the reducer's existing
`note_policy_change/2` adds one transcript notice (`Approvals: auto → full access`) and one toast. No
settings code writes policy notices itself.

`values.reset` — `attributes: {"keys": [...]}` or `{"section": "<id>"}` or `{"scope": "all"}`;
converts to a `values.patch` whose values are the reset values: nullable → null, session → null
(`session.mode` → `"build"`), `project.approval_mode` → `"read_only"`, `project.allow` → `[]`, others →
`entry.default`; entries with `resettable: false` (`project.name`, `project.trusted`) and `:cli` entries
are skipped (the client resets cli keys itself). `expected` must list every key reset (for `scope:
"all"` the client sends the base of every resettable key of its snapshot — ≤ 256 entries, inside the
`expected` map bound); a key changed since answers `conflict` and nothing is written.

`profile.apply` — `target: {"conversation_id"}`, `attributes: {"name": profile}`; reads the page's
project file profiles through S2 (`ProjectConfig.profiles/1`), maps `effort`→`effort`,
`swarm_effort`→`swarm_effort`, `model`→`chat_model`, `swarm_model`→`swarm_model`, one
`Conversations.update/2`; unknown → `rejected`/`Unknown profile "<name>" — available: a, b`.

#### 3.3.5 CAS for records and files (all handlers)

| Target | `expected` | Compared against (fresh, inside the write's transaction) | Conflict `current` |
|---|---|---|---|
| record field update | `{"fields": {"<field>": <wire value as read>}}` | the fresh record's same fields (secret fields: `{set, hint}`) | the fresh fields |
| record delete | `{"updated_at": "<iso8601>"}` | the fresh record's `updated_at` | `{"updated_at": …, "summary": …}` |
| secret set/clear | `{"key": {"set": bool, "hint": …}}` | the fresh secret's `{set, hint}` | `{set, hint}` |
| ordered list (search order, hooks) | `{"order": [...]}` / file fingerprint | fresh order | fresh order |
| pricing row | `{"row": <row map or null>}` | the fresh row | the fresh row |
| effort levels | `{"levels": <levels as read or null>}` | fresh levels | fresh levels |
| file | `{"fingerprint": {"sha256": hex, "size": n} \| {"missing": true}}` | fresh sha256 of the file | `{"fingerprint": …}` only — **never the content** (D33); the client re-reads with `settings.query view=file` |
| MCP tool switches | `{"disabled_tools": [...]}` | the fresh `disabled_tools` | the fresh list |

For pure DB writes compare and write inside one `Repo.retry(tag, fn -> Repo.transaction(...) end)`
(calling the domain function — `Providers.update/2`, `Search.upsert/2`, `Settings.update/1` — inside the
transaction is fine: its broadcasts are coalesced by the backend), and after `{:ok, _}` invalidate again
outside the transaction exactly as §3.3.4 step 5 (`Providers.broadcast/0` after a provider write,
`Cache.delete(:search_providers)` after a search write, `Cache.delete(:settings)` after a settings-row
write such as pricing or `lsp_servers`, `Projects.broadcast/0` after a project or config.json write). For writes with process side effects
(`MCP.create/update/delete`, `LSP.stop_project/1`) compare in a transaction and call the domain function
immediately after it in the same job (a documented millisecond window). `Repo.retry/2` always wraps the
whole transaction, never a statement inside one (`DOM/repo.ex` doc).

#### 3.3.6 Overview, facts, usage, projects (S1)

- `overview` view: S1 attention AT4, AT10, AT11, AT16, AT18 + every handler's `attention/1` (each call wrapped:
  an exception skips that handler and logs `settings overview skipped <module>`), sorted error before
  warning, ≤ 64; `glance`: S1 fragments `agents`, `approvals`, `budget` + handlers' `glance/1`
  (`providers`, `search`, `mcp`, `storage`).
- `facts` view: `paths` (`database` — the canonical DB path from `DMN/platform/paths.ex`; `config_dir`
  — `Paths.config_dir/0`; `research_root`; `project_dir` — `<root>/.swarm_code`; `user_agents` —
  `~/.swarm_code/agents`; `user_skills`, `user_commands`, `user_workflows`), each with `~` for home;
  `database_bytes` (db + wal from `File.stat`); `env` (list B of §2.25 as seen by the service process:
  `%{name, set, value | null, secret, feeds}`); `versions` (`service` = `Application.spec(:swarm_code_daemon, :vsn)`,
  `protocol` = the handshake body version, `otp` = `:erlang.system_info(:otp_release)`, `elixir` =
  `System.version/0`); `research_levels` (per level: key, label, steps, fanout, fast, median_ms or
  null); `scheduler: "desktop_only"`.
- `usage` view: `month` (`spend_usd` this calendar month from the same source as
  `FeatureCatalog.usage/1`, `budget_usd` from the row) and `by_model` (last 30 days: model,
  input/output tokens, cost or null when unpriced), ≤ 200 rows.
- `records:projects`: every project incl. the current one, scratch excluded unless current,
  `%{id, name, root, approval_mode, trusted, trusted_at, prefixes, scratch, last_opened_at, current}`,
  sorted by `last_opened_at` desc.
- `open` view (what opening the layer needs, **one job** instead of four, M7): `{"values": <values body
  for every section>, "overview": …, "facts": …, "projects": <records:projects page 1>}`; the encoded
  body is kept under 900 000 bytes (when larger — never with the registry's ≤ 256 scalars — the service
  answers the values alone and the client queries the rest).
- `task` view (B2): `id` = a task_id the session started, or `options.action` + `options.target` for
  the last result per key; answers `{"task_id", "action", "target", "state", "elapsed_ms", "message",
  "result": {"summary": map, "rows": [… ≤ page_size], "next_cursor": string | null, "total": integer}}`
  from the task cache (§3.3.8 rule 7). Row-shaped results (a fetch's models, an import preview's rows, a
  storage plan's items, MCP tool lists, doctor checks, smoke results) are paged 200 at a time; the rest
  is the summary. An evicted or expired entry → `not_found`/`that result is gone; run it again`.

#### 3.3.7 Transfer and doctor (S1)

Export format v1 (UTF-8 JSON, pretty-printed, 0600, atomic: temporary file in the same directory
created exclusively with mode 0600, fsync, rename, the temporary removed on every failure path):

```json
{"format": "swarmcode-settings", "version": 1, "exported_at": "2026-09-25T18:40:00Z",
 "scopes": ["global", "terminal", "project", "providers", "search", "mcp", "pricing", "lsp", "desktop_keys"],
 "global": {"limits.max_concurrent_agents": 6, "...": "every global scalar key except lsp.*, desktop.keys.* and pricing"},
 "terminal": {"panel": "compact", "...": "the cli.json keys the client sent in attributes.terminal"},
 "project": {"root": "~/dev/ailogic", "approval_mode": "auto", "allow": ["mix test"]},
 "providers": [{"name": "DeepSeek", "kind": "openai_compatible", "base_url": "https://api.deepseek.com/v1",
                "models": ["deepseek-v4-pro"], "default_model": "deepseek-v4-pro", "fallbacks": true,
                "effort_levels": null, "model_effort_levels": {}, "api_key": "<secret: set>"}],
 "search_providers": [{"kind": "tavily", "enabled": true, "base_url": null, "position": 0, "api_key": "<secret: set>"}],
 "mcp_servers": [{"name": "github", "transport": "stdio", "command": "github-mcp-server", "args": ["stdio"],
                  "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "<secret: set>", "GITHUB_TOOLSETS": "repos,issues"},
                  "url": null, "headers": {}, "enabled": true, "scope": "global", "disabled_tools": []}],
 "pricing": {"deepseek-v4-pro": {"input": 0.27, "output": 1.1}},
 "lsp": {"erlang": "erlang_ls"}, "desktop_keys": {"side": "meta+shift+s"}}
```

(The example shows `GITHUB_TOOLSETS` in clear because the export ran with *include plain MCP values*
on; with the default off every MCP env/header value is `"<secret: set>"`, and `SecretPattern.secret_kv?/2`
values are `"<secret: set>"` either way.)

`export` (task, 10 s, `kind: :file`): `target: {"path": "~/…json"}`, `attributes: {"scopes": [...],
"terminal": {…}, "mcp_plain_values": false}`; `~` expanded; the parent directory must exist (`the folder
does not exist: <dir>`); an existing file is replaced only with `attributes.overwrite = true` (else `that
file exists; choose another name or allow replacing it`). The task traps exits and removes its
temporary file in an `after` block, so a cancel or timeout (`Task.shutdown(task, 2_000)`, §3.3.8 rule 8)
never leaves one. Result `{path, bytes}`.

`import.preview` (task, 10 s, `kind: :file`): `target: {"path"}`; file ≤ 1 MiB, JSON, `format`/`version`
checked (`not a SwarmCode settings file` / `made by a newer SwarmCode (version N)`); the result is
`preview_id` (= the task_id) plus rows `{id, scope, key_or_record, now, after, status: "change" | "same" |
"invalid" | "secret_skipped", message}` (≤ 2 000 rows, read with `view=task`, 200 per page; secrets
always `secret_skipped` with `paste the key after import`); the summary carries the counts per status.
The preview (including the parsed file) stays in the task cache for 10 minutes.

`import.apply` (task, 60 s, not cancellable, `kind: :file`): `attributes: {"preview_id", "rows": [ids ≤
2 000]}`; applies global scalars in one `values.patch` (≤ 256 changes, §3.3.4) whose `expected` are the
preview's `now` values; records through the handlers (providers
matched by name: create or update non-secret fields; search by kind; MCP by name — `<secret: set>` values
keep an existing value or drop the entry with a note; pricing rows; lsp/desktop keys as scalars); returns
per-row results and `terminal` (the ticked terminal rows) for the client to apply through Preferences.

`doctor` (task, 30 s): checks → `[{id, ok, message}]`: `database` (`SELECT 1` through the Repo),
`config_dir` (exists, writable), `providers` (each: usable by D11's predicate; last test this session),
`mcp` (each enabled server's status), `search` (an engine enabled), `project_file` (parse state of the
session project), `research_root` (exists or creatable). The client adds cli.json and log checks.

#### 3.3.8 Settings tasks (backend-owned, S1 framework)

The PersistedBackend owns tasks (state fields `settings_tasks`, `settings_task_cache`,
`settings_sessions_store`); the pure parts live in `SVC/settings/tasks.ex` and
`SVC/settings/task_cache.ex`, the probe wrapper in `SVC/settings/probe_runner.ex`. Rules:

1. A command handler returns `{:task, spec, result}`; the job hands `spec` to the backend process,
   which starts it and answers the command with `result` plus `task: %{task_id, action}` (task ids are
   random UUIDs). The command's own ledger row completes with that answer (the task outlives it).
2. ≤ 8 tasks running per session; a 9th → `busy`/`Eight settings checks are already running; wait for
   one to finish.` A new task with the same `key` cancels the old one first (state `cancelled`) when the
   old one is cancellable; when it is not → `busy`/`That is still running; wait for it to finish.`
3. **Start.** `kind: :plain | :file` → `Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor,
   fn -> spec.run.(report) end)`; `kind: :probe` → `ProbeRunner.start(spec, report)` (an
   `async_nolink` wrapper that runs `spec.run` in a linked child it can reap, rule 8). `report = fn
   progress -> send(backend, {:settings_task_progress, id, progress}) end`. One `Process.send_after`
   timer for `timeout_ms`: for a **cancellable** task it is the kill deadline (→ state `timeout`, message
   `no answer in N s`); for a **non-cancellable** task it is a reporting deadline — the delta says
   `still running after N s` and the timer re-arms for another `timeout_ms`; nothing is ever killed by
   it. `:DOWN`/`{ref, result}` handling as `start_job/4` does.
4. **Waiting for a topic happens inside the task, subscribed first.** `mcp.reconnect`: the task
   subscribes its own process to the `mcp` topic (the same call the backend uses) **before** calling
   `MCP.reconnect/1`, then `receive {:mcp_status, ^id, status}` until `:ready` (done: `%{status: "ready",
   tools_total, tools_enabled}` read after the message) or `{:error, r}` (failed with the redacted
   reason), within the remaining time. `storage.run` / `storage.vacuum` / `storage.apply_retention`: the
   task subscribes to the `storage` topic **before** `Storage.run/1`, monitors the pid it returns, forwards
   `{:storage_progress, p}` through `report`, and returns on `{:storage_done, r}` (done), `{:storage_failed,
   r}` (failed) or the monitor's `:DOWN` without either (failed: `the cleanup stopped without a
   result`). No message can arrive before the subscription exists, so none is lost; the subscription ends
   with the task process. The backend's own `mcp`/`storage` subscriptions only mark sections (§3.3.9).
5. **Deltas** `settings_task` on start, on progress (the backend keeps the latest progress per task and
   emits at most one delta per 250 ms per task — ≤ 4 per second, §3.12), and at the end (`done`,
   `failed`, `timeout`, `cancelled`). A delta carries `state`, `elapsed_ms` (monotonic), `progress`,
   `message` (≤ 2 048 bytes) and `summary` (`spec.summary.(result)`, ≤ 16 384 bytes encoded, else
   dropped with `summary: null`) — **never the result** (D33). The client reads the result with
   `settings.query view=task` (§3.3.6). In the watch queue (`enqueue_delta/5`) a queued `settings_task`
   delta whose `state` is `running` is **replaced** by a newer one for the same `task_id` (not appended),
   so a long run cannot fill the 128-delta queue; after a watch resync the client re-queries every task
   it knows (§3.7.3).
6. Every `message` and every string in a summary or result is redacted: `LLM.HTTP.redact(text,
   spec.redact ++ stored secrets of the target)` then `LLM.HTTP.redact/1`, then exact-match removal of
   any secret in `spec.redact` shorter than 8 bytes (which `HTTP.redact/2` skips), then cut to 2 048
   bytes.
7. **Result cache** (`TaskCache`, pure):
   a. The last result per `key` (`%{task_id, state, at, summary, result, message}`), ≤ 64 entries and
      ≤ 4 MiB (entry size = encoded JSON bytes; least recently used evicted first). An entry that holds
      secret values (MCP import drafts, which keep the parsed secrets until apply) has a 10-minute TTL
      enforced by `Process.send_after(backend, {:settings_task_purge, key, ref}, 600_000)` armed at
      insert, ignored when the ref no longer matches (replaced or evicted), and every purge timer is
      cancelled in `terminate/2`. `Inspect` of the cache shows keys and sizes only.
   b. The **sessions store** — the last `storage.measure`'s sessions list — lives outside the LRU: ≤
      20 000 rows of `{id, bytes, updated_at, title ≤ 120 chars, project ≤ 120 chars, messages, runs,
      running, open, pinned, deletable, reason}` and ≤ 6 MiB; a larger measure keeps the largest rows by
      bytes and says `showing the 20 000 largest sessions`. `records:storage_sessions` and `storage.plan`
      read it through their `cache_reads/1` declaration.
   Handlers see cache entries only through `ctx.task_results` (§3.3.2).
8. **Stopping** (`task.cancel`, the kill deadline, a replacing task): `kind: :plain` →
   `Task.shutdown(task, :brutal_kill)`; `kind: :file` → `Task.shutdown(task, 2_000)` (the task traps
   exits and removes its temporary files in `after`); `kind: :probe` → `ProbeRunner.stop/1`: read
   `Port.info(port, :os_pid)` of every port in `Process.info(child, :links)`, kill the child, then
   `SwarmCode.Domain.OSProcess.kill_tree/1` for each os pid (an MCP stdio probe — `npx → node …` — leaves
   no process). State `cancelled`. A non-cancellable task → `rejected`/`this cannot be stopped once it
   started`.
9. Backend `terminate/2` stops every task with its kind's stop (non-cancellable ones are interrupted
   there — the client asks before quitting, §4.8) and cancels every purge timer. Tasks survive a
   conversation switch (settings are not conversation-scoped).
10. Headless (`swarmcode config`, §3.10.3) runs `spec.run` in a `Task.Supervisor.async_nolink` child
    with the spec's timeout and the same stop rules, keeping results in a map local to the command.

| Action | timeout | cancellable | kind | Notes |
|---|---|---|---|---|
| `provider.test` | 15 s | yes | plain | lists models, writes nothing; optional `secrets: [api_key]` tests an unsaved key |
| `provider.set_key` with `test_first` | 15 s | yes (cancel = keep the old key) | plain | tests with the new key, writes it only on success (§3.5.1) |
| `provider.fetch_models` | 30 s | yes | plain | lists models, writes nothing, the difference is the result (rows paged) |
| `provider.fetch_all` | 120 s (30 s per provider, ≤ 4 at once) | yes | plain | per-provider progress |
| `search.test` | 20 s | yes | plain | `Search.test/2` (15 s inside) |
| `search.set_key` with `test_first` | 20 s | yes | plain | as `provider.set_key` |
| `mcp.test` | 65 s | yes | probe | `MCP.Client.probe/1` |
| `mcp.reconnect` | 35 s | yes (stops waiting; the client keeps its own lifecycle) | plain | rule 4 |
| `mcp.import.read` | 10 s | yes | plain | drafts with masked secrets (secret values stay in the cache, TTL 10 min) |
| `lsp.check` | 5 s | yes | plain | |
| `storage.measure` | 120 s | yes | plain | overview + previews; fills the sessions store |
| `storage.plan` | 60 s | yes | plain | key `{storage.plan, :wizard}` |
| `storage.run` | 30 min (reporting) | no | plain | rule 4 |
| `storage.vacuum` | 30 min (reporting) | no | plain | synchronous `Storage.vacuum/0` inside the `:storage_cleanup` registration (§3.5.5) |
| `storage.apply_retention` | 10 min (reporting) | no | plain | §3.5.5 |
| `workflow.smoke` | 30 s | yes | plain | |
| `export` / `import.preview` | 10 s | yes | file | |
| `import.apply` | 60 s (reporting) | no | file | |
| `doctor` | 30 s | yes | plain | |

#### 3.3.9 Live updates and refresh (S1)

The backend subscribes (in `init/1`, beside its existing subscriptions) to `Settings.subscribe/0`
(`"settings"`), `Providers.subscribe/0`, `Search.subscribe/0`, `Projects.subscribe/0`,
`Storage.subscribe/0` (`"mcp"` is already subscribed). On a message of those topics — and on
`{:conversation_updated, _}` for the session conversation — it:

1. adds the touched sections to a pending set: `{:settings_updated, _}` → models_effort, deep_research,
   search_web, agents_limits, language_servers, storage, budget, desktop, pricing, approvals (efforts'
   choices); `providers` → providers, models_effort, pricing, deep_research; `search_providers` →
   search_web; `projects` → approvals, project_file, overview; `mcp` → mcp, overview; `storage` →
   storage **only for `{:storage_done, _}` and `{:storage_failed, _}`** (progress belongs to the task,
   §3.3.8 rule 4); conversation → models_effort **only when a registry-backed conversation column
   changed** (the backend keeps the last projected session values and compares; `mark_seen`, queue and
   title-only changes do not mark it — title marks models_effort because `session.title` is a row);
2. arms a 100 ms coalescing timer (§3.12); when it fires, bumps `settings_revision` and emits one
   `settings_update` delta `{revision, sections, origin}` on the global scope, where `origin =
   "settings"` when a settings command of this session completed within the window, else `"elsewhere"`;
3. calls `schedule_refresh/1` for `settings`, `providers`, `search_providers` and `projects` messages so
   the workspace metadata (model list, context window, effort, approval mode) is re-projected (R3; this
   is also how a settings change of the session project's approval mode produces the transcript's
   policy notice, §3.3.4).

The `{:settings_updated, %Setting{}}` struct (which contains `tavily_api_key`) is never forwarded, stored
or inspected (R19): the handler matches `{:settings_updated, _}` and keeps nothing of it.

**Limitation (documented, R17).** A desktop app started after the CLI writes the same database from
another VM, with no PubSub reaching this one: no delta arrives and the engine caches can stay stale
until the next values snapshot's `max(updated_at)` check (§3.3.3) or a CAS conflict reveals the change.
The CLI never runs beside the desktop by design (the foundation gate refuses to start while it runs).

#### 3.3.10 Backend integration details (S1)

- **Settings jobs have their own pool.** `settings.query` and `settings.command` run as backend jobs
  in a settings pool of **4** beside the existing job cap of 8 (chat, feature and file-index jobs keep
  theirs); a 5th settings job → a query answers `wire_error(:capacity_exceeded)`, a command answers the
  settings_result `busy`/`Settings is busy; try again in a moment.` (checked **before**
  `CommandLedger.admit`, so no ledger row is created for a refused command).
- **Query jobs** are keyed `{:settings_query, view, kind, id, project_id, options["slot"]}` and are
  replaceable only by a request with the same key — so the Memory & instructions page's three `file` loads, two record
  pages and two projects' records run side by side; the client sends `options.slot` (e.g. `"search"`)
  only where a newer request should replace an older one. The client ignores the `:stale_revision`
  failure of a request it has already superseded. `:settings_query` is added to
  `Connection.fail_request/3`'s read list, so a deadline answers a typed read error, never an outcome.
- **Command jobs** (the first commands that run as jobs): `admit_request/5` may return `{:job, job}`
  for `:settings_command`; command jobs are **never replaceable** (`replace: false`); the durable ledger
  `admit` happens after the pool check and before the job starts. Every settle path of a command job
  completes the ledger and answers the client with a `settings_result`: success → the result; `:DOWN`,
  the job timer, `cancel_jobs` in `terminate/2` → `CommandLedger.complete/3` with `%{status:
  "unavailable", message: "Couldn't tell whether that was saved; reloading."}`, `remember_response`, and
  that settings_result as the reply (never a bare `wire_error`, so the ledger row never stays
  `processing`). The command-job timer is `timeout_ms − 1 000` ms so the job settles before the
  Connection's own timer.
- **Ledger guard (D33, B1).** Before `CommandLedger.complete/3`, a settings_result whose encoded size is
  over 122 880 bytes (120 KiB) is replaced by the same `status` with `results: []`, `record: null` and
  `message: "The answer was too large to keep; reloading."` (`command_ledger.ex` is not edited; a test
  asserts the guard stays below its 131 072-byte raise). A test commits a conflict on a 200 KB file and
  asserts the backend survives and the ledger replays the reply.
- **Secrets and the ledger:** a `settings.command` whose `secrets` list is non-empty is **not durable**
  (never written to `cli_command_ledger`) and is **not** kept in the in-memory replay cache; its
  fingerprint (used for request-id conflict detection only) is computed with every secret value replaced
  by `"[secret]"`. No response ever contains a secret.
- **Crash reports never hold a secret (M15).** `format_status/1` of `Connection`, `PersistedBackend`,
  `DataSource.Daemon` (S1) and `SessionRuntime` and the terminal port owner (U1) replace the `:message`
  and `:log` entries with `:redacted` as well as the state they already redact. `Connection` stores per
  request `%{message: <the message with "secrets" deleted from its body>, operation, task, timer,
  deadline}` and `fail_request/3` uses the stored `operation` (it no longer re-decodes the body), so the
  secret bytes live only in the one request task. `ServiceRequest`, the client `Request` and
  `Settings.Command` get custom `Inspect` implementations that print `secrets: [<N redacted>]`.
- **Open conversations are protected from cleanups (M3).** `PersistedBackend.init/1` and
  `switch_conversation/2` call `SwarmCode.Domain.UIState.opened(conversation_id)` (a public domain
  function; the entry is keyed by the backend pid and removed when it exits), so `Storage.plan/2` and
  retention keep back the conversation the TUI shows (`open in this terminal`).
- The request scope is global (`id` nil); the backend builds `Context` from its session (project,
  conversation, override), the §2.25 list-B names of `System.get_env/0`, the declared cache entries
  (§3.3.2), its `seen` marks and `settings_revision`.
- **Dispatch without a usable provider (D11, M9):** `dispatch_send` resolves the conversation's
  effective chat provider (`Providers.effective_model(conv, :chat)` after the `--model` overlay); when
  that fails **or** the provider is not `SessionConfiguration.usable?/1`, the send is refused with
  `reason: {:provider_required, "No model provider can answer: <name> has no key. Add one in /settings
  providers."}` (`<name>` omitted when there is none) instead of starting a run. The client shows the
  §3.10.1 words and keeps the draft.
- `LiveBackend`: `settings.query` answers `settings_snapshot` with `available: false`, `message: "Saved
  settings are available in a saved session (swarmcode). This session runs from SWARM_* variables."`;
  `settings.command` answers `settings_result` with `status: "unavailable"` and the same message.
- R1: `SVC/feature_request.ex` error bodies use exactly the canonical `AdmissionError` messages for
  their codes (read them from `UI/data_source/admission_error.ex`'s table; add a daemon-side copy in
  `feature_request.ex` and a test that both tables agree by value).

### 3.4 The wire (S1)

#### 3.4.1 Operations and capability

| op (wire) | atom | capability | read/command | params (exact key set) |
|---|---|---|---|---|
| `settings.query` | `:settings_query` | `settings` | read (job) | `view`, `sections`, `keys`, `kind`, `id`, `project_id`, `cursor`, `page_size`, `byte_limit`, `options` |
| `settings.command` | `:settings_command` | `settings` | command (job; durable unless `secrets` non-empty) | `action`, `target`, `attributes`, `expected`, `secrets`, `dry_run` |

- New capability wire name `settings` ↔ `:settings` (17 of 20). Add it to
  `CORE/protocol/service_handshake.ex` `@capabilities` and `HelloOk.capability`, to the daemon default
  grant (`DMN/service.ex`), to `Connection.capability?/2` (both ops → `:settings`), and to the client's
  `request_capability/1` (`UI/data_source/daemon.ex`). A client never sends a settings request without
  the granted capability.
- Scope: global only (`id` nil); anything else fails `valid_params?/3`.
- `timeout_ms`: 1..600 000 as for every op; the client uses 15 000 for queries and commands.
- **One bounds function for both sides (B3c).** The bounds below live in
  `SwarmCode.Settings.WireBounds.valid?(op, params) :: :ok | {:error, param :: String.t()}` (core, S1).
  `ServiceRequest.valid_params?/3` calls it (a violation fails decoding, and `Connection` closes the
  socket, as for every op today), and the client's `Request.validate/1` calls the same function before
  anything is sent, so an oversize edit is refused locally with `That is too long to save here (<param>)`
  on the row and never reaches the wire.

Param bounds (never truncating):

| Param | Rule |
|---|---|
| `view` | one of `values`, `overview`, `facts`, `usage`, `open`, `task`, `records`, `record`, `file` |
| `sections` | null or list ≤ 32 of section ids (strings in `Sections`) |
| `keys` | null or list ≤ 400 of strings 1..64 bytes |
| `kind` | null or a record kind name ≤ 64 bytes (from `RecordKind`) |
| `id` | null or string 1..512 bytes, no control characters |
| `project_id`, `cursor` | null or uuid / null or string ≤ 256 bytes |
| `page_size` | 1..200 |
| `byte_limit` | 4 096..1 048 576 |
| `options` | map ≤ 32 entries, depth ≤ 3, strings ≤ 1 024 bytes (`slot` ≤ 32 bytes, §3.3.10) |
| `action` | one of the closed list in §3.4.3 |
| `target` | null or map ≤ 16 entries, depth ≤ 3, strings ≤ 1 024 bytes |
| `attributes` | map; depth ≤ 8; maps ≤ 256 entries with keys 1..256 bytes; lists ≤ 2 048 items; strings ≤ 262 144 bytes; the encoded params ≤ 900 000 bytes |
| `expected` | null or map with the same bounds as `attributes` |
| `secrets` | list ≤ 16 of `{"slot": 1..128 bytes, "value": 1..8 192 bytes, no NUL}` |
| `dry_run` | boolean (validate and CAS-check, write nothing, answer `accepted`/`conflict`/`rejected`) |

#### 3.4.2 Responses

Every settings answer is an ordinary `result` frame, `{"op": "result", "response_kind": <kind>, "value":
<value>}` with the request's `request_id` (the existing codec shape, `codec.ex` `response_body/2`), with
two new response kinds: `settings_snapshot` (to `settings.query`) and `settings_result` (to
`settings.command`).

`settings_snapshot` value:

```json
{"request_id": "…", "view": "values", "revision": 42, "available": true, "message": null,
 "body": { … view body … }}
```

| view | body |
|---|---|
| `values` | `{"values": [SettingValue …≤ 400], "project_id": uuid \| null, "conversation_id": uuid \| null}` (SettingValue §3.3.3) |
| `overview` | `{"attention": [{"id", "severity", "section", "target": {"key"} \| {"kind", "id"}, "title", "reason"} …≤ 64], "glance": {"providers", "search", "mcp", "agents", "approvals", "storage", "budget"}}` (each glance value a map of numbers/strings ≤ 16 entries) |
| `facts` | §3.3.6 |
| `usage` | `{"month": {"spend_usd", "budget_usd"}, "by_model": [usage_row …≤ 200]}` |
| `open` | `{"values": <values body>, "overview": <overview body>, "facts": <facts body>, "projects": <records body>}` (§3.3.6) |
| `task` | `{"task_id", "action", "target", "state", "elapsed_ms", "message", "result": {"summary", "rows": [… ≤ page_size], "next_cursor", "total"}}` (§3.3.6) |
| `records` | `{"kind", "items": [record …≤ page_size], "next_cursor": string \| null, "total": integer \| null}` |
| `record` | `{"kind", "id", "fields": {…}}` |
| `file` | `{"file": {file record + "content": string \| null}}` |

`settings_result` value:

```json
{"request_id": "…", "status": "accepted",
 "results": [{"target": "limits.max_concurrent_agents", "status": "accepted", "value": 6, "current": null, "message": null}],
 "record": null, "task": null, "message": null, "confirm": null,
 "field_errors": [], "revision": 43}
```

`status` ∈ `accepted`, `unchanged`, `conflict`, `rejected`, `needs_confirmation`, `not_found`, `busy`,
`unavailable`, `unsupported`. `record` = the fresh record (kind-typed, secrets as `{set, hint}`) after a
record write. `field_errors` = `[{"target": "name" | "rows[3]" | "env.GITHUB_TOKEN", "message"}]` ≤ 64.
`results` ≤ 256 rows for `values.patch`/`values.reset`/`import.apply`, ≤ 64 otherwise; `message` = one
sentence ≤ 2 048 bytes for the status row (never a secret); `confirm` = `{kind, items ≤ 32}` only with
`needs_confirmation`. **No settings_result carries file content or a task result** (D33); the encoded
value stays under the 120 KiB ledger guard (§3.3.10).

**Other replies to a settings request, and what the client does with them (B3b):**

| Reply | When | Client |
|---|---|---|
| `result` with `response_kind: "outcome"` to a `settings.command` | ledger replay/conflict, `not_allowed`, `request_conflict`, an unresolved ledger row, a Connection deadline (`outcome_unknown`) | the codec maps it to `DTO.SettingsResult{status: :unavailable, message: "Couldn't tell whether that was saved; reloading.", corrective_action: :refresh}` (status `rejected` when the outcome's status is `rejected`) — the connection stays open; the layer re-queries what it shows |
| `error` frame (`wire_error`) | capability, capacity, deadline of a query, `source_unavailable` | `{:settings_failed, request_id, words}` from the canonical `AdmissionError` words |
| a `result` of any other kind | never (a daemon bug) | `invalid()` as today (the connection closes) — the only close path left |

A test drives each row: an `outcome` reply to a settings command, a deadline on a settings query and a
deadline on a settings command, and asserts the connection stays open.

#### 3.4.3 The closed action list

`values.patch` `values.reset` `profile.apply` `task.cancel` `export` `import.preview` `import.apply`
`doctor` · `provider.create` `provider.update` `provider.set_key` `provider.clear_key` `provider.delete`
`provider.test` `provider.fetch_models` `provider.apply_models` `provider.fetch_all`
`provider.forget_caps` · `efforts.save` `efforts.remove_override` · `pricing.put_row`
`pricing.delete_row` · `search.update` `search.set_key` `search.clear_key` `search.move` `search.test` ·
`mcp.create` `mcp.update` `mcp.set_secret` `mcp.toggle` `mcp.set_tools` `mcp.reconnect` `mcp.test`
`mcp.delete` `mcp.import.read` `mcp.import.apply` · `storage.measure` `storage.plan` `storage.run`
`storage.vacuum` `storage.apply_retention` · `lsp.check` `lsp.stop` `lsp.remove_key` · `file.save`
`file.create` `file.delete` `file.clear` `workflow.smoke` · `project_config.put_hook`
`project_config.delete_hook` `project_config.move_hook` `project_config.put_profile`
`project_config.delete_profile` `project_config.remove_key` `project_config.remove_entry`. (60 actions.)

#### 3.4.4 Deltas (global scope, via the shell watch)

| kind | body | notes |
|---|---|---|
| `settings_update` | `{"revision", "sections": [ids …≤ 22], "origin": "settings" \| "elsewhere"}` | never values |
| `settings_task` | `{"task_id", "action", "target": map \| null, "state": "running" \| "done" \| "failed" \| "timeout" \| "cancelled", "elapsed_ms", "progress": null \| {"done", "total", "bytes", "step"}, "summary": null \| map (≤ 16 384 bytes encoded), "message": null \| string ≤ 2 048}` | never the result (D33); the result is `settings.query view=task`; running deltas of one task replace each other in the watch queue (§3.3.8 rule 5) |

Add both to `UI/data_source/delta.ex`'s kinds and to the codec's global-scope allowance (like `toast`).
Both stay far below the watch's 128 KiB per-delta bound.

#### 3.4.5 File references

`ref` strings name a file without a path; the service resolves and confines the path (never accepts a
path from the client): `<file_kind>:<scope>:<project_id or ->:<name>` ≤ 512 bytes, e.g.
`memory_project:project:0f3c…:MEMORY`, `memory_global:global:-:MEMORY`,
`instructions:project:0f3c…:AGENTS` (the service resolves which candidate file wins, §2.12),
`command:global:-:review`, `agent:user:-:scout`, `agent:bundled:-:reviewer` (read-only),
`skill:project:0f3c…:html-report` (the file is `<dir>/SKILL.md`), `workflow:user:-:nightly`,
`project_config:project:0f3c…:config`. `name` must pass the kind's name rule (§2.23); any other form is
`not_found`.

#### 3.4.6 Client DTOs (closed, S1)

`DTO.SettingsSnapshot{view, revision, available, message, body}` with body decoded per view into:
`[DTO.SettingValue]` (values), `DTO.SettingsOverview`, `DTO.SettingsFacts` (bounded generic map),
`DTO.SettingsUsage`, `DTO.SettingsOpen{values, overview, facts, projects}`, `DTO.SettingsTaskView{task_id,
action, target, state, elapsed_ms, message, summary, rows, next_cursor, total}`,
`DTO.SettingsRecordPage{kind, items: [DTO.SettingsRecord], next_cursor, total}`,
`DTO.SettingsRecord{kind, id, fields}`, `DTO.SettingsFile`. `DTO.SettingsResult` (also built from an
`outcome` reply, §3.4.2), `DTO.SettingsUpdate`, `DTO.SettingsTask`.

Decoding rules (the client's last line of defence for D6):

1. A `SettingValue.key` must be a registry scalar key (an unknown key — from a newer daemon — is
   dropped from the snapshot and logged by key only). A value or layer value that fails
   `WireValue.type_ok?/2` makes **that SettingValue** `state: "invalid"` with `value: nil` (D34); the
   snapshot is kept. A `state: "invalid"` value from the service is decoded as is (its `raw` is a
   bounded string shown through `SafeText`).
2. A record's `fields` keys must be fields of its `RecordKind`; a field declared `secret` must decode
   as exactly `{"set": boolean, "hint": null | <string of 4 printable characters>}` — any other value
   (a string, a longer hint, extra keys) rejects the whole snapshot/result and the client logs
   `settings response rejected: secret field shape (<kind>.<field>)` (no value). This is the only
   rule that rejects a whole response for a value.
3. MCP env/header entries: when `secret` is true, `value` must be null; when `secret` is false, the
   client re-checks `SecretPattern.secret_kv?/2` and rejects the response when it matches (the service
   masks with the same function, so this only fires on a daemon bug).
4. Bounds: values ≤ 400; record pages and task rows ≤ 200 per page; a record field list ≤ its
   `RecordKind` field `max` (`provider.models` ≤ 2 000, `mcp_server.tools` ≤ 512, others ≤ 200);
   strings ≤ 65 536 except file `content` ≤ 262 144.
5. A rejected response becomes the typed delivery `{:settings_failed, request_id, "Couldn't read settings right now."}`
   (EffectRunner), never a connection close.

Also in this pass (S1): `DTO.WorkspaceMetadata.models` accepts up to 400 items (R5).

### 3.5 Integration operations (S2)

Every handler: fresh reads, CAS per §3.3.5, field errors keyed by record field names, redacted
messages, no secret in any result, no DB write on read (D24), atomic file writes (D26). Timeouts and
cancellability per §3.3.8.

#### 3.5.1 Providers, models, efforts (`Settings.Providers`, `Settings.Models`, `Settings.Efforts`)

| action / view | target | attributes | expected | secrets | behaviour | result |
|---|---|---|---|---|---|---|
| `records:providers` | — | — | — | — | `Providers.list/0` → summaries (§2.23) with `api_key: {set, hint}`, `usable`, `models_count`, `last_test`/`last_fetch` from `ctx.task_results` | page |
| `record:provider` | — | — | — | — | + `models`, `effort_levels`, `model_effort_levels`, `builtin_levels` (`Efforts.defaults(kind, nil)`), `presets` (`Efforts.presets/0` whose kinds include the provider's), `used_by` (settings pairs pointing at it → registry keys; conversations count with any of chat/swarm/judge/implementer provider ids = id; scheduled tasks count with `provider_id` = id), `caps` (`ProviderCaps` effort/prefix-cache/fallbacks rejections) | record |
| `provider.create` | — | `name`, `kind`, `base_url`, `models`, `default_model`, `fallbacks`, `effort_levels` (the preset's levels or null, validated with `Efforts.validate/1`) | — | optional `api_key` | `Providers.create/1` with the key merged; `Providers.broadcast/0` after the commit | record |
| `provider.update` | `{id}` | any subset of the create fields | `{"fields"}` | — | CAS → `Providers.update/2` (also forgets caps) | record |
| `provider.set_key` | `{id}` | `{"test_first": bool}` (the client sends `true` when the stored key is set, `false` for a first key and for `s save it anyway`) | `{"key"}` | `api_key` required | `Secrets.check_paste/1` (trimmed; `paste only the key: it had N lines` / `a key has no spaces inside` / `that is too short to be a key`). `test_first: false` → CAS + update `api_key` → record, and the client starts `provider.test`. `test_first: true` → a task (15 s): `LLM.list_models(%{provider \| api_key: new})`; success → CAS on `expected.key` + update inside one transaction → done `{saved: true, count, ms}`; refusal/timeout → failed with `The new key was refused (<HTTP status or words>).` and the stored key untouched | record / task |
| `provider.test` | `{id}` or `{"draft": true}` | draft: `{kind, base_url}` | — | optional `api_key` (an unsaved key: drafts, or a check before a save) | task: `SwarmCode.Domain.LLM.list_models(provider)` with the secret merged in memory; writes nothing | `{count, ms}` |
| `provider.clear_key` | `{id}` | — | `{"key"}` | — | `api_key: ""` | record |
| `provider.delete` | `{id}` | `{"replacements": {"<models.* or research.*_model key>": model wire value}}` | `{"updated_at"}` | — | CAS on `updated_at`; the replacements are written in the same transaction with one `Settings.update/1` of the pair columns named by the registry's storage descriptors (not through S1's `Values`, so S2 builds alone; `$any` for those pairs since they are being replaced); then `Providers.delete/1`; `Cache.delete(:settings)` + `Providers.broadcast/0` after the commit | `record: null`, `message: "<name> deleted"`, results per replacement |
| `provider.fetch_models` | `{id}` | — | — | — | task: list models; difference against `provider.models`. Summary `{listed, kept, truncated, added, removed, unchanged, ms}`; rows (paged via `view=task`) `{model, change: "new" \| "gone" \| "same", conversations}` sorted, the listed models capped at 2 000 (`truncated: true` and `listed` = the real count when longer) and `removed_in_use` as the `conversations` count of each gone model | task result |
| `provider.apply_models` | `{id}` | `{"fetch_task_id", "mode": "replace" \| "add"}` (the list never travels back, D25) | `{"fields": {"models"}}` | — | reads the fetched list from `ctx.task_results` (declared, §3.3.2; gone → `not_found`/`fetch again first`); add = current ++ new ones (order kept, stopping at 2 000 with `N not added: 2 000 models at most`); replace = exactly the fetched list, **refused when the fetch was truncated** (`rejected`/`the list was longer than 2 000; add new ones instead`, D39); `Providers.update/2` | record |
| `provider.fetch_all` | — | — | — | — | task: every provider, ≤ 4 at once, 30 s each; progress `{done, total}` | `{providers: [{id, name, state, count, added, removed, message}]}` |
| `provider.forget_caps` | `{id}` | — | — | — | `ProviderCaps.forget/1` | record |
| `records:model_options` | — | `options.provider_id` optional | — | — | every provider × model (`provider.models`, plus each `default_model` not in the list), price from `settings.pricing`, `context_window` from the pricing row, `in_last_fetch` from the fetch cache; sorted provider name, model; paged 200 | page |
| `records:effort_presets` | — | `options.kind` | — | — | `Efforts.presets/0` filtered | page |
| `efforts.save` | `{id, "model": null \| string}` | `{"rows": [{key, label, hint, body: object, drop: [string]}] ≤ 32}` | `{"levels"}` | — | encode each body to JSON text, `Efforts.from_rows/1`; `{:error, errors}` → `field_errors` `rows[i]` with the exact messages; provider scope: `effort_levels` (empty → nil); model scope: put the list in `model_effort_levels` | record |
| `efforts.remove_override` | `{id, "model"}` | — | `{"levels"}` | — | delete the model's entry | record |

Errors of `provider.test`/`fetch_models`: the domain's error string (`HTTP.status_message/3` words,
already redacted with the key) redacted again (§3.3.8 rule 6); a timeout → `no answer in 15 s` /
`… 30 s`.

#### 3.5.2 Pricing (`Settings.Pricing`)

| action / view | target | attributes | expected | behaviour |
|---|---|---|---|---|
| `records:pricing_rows` | — | — | — | rows sorted by model with `derived_cache_read`, `derived_cache_write` (`Pricing.cache_read_rate/3`, `cache_write_rate/2` semantics) |
| `records:unpriced_models` | — | — | — | models named by any `models.*`/`research.*_model` default or by conversations updated in the last 30 days (chat/swarm/judge/implementer model columns), without a pricing row; `conversations_30d` counts |
| `pricing.put_row` | — | `{model, input, output, cache_read, cache_write, context_window, "rename_from": null \| old model}` | `{"row": old \| null}` (+ `{"rename_row": …}` when renaming) | fresh map; CAS on the row(s); desktop row validation with the exact texts (D§5); `Settings.update(%{pricing: map})` |
| `pricing.delete_row` | `{model}` | — | `{"row"}` | remove the key |

#### 3.5.3 Search (`Settings.Search`)

| action / view | target | attributes | expected | secrets | behaviour |
|---|---|---|---|---|---|
| `records:search_providers` | — | — | — | — | `Search.list/0` + in-memory placeholders for missing kinds (`enabled: false`, `position` = canonical index), sorted `{position, canonical index}`; never `Search.all/0` |
| `search.update` | `{kind}` | subset of `{enabled, base_url}` | `{"fields"}` | — | CAS on the fresh row (or the synthesized placeholder); `Search.upsert(kind, attrs)` (the key untouched) |
| `search.set_key` | `{kind}` | `{"test_first": bool}` | `{"key"}` | `api_key` | checks as `provider.set_key`; `test_first: true` → a task (20 s) running `Search.test(kind, %{api_key: v})` first and writing only on success (else `The new key was refused (<words>).`, old key kept); then `Search.upsert(kind, %{api_key: v})` in the CAS transaction |
| `search.clear_key` | `{kind}` | — | `{"key"}` | — | `api_key: ""`; a key-needing enabled kind is also turned off (`enabled: false`) and the result message says so |
| `search.move` | `{kind}` | `{"dir": -1 \| 1}` | `{"order": [kinds]}` | — | CAS on the order; `Search.move/2` |
| `search.test` | `{kind}` | optional `{base_url}` | — | optional `api_key` (tests an unsaved key) | task: `Search.test(kind, overrides)`; engines `{count, ms}`, readers `{read: "example.com", ms}` |

#### 3.5.4 MCP (`Settings.MCP`, `Settings.MCPImport`)

Env/header wire form: `[{"name", "secret", "value" (null when secret), "hint"}]`; secret by
`SecretPattern.secret_kv?/2` (§3.2.5). S2's tests assert, on a sample table of 40 names/values, that
every entry `MCP.Server.secrets/1` masks is also masked (superset) and that `GH_PAT`, `OPENAI_KEY`,
`STRIPE_KEY=sk_live_…`, `DB_PASSWD`, `DATABASE_URL=postgres://u:pw@h/db`, `xoxb-…`, `AKIA…` are masked;
the daemon's log redaction keeps using the desktop's own rule (`desktop_secret_kv?/2`). Command attributes use `[{"name", "value"}]` for a new/changed non-secret value,
`[{"name", "keep": true}]` to keep a stored value, and a secret slot `env:<NAME>` / `header:<Name>` in
`secrets` for a new secret value; a name missing from the list is deleted.

| action / view | target | attributes | expected | secrets | behaviour |
|---|---|---|---|---|---|
| `records:mcp_servers` | — | `options.project_id` | — | — | global servers + those of the page project; status `MCP.status/1` (`:ready`→ready, `:connecting`, `{:error, r}`→error + message, `:stopped`), tools counts from `MCP.tools_of/1` |
| `record:mcp_server` | — | — | — | — | + command, args, env, url, headers (masked), `tools` (`MCP.tools_of/1`: raw name, published name, description ≤ 512, enabled, read_only), `output` (`MCP.recent_output/1`), `slug` |
| `mcp.create` | — | name, transport, command, args, env, url, headers, enabled, project_id | — | `env:*`, `header:*` | build maps; `MCP.create/1` (starts the client when enabled) |
| `mcp.update` | `{id}` | subset (env/headers = full desired lists) | `{"fields"}` | `env:*`, `header:*` | CAS; merge (`keep` from the fresh row); `MCP.update/2` (restarts). `project_id` changes only when present in `attributes` (fixes R7) |
| `mcp.set_secret` | `{id, "map": "env" \| "headers", "name"}` | — | `{"key"}` (that entry's `{set, hint}`) | one | put the entry; `MCP.update/2` |
| `mcp.toggle` | `{id}` | `{"enabled": bool}` | `{"fields": {"enabled"}}` | — | `MCP.update(server, %{enabled: b})` |
| `mcp.set_tools` | `{id}` | `{"tools": {"<raw name>": bool}}` ≤ 512 | `{"disabled_tools": [...]}` | — | in one CAS transaction compute the final `disabled_tools` list and write it once (`Server.changeset(server, %{disabled_tools: list}) \|> Repo.update`); after the commit call `MCP.set_tool_enabled/3` once for one changed tool (idempotent) so the tool table is republished — never one call per tool inside the transaction (it has its own `Repo.retry`) |
| `mcp.reconnect` | `{id}` | — | — | — | a disabled server → `rejected`/`turn it on first`; else task: subscribe, then `MCP.reconnect/1`, then wait for the status (§3.3.8 rule 4); result `{status, tools_total, tools_enabled}` |
| `mcp.test` | `{id}` or `{"draft": true}` | draft attributes (as create) | — | `env:*`, `header:*` | task (`kind: :probe`): changeset valid (else field errors, no task) → `apply_changes`, temporary id → `MCP.Client.probe/1`; `{tools: [names ≤ 64], count}`; cancel reaps the server's process tree (§3.3.8 rule 8) |
| `mcp.delete` | `{id}` | — | `{"updated_at"}` | — | `MCP.delete/1` |
| `mcp.import.read` | — | `{"path": null \| string}` | — | — | task: read `<page project root>/.mcp.json` or the expanded path (confined to the user's home, ≤ 1 MiB, JSON `{"mcpServers": {name: {command, args, env, url, headers, type}}}`); drafts `{name, transport (http when `url` or `type` http/streamable-http; `sse` → `unsupported: true` with `SSE servers are not supported; use the server's streamable http URL`), command, args, env (masked), url, headers (masked), conflict: existing name?, variables: [{map, name, ref: "GITHUB_TOKEN", in_shell: bool}]}` — a value matching `^\$\{[A-Za-z_][A-Za-z0-9_]*\}$` or `^\$[A-Za-z_][A-Za-z0-9_]*$` is a variable reference (§2.7), `in_shell` = `System.get_env(ref) != nil` (the value itself never leaves the daemon); the parsed values (incl. secrets) stay in the task cache under `import_id` (= the task_id) for 10 min |
| `mcp.import.apply` | — | `{"import_id", "names": [...], "project_id": null \| uuid, "rename": {"<name>": "<new name>"}, "values": {"<name>": {"env.<NAME>" \| "header.<Name>": "shell" \| "paste" \| "literal"}}}` | — | `import:<name>:env:<NAME>` / `import:<name>:header:<Name>` for pasted values | per ticked draft: resolve each variable by its choice (`shell` → `System.get_env/1` now — not set → that server `rejected`/`GITHUB_TOKEN is not set in this shell`; `paste` → the slot; `literal` → the text as written), refuse `unsupported` drafts, then `MCP.create/1`; per-name results |

#### 3.5.5 Storage (`Settings.Storage`)

| action / view | behaviour |
|---|---|
| `storage.measure` | task: `Storage.overview/0`, `Storage.sessions(sort: :bytes)` (into the sessions store, §3.3.8 rule 7b), `Storage.presets/0` + `Storage.previews/1`; result summary = overview + presets with previews |
| `records:storage_sessions` | pages the sessions store; `options.sort` ∈ `bytes`, `date`, `title` (`String` compare), `options.filter` substring on title/project (case-insensitive); no store → `not_found`/`measure first` |
| `storage.plan` | task: `attributes.selection` (§2.18 wizard keys: `older_than_days`, `session_ids` ≤ 2 048, `include_pinned`, `empty_sessions`, `prune_days`, `checkpoint_days`, `journal_days`, `research_days`, `vacuum`) → `Storage.plan(selection, store_sessions)`; the plan is cached under `plan_id` (= the task_id); result summary `{plan_id, items: [{label, count, bytes}], skipped: [{reason, count}], total_count, total_bytes, vacuum}` |
| `storage.run` | task (not cancellable): the task subscribes to `storage`, then `Storage.run(cached_plan)` → `{:ok, pid}` (monitored) → waits for done/failed/`:DOWN` (§3.3.8 rule 4); `{:error, :busy}` → `busy`/`A cleanup is already running.`; done summary `{freed_bytes, items, vacuum: {before, after} \| null, db_bytes_after, reclaimable_after}` (the last two feed the vacuum nudge of §2.18) |
| `storage.vacuum` | task (not cancellable): `Storage.running?()` → `busy`/`A cleanup is already running.`; else, in the task process, `Registry.register(SwarmCode.Domain.Registry, :storage_cleanup, nil)` (the same single-run guard `Storage.run/1` uses; `{:error, {:already_registered, _}}` → `busy`) and `Storage.vacuum/0`; `{:error, :runs_active}` → `a run is live; stop it first`; `{:error, {:disk, needed, free}}` → `needs <needed> free, <free> free` (bytes in words); done `{before, after}` |
| `storage.apply_retention` | task (not cancellable): both policies nil → `rejected`/`set a retention first`; `Storage.running?()` → `busy`/`A cleanup is already running.`; else, in the task process, the `:storage_cleanup` registration as above, then a selection built only from the non-nil days (`%{older_than_days: r}` and/or `%{prune_days: p}`, as `Storage.put_days/3` does), `Storage.plan(selection, Storage.sessions([]))`, `Storage.run_sync/1`, then `Settings.update_quiet(%{storage_last_cleanup_at: now})`; result as `storage.run`. Open conversations (the TUI's, §3.3.10) are kept back by the plan |

#### 3.5.6 Language servers (`Settings.LSP`)

`lsp.check` (task): for each of the 13 languages: built-in command (`LSP.Language` defaults), override
(`settings.lsp_servers`), effective (`off` → none), `installed` = `System.find_executable/1` of the
effective command's first word (null when none), `running` = clients per project root from
`Registry.select(SwarmCode.Domain.Registry, …)` on keys `{:lsp, root, language}`; plus `unknown_keys`
(keys of `lsp_servers` that are not one of the 13 languages, with their values). `lsp.stop`:
`target: {"project_id"}` or `{"all": true}` → `LSP.stop_project(root)` for that project / every
project in `Projects.list/0`. `lsp.remove_key`: `target: {"key"}` (must be one of `unknown_keys`),
`expected: {"value": <as read>}` → the map without that key in one `Settings.update/1` (CAS in the
transaction; `Cache.delete(:settings)` after the commit).

#### 3.5.7 Files and library (`Settings.Files`, `Settings.Library`)

| action / view | behaviour |
|---|---|
| `records:memory_files` | `options.project_id` → meta of three files: project memory (`Memory.file(:project, root)`), global memory (`Memory.file(:global, nil)` — never a path built from `config_dir`), and the project instructions file (`ProjectContext.instructions_path(project)`, with `winner`, `exists`, `trusted`, §2.23) — bytes, lines, fingerprint, `editable_in_place` |
| `records:commands` | `Commands.list(project)` + per-file meta; `overrides_global` when a project command shadows a global one; `shadowed_by_builtin: true` for the names `settings`, `config`, `prefs` |
| `records:agent_defs` | all three tiers for the page project: bundled (`Agents.bundled/0`), user dir, project dir, each file parsed with `Agents.parse/1` (errors → `parse_error`, file kept in the list); shadowing by case-insensitive name (project > user > bundled) |
| `records:skills` | `Skills.list(project)` with scope, description, file count/bytes, shadowing |
| `records:workflows` | `Workflows.list_all(project)` (or the per-scope listing functions) with scope and path; `smoke` from the declared task-cache entries |
| `file` (view) | resolve `ref` (§3.4.5) → path confined to its tier root (a symlink out of the root reads as `not_found`); content ≤ 262 144 bytes (else `too_large: true`, `content: null`); fingerprint = sha256 + size |
| `file.save` | `target: {ref}`, `attributes: {"content", "confirmed_hooks": bool}` (≤ 262 144 bytes), `expected: {"fingerprint"}` → CAS (a conflict answers the fresh fingerprint only, D33); memory: `Memory.write(scope, root, text)` (its own allowed root); instructions: `AtomicFile.replace(root, path, content)` confined to the project root (a missing file is created as `AGENTS.md`); workflow: `Workflows.save(project, scope, name, source)`; others: `AtomicFile.replace(root, path, content)`; result = file record + `parse` (`ok` or the parse error for agents/commands/config.json; smoke is separate). **config.json** (kind `project_config`): when the project is trusted, the service diffs the hook commands of the old and new text (per event, by command string); a new or changed command without `confirmed_hooks: true` answers `needs_confirmation` with `confirm: {kind: "hooks", items: ["post_tool_use: mix format", …]}` and writes nothing (the client shows the D14 dialog, §4.8, then re-sends with `confirmed_hooks: true` and the same `expected`); after any successful config.json save, `Projects.broadcast/0` outside the transaction (the engine's hook cache, §3.5.8) |
| `file.create` | `target: {"kind": "command" \| "agent" \| "skill", "scope", "project_id"?, "name"}`; refuses an existing name (`already exists`) or a bad name (kind rule); writes the template (§2.23) atomically, creating the tier directory with mode 0700 (`File.mkdir_p/1` then `File.chmod/2`) |
| `file.delete` | `target: {ref}`, `expected: {"fingerprint"}`; bundled/builtin → `rejected`/`a built-in file cannot be deleted; make a user copy to override it`; workflows via `Workflows.delete/3`; a skill directory is removed only when it holds ≤ 32 regular files and no symlinks (else `rejected`/`this skill folder holds more than skill files; remove it yourself: <path>`); instructions cannot be deleted here (`rejected`/`edit it instead; delete the file yourself if you mean to`) |
| `file.clear` | memory refs only: writes `""` (CAS on fingerprint) |
| `workflow.smoke` | task: the domain's workflow smoke lint (`SwarmCode.Domain.Workflows.Smoke`) for one ref or every user/project workflow; results cached per workflow |

#### 3.5.8 Project config (`Settings.ProjectConfig`)

- `record:project_config` (`id` = project id): read `<root>/.swarm_code/config.json` (≤ 1 MiB) with
  `Jason.decode(text, objects: :ordered_objects)`; `parse` state; on a decode error compute `line` and
  `column` from the byte offset; `hooks` per event (index, command, matcher, timeout_ms, output_cap —
  raw values), `profiles`, `top_level` (the four ignored keys when present), `denied` (denylisted keys
  present), `unknown_keys`, `fingerprint`, `trusted` (hooks run only when the project is trusted), and
  **`ignored_entries`** — every entry the domain's parser (I§5.2) drops or bends, each `{path, reason,
  severity}` (≤ 64): an unknown event name (`hooks.post_edit` · `unknown event post_edit` · error), a
  non-list event value or a non-map hook entry (`not a hook` · error), a hook without a non-empty
  `command` (`no command · dropped` · error), a matcher that does not compile (`matcher "*.ex" is not a
  regular expression · runs for every tool` · warning), a non-integer or out-of-range `timeout_ms` /
  `output_cap` (`timeout 50000 · used as 30000`, `timeout "10s" · used as 10000` · warning), a profile
  name that fails `\A[\w-]+\z` / 1..32 bytes or a non-map profile (`not a profile name · dropped` ·
  error), a profile key other than the four (`profiles.fast.mode · not a profile key` · warning).
- Structured writes: read ordered → CAS on the file fingerprint (`expected.fingerprint`) → modify →
  encode pretty with key order preserved → `AtomicFile.replace(root, path, json)`; a missing file starts
  from an empty object (creating `.swarm_code/` with `Projects.Workspace.ensure!/1`); an invalid file →
  `rejected`/`the file is not valid JSON; fix it first (e opens it)`. Unknown keys survive every write
  with semantically equal values in the same order and nesting (a pretty re-encode normalises
  formatting: `1.10` becomes `1.1`, escapes and whitespace may change — the tests compare decoded
  values, not bytes).
- **After every successful write** of config.json — structured `project_config.*`, `file.save` of kind
  `project_config`, `values.patch` on `project_file.*` — call `Projects.broadcast/0` outside any
  transaction. `Cache.invalidate(:project)` drops `{:project, {:config, root}}`, so the engine's
  `Hooks.cached_config/1` (keyed by mtime seconds and size) re-reads even a same-size edit or a hook
  reorder made within the same second. A test moves a hook twice within one second and asserts the
  engine-side read returns the new order.

| action | target | attributes | behaviour |
|---|---|---|---|
| `project_config.put_hook` | `{project_id, event, "index": null \| i}` | `{command, matcher, timeout_ms, output_cap, "confirmed": bool}` | validate (§2.23 hook; regex compiled with `Regex.compile/1`); null index appends; a new or changed command in a trusted project without `confirmed: true` → `needs_confirmation` (the client asks first, so this only guards other callers) |
| `project_config.delete_hook` | `{project_id, event, index}` | — | remove |
| `project_config.move_hook` | `{project_id, event, index}` | `{"dir": -1 \| 1}` | swap |
| `project_config.put_profile` | `{project_id, "name": null \| old name}` | `{name, effort, swarm_effort, model, swarm_model}` (nulls drop keys) | validate name and uniqueness; rename keeps order position |
| `project_config.delete_profile` | `{project_id, name}` | — | remove |
| `project_config.remove_key` | `{project_id, key}` | — | only the four ignored keys or denylisted keys |
| `project_config.remove_entry` | `{project_id, path}` | — | only a `path` listed in `ignored_entries` (e.g. `hooks.post_edit`, `hooks.pre_tool_use[2]`, `profiles.fast.mode`); removes that key or list element |

Also exported to S1: `read_top_level(project) :: %{key => value}` and `remove_top_level(project, keys,
expected_fingerprint)` (for `values.patch` on `project_file.*`; it broadcasts after the write as above),
`profiles(project)`.

#### 3.5.9 Secrets helper (`Settings.Secrets`, S2)

`take(command, slot) :: {:ok, value} | :error`; `masked_entries(map) :: [%{name, secret, value, hint}]`
(secret by `SecretPattern.secret_kv?/2`); `redaction_list(record) :: [String.t()]` (provider key,
search key, MCP secret values); `check_paste(value) :: :ok | {:error, message}` (trimmed; one line —
else `paste only the key: it had N lines`; no inner whitespace — else `a key has no spaces inside`; 8..8 192
bytes — else `that is too short to be a key` / `that is too long to be a key`); every handler module
calls these, never formats secrets itself. The 8-byte floor matches `LLM.HTTP.redact/2`'s minimum, so
every stored secret is also redactable (§3.3.8 rule 6 covers shorter legacy values).

### 3.6 Client data source (S1)

- `UI/data_source/request.ex`: kinds `:settings_query` and `:settings_command`; origin
  `{:settings, generation :: pos_integer(), purpose :: term()}` where purpose is built only from atoms,
  integers and registry-bounded strings; expected responses `:settings_snapshot`, `:settings_result`.
  Constructors `Request.settings_query(params, origin, deadline_ms)` and
  `Request.settings_command(command_map, origin, deadline_ms)`; `Request.validate/1` calls
  `SwarmCode.Settings.WireBounds.valid?/2` (§3.4.1) so an out-of-bounds request is refused before it is
  sent; `Inspect` hides `secrets`.
- `UI/data_source/daemon/codec.ex`: request bodies (exact key sets of §3.4.1), response decoding of the
  two new `response_kind`s into the DTOs of §3.4.6, **an `outcome` reply to a `:settings_result` request
  mapped to `DTO.SettingsResult`** (§3.4.2: `response_kind_matches?/2` accepts `"outcome"` for that
  expected response only), deltas `settings_update` / `settings_task` at global scope.
- `UI/effect.ex` (one clause, S1-6, then U1's file): `validate({:command, %Request{expected_response:
  :settings_result}})` accepts a valid settings command request (today only `:outcome` commands pass).
- `UI/effect_runner.ex`: error bodies for the two new expected responses; a data-source failure of a
  settings request becomes `{:settings_failed, request_id, words}`.
- `UI/data_source/daemon.ex`: `format_status/1` also redacts `:message` (§3.3.10).
- `UI/data_source/fake.ex` + `UI/data_source/fake/settings.ex` (`SwarmCodeCLI.UI.DataSource.Fake.Settings`,
  S1): an in-memory store seeded with Appendix A; answers the views `values`, `overview`, `facts`,
  `usage`, `open`, `task`, `records:projects` and the actions `values.patch`, `values.reset`,
  `profile.apply`, `task.cancel` with the same CAS and validation rules (registry validators; `:svc`
  checks simulated for `provider_exists` and `effort_of_model`), plus a **data-driven record store**
  (`records`/`record` of any kind from the seed, generic `{fields}` CAS) and the **generic task
  lifecycle** (`running` on start, `done` on the next `Fake.step/1` or at once with `auto_tasks: true`,
  results read with `view=task`). Every other action goes to `Fake.SettingsIntegrations` (U2) when it is
  loaded, else answers `unsupported`. Test controls: `Fake.Settings.put(fake, key_or_record_path,
  value)` (a change elsewhere + a `settings_update` delta with origin `elsewhere`), `fail_next(fake,
  action, %{status, message, field_errors})`, `hold_task(fake, action)` / `release_task(fake, action,
  result | {:error, message})`, `reply_outcome_next(fake, status)` (an `outcome` reply, §3.4.2),
  `stub_reply(fake, action, reply | (command -> reply))` (scripts an action the Fake does not simulate,
  for U3's tests of `project_config.*` and config.json saves),
  `requests(fake)` (for assertions; secrets appear as `[REDACTED]`), `secret_writes(fake)` (`[{action,
  slot, sha256 hex}]`, never the value).
- `UI/data_source/fake/settings_integrations.ex` (`Fake.SettingsIntegrations`, **U2**): simulates the S2
  actions against the same store — provider create/update/set_key (incl. `test_first`)/clear_key/delete
  with replacements/test/fetch (the Appendix A difference)/apply_models, efforts, pricing, search,
  MCP (incl. import with variables), storage, LSP, files, library and project config — with the §3.5
  messages. S1 never simulates S2's behaviour.
- Conformance: `CLIT/support/request_conformance.ex` and `contract_fixtures.ex` gain the two ops,
  their param sets, and the two response kinds.

### 3.7 The client settings layer (U1 shell; U2/U3 sections)

All modules under `SwarmCodeCLI.UI.Settings.*` are **pure** (no IO, no clock, no ids of their own):
time, ids, sizes and capabilities come from the reducer's inputs, IO happens through effects run by the
session runtime or the data source (A§5.1).

#### 3.7.1 State

`State` gains: `settings :: nil | Layer.t()`, `settings_resume :: nil | map()` (the page stack and
focus kept after a close, for the next `/settings`), `settings_history :: Undo.t()` (past ≤ 100, future
≤ 100, changelog ≤ 200 — kept for the whole session, so undo and *changed in this session* survive
closing the layer, D38), `settings_generation :: non_neg_integer()`,
`prefs :: map()` (every cli.json value by json name, from `Preferences`), `key_overrides ::
Keymap.Overrides.t()`, `launch_facts :: map()` (§3.8.4: `env_overrides`, `flag_overrides`, the project root and the launch flags), `pending_open_settings :: nil | String.t()`.

```elixir
defmodule SwarmCodeCLI.UI.Settings.Layer do
  @derive {Inspect, except: [:paste, :drafts]}
  defstruct generation: 1,
            restore: nil,             # %{focus, draft_key, chat_scroll} put back on close (the overlay's pattern)
            stack: [],                # [%Page{section, record: nil | {kind, id}, sub: nil | term, cursor: row_id | nil, scroll: 0}], head = current
            region: :page,            # :search | :rail | :page | :detail
            rail_cursor: :overview,
            mode: :browse,            # :browse | :search | :command_line | :editing | :paste | :capture
            search: nil,              # %{query, results, cursor, entered_from}
            command_line: nil,
            editing: nil,             # %{row_id, write_key, editor, state, original}
            paste: nil,               # %Paste{} (§3.7.7)
            popover: nil,             # {:picker | :confirm | :help | :pending_leave | :project_picker, spec}
            data: %Data{},            # values, records, record, files, overview, facts, usage, cli (§3.7.4)
            requests: %{},            # request_id => purpose
            writes: %{},              # write_key => %{request_id, value, old, queued}
            step: nil,                # number stepping: %{write_key, value, deadline_ms}
            conflicts: %{},           # write_key => %{mine, theirs, origin}
            row_errors: %{},          # row_id => message
            tasks: %{},               # task_id => %{action, target, state, elapsed_ms, received_at_ms, progress, result, message, mine?}
            drafts: %{},              # draft kind => %{fields, secrets, errors, dirty?}  (one per kind)
            staged: %{},              # {kind, id} => %{field => value} (MCP connection fields)
            filter: nil,              # %{page_ref, query} — the in-page list filter (D37)
            treat_secret: MapSet.new(),# {kind, id, map, name} marked "treat as secret" this session (§2.23 mcp env)
            status: nil,              # %{text, role, until_ms}
            changed_elsewhere: %{},   # row_id => until_ms
            deep_link: nil,           # a pending focus target resolved when data arrives
            page_project_id: nil      # project picker choice; nil = the session's project
end
```

#### 3.7.2 Section and editor API (published by U1 in `c74-U1-api`)

```elixir
defmodule SwarmCodeCLI.UI.Settings.Section do
  alias SwarmCodeCLI.UI.Settings.{Ctx, Row, Op, Attention, Detail}
  @callback id() :: atom()
  @callback loads(Ctx.t()) :: [Op.load()]                 # data the current page needs
  @callback rows(Ctx.t()) :: [Row.t()]                    # the section page, pure
  @callback record_rows(Ctx.t(), kind :: String.t(), id :: String.t()) :: [Row.t()]
  @callback sub_rows(Ctx.t(), sub :: term()) :: [Row.t()]
  @callback act(Ctx.t(), Row.t(), action :: atom()) :: [Op.t()] | :default
  @callback commit(Ctx.t(), Row.t(), wire_value :: term()) :: [Op.t()] | :default
  @callback title(Ctx.t()) :: String.t()                  # page title incl. "unsaved · Ctrl-S creates it · Esc discards"
  @callback attention(Ctx.t()) :: [Attention.t()]
  @callback counts(Ctx.t()) :: %{records: non_neg_integer() | nil}
  @optional_callbacks record_rows: 3, sub_rows: 2, act: 3, commit: 3, title: 1, attention: 1, counts: 1
end
```

`use SwarmCodeCLI.UI.Settings.Section, id: :agents_limits` injects defaults: `loads/1` →
`[{:values, [section]}]`, `rows/1` → `Rows.registry(ctx, section)` (every registry entry of the
section, grouped by `group` in registry order, `Rows.scalar/2` each, then the danger group), `act/3`
and `commit/3` → `:default` (U1's generic handling).

`SwarmCodeCLI.UI.Settings.Sections.module_for(id)` is a compile-time map of the 22 section ids to the
module names of §3.1; a module that is not loaded falls back to the default implementation (the page
still shows every registry row of that section), so any branch runs end to end.

`%Row{}` (`UI/settings/row.ex`): `id` (stable in the page: `key:<registry key>`,
`rec:<kind>:<id>`, `fld:<kind>:<id>:<field>`, `act:<name>`, `head:<group>`, `item:<list>:<n>`),
`kind` (`:setting | :record | :field | :action | :heading | :info | :link | :list_item | :kv_item`),
`key`, `label`, `value` (`[{text, role}]` segments), `tag` (segments, right-aligned), `marks`
(`:changed | :attention | :invalid | :running | :pending | :conflict`), `lines` (continuation lines),
`editor` (`nil | {module, opts}`), `keys` (`[{key_label, action, words}]` for the footer and the detail),
`detail` (`nil | %Detail{}`), `state` (`:normal | :readonly | :disabled | :loading | :running`),
`columns` (`nil | [{text, role, priority}]` for record tables), `target` (opaque for `act/3`).

`Op` values (`UI/settings/op.ex`): `{:patch, key, wire_value}` · `{:reset, [key]}` · `{:reset_section,
id}` · `{:command, action, target, attributes, %{expected, write_key, secrets_from, undo, toast}}` ·
`{:task, action, target, attributes}` · `{:cancel_task, task_id}` · `{:load, load}` where `load ::
{:values, sections} | {:records, kind, options} | {:record, kind, id} | {:file, ref} | :overview | :facts
| :usage | {:auto_task, action, target}` · `{:open, page}` · `:back` · `{:section, id}` · `{:confirm,
%Confirm{}, then: [op]}` · `{:picker, %Picker{}}` · `{:paste, paste_target}` · `{:edit, row_id}` ·
`{:external_edit, %{ref, content, fingerprint, suffix}}` · `{:cli_write, %{json_name => value |
:remove}}` · `{:open_folder, path}` · `{:copy, text}` · `{:toast, text, role}` · `{:leave, then}`.

How the two OS-facing ops run (U1, through the session runtime's owned tasks, never in the reducer):

- `{:copy, text}` → the runtime's existing clipboard effect (OSC 52 through the terminal port, the path
  `/copy` uses today). When the terminal does not support it (the port's capability flags) the toast
  reads `Couldn't copy · the path is shown in the detail`. Never used for a secret (`y` on a secret row
  copies the key name).
- `{:open_folder, path}` → an owned task that runs `open <path>` (macOS) or `xdg-open <path>` (Linux,
  only when `DISPLAY` or `WAYLAND_DISPLAY` is set and the session is not over SSH — `SSH_CONNECTION`
  unset) with a 5 s timeout; otherwise the toast `No desktop to open folders here · y copies the path`.
  A folder that does not exist (a commands, agents or skills tier with no file yet) is not created by a
  read: the toast reads `That folder does not exist yet · n creates the first file in it` (`file.create`
  creates the tier directory 0700, §3.5.7). The desktop's `mkdir_p` on open is deliberately not copied.

Editor behaviour (`UI/settings/editor.ex`):

```elixir
@callback init(Row.t(), opts :: map(), Ctx.t()) :: {:ok, state :: term()} | {:error, String.t()}
@callback handle(state, event, Ctx.t()) ::
            {:cont, state} | {:commit, wire_value :: term(), state} | {:cancel, state} | {:ops, [Op.t()], state}
            # event :: {:key, :enter | :escape | :left | :right | :up | :down | :tab | :backtab | :home | :end |
            #          :backspace | :delete | :space | :page_up | :page_down | {:ctrl, char} | {:shift, atom}}
            #        | {:text, String.t()} | {:paste, String.t()} | {:raw, {code, mods}} (capture only) | :tick
@callback display(state, Ctx.t()) :: %{value: [segment], lines: [[segment]], popover: nil | map(),
                                        context: atom(), footer: [{key_label, words}]}
```

Text inside editors lives in `FieldEditors` under the new `FieldKey` variants
`{:settings_field, generation, row_id}`, `{:settings_query, generation}`,
`{:settings_command_line, generation}` (≤ 3 editors open at once; the owner closes them with
`FieldEditors.close_owner/2` on close).

#### 3.7.3 Open, close, levels

- **Open** (`Reducer.Settings.open(state, arg, now)`): `generation = state.settings_generation + 1`;
  the restore point (focus, current draft key, chat scroll); the page stack from `DeepLink.resolve/2`
  (§3.7.12) or `settings_resume`; effects: **one** `settings.query view=open` (values of every
  section, overview, facts, projects — one job, §3.3.6), `{:settings_cli_read, generation}` (fresh
  cli.json values, mode, size, fingerprint), the current page's `loads/1`, and a `view=task` query for
  every task the session still knows (the tasks map of a closed layer is kept in `settings_resume`).
- **Close** (Esc at a section page, `q`, `Ctrl-C` outside an editor, `/settings` again): pending check
  (§3.7.10) → close: cancel the cancellable tasks this layer started (`task.cancel`; non-cancellable
  ones keep running and their rows come back on reopen), close the layer's editors, drop the paste,
  restore focus/draft/scroll, keep `settings_resume` (page stack, focus, tasks map); undo history stays
  in `State.settings_history` (D38).
- **Levels:** layer › section page › record page › sub-page. Esc pops one level and restores the
  parent's cursor and scroll; in an editor Esc cancels the editor first; in search Esc clears the query,
  then leaves search. The header always says where Esc goes.
- **Stale data:** every response is matched by `request_id` and `generation`; a response for another
  generation, or for a page that is no longer on the stack, is dropped. A values snapshot whose
  `revision` is older than the newest `settings_update` revision seen for any of its sections is kept
  for display but immediately re-queried (it may predate a change); a `:stale_revision` failure of a
  request the layer already superseded is ignored.
- **Deltas:** `settings_update` whose sections intersect the loaded sections → re-query `values` for
  them and re-run the current page's `loads/1`; rows whose value changed without a local pending write
  get `changed elsewhere in this session` (faint, 2 s). `settings_task` → `tasks` map; on `done` the
  layer queries `view=task` for the result when a visible row needs it (difference rows, preview
  tables, plan items; summaries cover the rest). After a watch resync or `watch_ready`, every task in
  the map is re-queried with `view=task` (a task whose final delta was lost would otherwise stay
  `running`). `toast` deltas
  from the rest of the session while the layer is open are queued and shown after it closes, except run
  failures, which appear on the settings status row for 4 s (T§4.3). `workspace_metadata` → re-query
  `values` of `models_effort` (session keys).
- **Runs keep running** under the layer; the header shows `! N needs you · <who> wants to <verb> · ^N`
  from the same facts the shell's band uses; `Ctrl-N` closes the layer (resume kept) and focuses the
  card.

#### 3.7.4 Data held by the layer

`%Data{values: %{key => SettingValue}, values_loaded: MapSet of sections, records: %{{kind, options} =>
%{items, next_cursor, total, loaded_at}}` (≤ 8 pages per kind, oldest dropped), `record: %{{kind, id} =>
record}` (≤ 16), `files: %{ref => file}` (≤ 3 with content — the Memory & instructions page shows
three), `task_views: %{task_id => %{summary, pages: %{cursor => rows}}}` (≤ 4 tasks × ≤ 5 pages of 200
rows, the least recently shown dropped and re-queried with `view=task` when shown again), `overview`,
`facts`, `usage`, `cli: %{values, status, mode, size, fingerprint, unknown}`}. The client composes `:cli` entries' SettingValues itself
(`Provenance.cli_value(entry, cli, launch_facts, values)`): layers `flag`/`env` from launch facts,
`cli` from the file, `global` through `entry.follows` (e.g. `desktop.mode`), `default`.

#### 3.7.5 Rows from the registry (`Rows.scalar/2`)

For a registry key: label, value display by type (§4.5), tag = the winner (`default` faint, else the
layer word muted + its source faint: `env SWARM_THEME`, `flag --model`), marks (`•` when winner ≠
default, `!` when `state == "attention"`, `✗` row error, `◷` pending > 300 ms), continuation lines
(env/flag override: `<VAR>=<value> wins while set · cli.json: <stored>`; desktop-only: `no effect in the
terminal`; scheduler-only: `schedules run only while the desktop app runs`; next-launch: `applies at the
next launch` after a change; conflict lines, §3.7.9), the editor from the type, and a detail built from
the entry (§4.6).

#### 3.7.6 The commit path

1. An editor commit, a section op or a reset produces an Op. `{:patch, key, v}` → write key
   `{:value, key}`, `expected = data.values[key].base` (or the cli value for `:cli` keys); records and
   files use the write keys `{:record, kind, id, field}`, `{:secret, kind, id, slot}`, `{:file, ref}`.
2. **One in-flight write per write key.** A second commit for the same key while one is in flight
   replaces its `queued` value; when the first answers `accepted` or `unchanged`, the queued value is
   sent with `expected` = the value the first write stored. When the first answers `conflict`,
   `rejected` or a failure, the queued value is **dropped, never sent automatically**: it becomes *mine*
   in the conflict row (§3.7.9) or is named in the status (`Couldn't save; your later change to <Label>
   was not sent`).
3. The row shows the new value at once; after 300 ms without an answer the tag shows `saving…` (faint).
4. `accepted` → `base` updated from the result, toast (§4.7), undo step, changelog entry; the delta that
   follows refreshes provenance. `unchanged` → no toast. `conflict` → conflict row (§3.7.9), no undo.
   `rejected` → the old value back, `✗ <message>` under the row, status `Couldn't save: <message>`;
   Enter re-opens the editor with the typed value. `unavailable`/`busy`/`not_found`/data-source failure
   → old value back, the message on the status row.
5. `:cli` keys: effect `{:settings_cli_write, generation, ref, changes, expected}` → the session runtime
   runs `Preferences.write_changes/3` (→ `CliFile.write_changes/3`) in an owned task →
   `{:settings_cli_result, generation, ref, result}` with the same outcomes; on success the live
   consumers apply (§3.8.5).
6. Number stepping (`←`/`→` one `step`, `Shift-←`/`Shift-→` one `big_step`) writes 600 ms after the
   last step or when focus leaves the row (one write, one toast, one undo step); the settle timer uses
   the existing timer effect.
7. A request `Request.validate/1` refuses (WireBounds, §3.4.1) never leaves the client: the row shows
   `✗ That is too long to save here (<param>)` and the old value stays.

#### 3.7.7 Secrets in the client (the paste target)

`%Paste{target, bytes, lines, typing?, pending_task}` (`UI/settings/paste.ex`, `@derive {Inspect, only:
[:target, :lines]}`): Enter on a secret row opens it (mode `:paste`, context `settings_paste`). A
bracketed paste replaces `bytes`; typed printable keys are ignored with the status `typing is ignored
here · paste with Cmd-V · Ctrl-T types instead` — unless `caps.paste == :unavailable` or the user
pressed `Ctrl-T` (*type instead*, available under every `caps.paste` value, for terminals and
multiplexers that do not bracket pastes), then typed characters are appended to the same `bytes` and
never echoed (the row says `typing · not shown`). Ctrl-U clears. The row shows `●●●●●●●● pasted · not
shown` (always 8 marks, `********` in ASCII) and `not saved` (warning). Enter checks (one line — else
`the paste had N lines; paste only the key`; no inner whitespace; 8..8 192 bytes after trim — else
`that is too short to be a key`) and sends the section's command with `secrets: [%{slot, value:
bytes}]`.

- **First key** (the stored secret is not set) and drafts: the command saves; the paste is dropped when
  it is sent; the automatic test follows (§4.9).
- **Replacing a key** (the stored secret is set): the command carries `test_first: true` (§3.5.1); the
  row shows `◷ checking the new key…`; the paste is kept (`pending_task` = the task id) until the task
  ends. Done → toast `<Name> API key replaced · the new key listed N models` and the paste is dropped.
  Failed/timeout → the row reads `The new key was refused (<words>). s save it anyway · Esc keep the old
  key`; `s` re-sends with `test_first: false` (the second and last time the bytes travel), Esc drops the
  paste; either way the paste is gone afterwards. `c` cancels the check (the old key stays).

Esc drops the paste. Drafts keep pasted secrets in `drafts[kind].secrets` (Inspect-hidden) until the
create command is sent or the draft is discarded. Pasted bytes never enter `FieldEditors`, rows, the
scene, undo, the changelog, toasts, the search index, logs or `Inspect` output.

#### 3.7.8 Generic editors (U1, `UI/settings/editors/*.ex`)

Toggle · Enum (segmented when ≤ 5 choices fit the value column, else a picker popover with a filter)
· Checklist (a list of more than 20 items gets the `/` filter) · Number (integer, duration, money;
stepping — `←`/`→` step, `Shift-←`/`Shift-→` and, inside the open editor, `PgUp`/`PgDn` big step —
typing, bounds, specials, nullable with Ctrl-U) · Text (single line; completion for paths, model ids, env names) · Multiline (≤ 16 384 bytes,
Enter inserts a line break, Ctrl-S saves, Ctrl-X external) · List (sub-rows, `a` add, `Enter` edit,
`x` remove, `J`/`K` move when ordered, `X` remove all with confirmation; item validation; only the
visible rows are projected, and a list of more than 20 items gets the in-page `/` filter, D37) ·
KeyValue (two columns; entries secret by `SecretPattern.secret_kv?/2` — or marked with `s` *treat as
secret* — become paste targets) · Path ·
LspCommand (enum default/off/custom + text) · ModelFallback (text `provider name · model`, used only
when U2's `ModelPicker` is not loaded) · ReadOnly · Action. Custom editors from other owners are
`{module, opts}` pairs implementing the Editor behaviour: U2 `ModelPicker` (type `:model`), U3
`KeyCapture` (types `:keys` entries and `:combo`), U3 `Color` (`:color`).

#### 3.7.9 Conflicts

A `conflict` result keeps the attempted value as *mine* and the result's `current` as *theirs*; the row
shows (warning) `! changed while you edited (<origin>): now <theirs>` and `Enter keep yours (<mine>) ·
Esc take theirs (<theirs>)`. Enter re-sends *mine* with `expected = theirs` (a proper CAS against what
was just seen); Esc discards *mine* and shows *theirs*. Origin words: `elsewhere in this session` (the
common case), `by the desktop app` is never claimed (the CLI cannot know). A queued value dropped by
the conflict (§3.7.6 step 2) is what *mine* shows. **File conflicts** (after an in-place edit or an
external edit) carry only the fresh fingerprint (D33): the layer keeps the user's text in the editor
(or the private temp copy), re-reads the file with `settings.query view=file`, and asks: `The file
changed while you edited. s save yours over it · e edit again · Esc keep the file's version`; `s`
re-sends `file.save` with `expected` = the re-read fingerprint.

#### 3.7.10 Undo, changelog, reset, drafts, pending on leave

- **Undo** (`UI/settings/undo.ex`, stored in `State.settings_history`, D38): a step is `%{write_key,
  label, old, new, inverse :: Op, redo :: Op}`; `u`/`Ctrl-Z` sends the inverse (a normal CAS write with
  `expected = new`; after a reopen the value may have moved, and the CAS then shows the usual conflict
  row), `U`/`Ctrl-Y` re-sends the redo. Not undoable (and logged with `· no undo`): secrets, record
  creation/deletion, file clear, storage cleanup/vacuum/retention, import apply of records, reset
  everything. A section reset and a scalar import batch are one step each (the inverse `values.patch` of
  a 70-key import stays inside the 256-change bound). Bounds: 100 past, 100 future, 200 changelog
  entries.
- **Reset:** `r` on a row → `{:reset, [key]}` (cli keys → `{:cli_write, %{name => :remove}}`); on a
  staged MCP field `r` reverts it to the stored value, on the MCP record head it discards every staged
  field (never a restart — that is `R`, D8); on an invalid row (D34) `r` writes the default with
  `expected` = the raw stored value; a section's `▸ Reset this section…` confirms with the list of
  values that change.
- **Drafts:** one per kind (`provider`, `mcp_server`, `pricing_row`, `effort_levels`, `hook`,
  `profile`, `command`, `agent`, `skill`); the page title says `unsaved · Ctrl-S creates it · Esc
  discards`; a second `a` returns to the open draft.
- **Pending on leave:** leaving a page (Esc, `[`/`]`, a rail jump, close) with a paste, a dirty draft,
  an unapplied fetch difference, an unsaved multi-line text, or staged MCP fields that do not validate →
  `N things are not saved here: <list> · s save what can be saved · d discard · Esc stay`. Valid staged
  MCP fields are applied (one `mcp.update`) on leaving without asking (D8). An invalid typed value is
  discarded and named in a toast.

#### 3.7.11 Search and the command line

- **Index** (`UI/settings/search.ex`): one entry per registry entry, per loaded record (providers,
  search providers, MCP servers, pricing rows, key-binding actions, agent definitions, commands,
  skills, workflows, hooks, profiles), per **provider model** (`deepseek-v4-lite` → the provider's
  record with the models row focused on it) and per **MCP tool** (`create_issue` → the server's record
  with the tool focused), and per section; fields: label, section title, key, stored name, synonyms,
  description, displayed value (never for secrets; never an MCP env/header value), record columns. ≤ 8 000
  entries and ≤ 2 MiB (models and tools of records not loaded yet are indexed when their record list
  loads; beyond the bound the oldest-loaded record's items are dropped first and the results page says
  `some models and tools are not searched; open their provider or server`); rebuilt when data changes
  (not per keystroke).
- **In-page filter (D37):** in a list sub-page, a record table or a checklist of more than 20 rows, `/`
  opens a filter on that list only (context `settings_search`, the header reads `/ filter 312 models ·
  7 match`); matching is the same word-prefix rule over the list's columns; Enter goes to the focused
  match; Esc clears the filter, a second Esc leaves the page as usual. `/` on an empty local filter
  switches to the global search; `:goto` always reaches it.
- **Matching:** case-insensitive; words AND; each word a prefix of a word in any field; `@filters`:
  `@modified @env @flag @session @project @file @cli @shared @secret @attention @restart @new
  @section:<id> @key:<prefix>`; when words match nothing, a subsequence pass over labels and keys headed
  `close matches`. Ranking: exact key > label prefix > label word > synonym > key word > description >
  value > model/tool item > fuzzy; ties in rail then page order. Empty: `Nothing matches “xyz”.` + up to three keys by
  edit distance + `Try @modified, @env, or a key such as limits.command_timeout.`
- **Results page:** grouped by section in rail order with counts; scalar results are real rows
  (`Rows.scalar/2`, editable in place); record results are link rows (`Enter open`). The rail shows
  per-section counts and ghosts sections without matches. `g` on a result goes to it in its section.
- **Command line** (`:`, replaces the search row): `:set <key> <value>`, `:get <key>`, `:reset <key>`,
  `:goto <section | key | words>`, `:undo`, `:redo`, `:export <path>`, `:help`. Values are parsed by
  `SwarmCode.Settings.TextValue.parse(entry, text)` (core, S1; the same parser as `swarmcode config
  set`); Tab completes keys, enum values, `default`, `null`. The result is a toast; an error stays on
  the line.

#### 3.7.12 Deep links (`UI/settings/deep_link.ex`)

`resolve(arg, ctx)`: blank → `settings_resume`, else Overview (focus the first attention item once the
overview arrives); `@…` → search with the argument; a section (`Sections.fetch/1`) → that section; a
registry key, a stored name, or a synonym (`Registry.synonyms/0`: `theme` → `terminal.theme`, `dark
mode` → `terminal.theme`, `vim` → `terminal.keymap`, `editor` → `terminal.editor`, `model` →
`models.chat`, `effort` → `efforts.default`, `budget` → `budget.monthly_usd`, `retention` →
`storage.retention_days`, `lsp` → section `language_servers`, `mode`/`plan`/`consensus`/`ultra` →
`session.mode`, `agents.md`/`instructions` → the instructions row of Memory & instructions,
`tavily`/`exa`/`brave`/`serper`/`jina`/`firecrawl` → that search provider's record) → its section with the row focused; otherwise a record name
(case-insensitive exact, providers and MCP servers, resolved when those records load; one match opens its
record page) → else search with the words.

#### 3.7.13 Projector (`UI/projector/settings.ex` + `UI/projector/settings/*.ex`)

`Projector.project/1` uses the settings regions when `state.settings` is set (the overlay precedent);
layers above it (the palette) and the layer's own popover draw on top. Regions: header, search row (or
section strip under 120 columns), rules, rail, page, detail (≥ 160) or drawer (< 160), status row,
footer. Only visible page rows are built (row heights by wrapping at the current width), so the paint
budget (4 096 nodes, A§5.13) holds for any page. Geometry, words and glyphs: §4.

### 3.8 cli.json and the terminal preferences (S1 file layer, U1 wrapper and consumers, U3 launch)

#### 3.8.1 `SwarmCode.Settings.CliFile` (S1, core) and `UI.Init.Preferences` v2 (U1)

The cli.json file layer lives in core as **`SwarmCode.Settings.CliFile`** (`CORE/settings/cli_file.ex`,
S1, shipped in the first S1 tag `c74-S1-core`), so `swarmcode config` (S1) and the TUI (U1) share one
implementation and the S1 branch can build and test the headless cli half on its own.
`SwarmCodeCLI.UI.Init.Preferences` (U1) becomes a thin wrapper: it keeps the legacy `read/1`, `read/2`,
`write/2`, `valid?/1` API (the four legacy atom keys) and delegates `read_all/1` and `write_changes/3` to
`CliFile`.

- `@max_bytes 65_536` (D20). Reads refuse a file larger than that (`:too_large`) and keep defaults.
- **Registry-driven.** The known json names are `SwarmCode.Settings.Registry.cli_entries/0` (each entry
  with `storage: {:cli, json_name}`); values are checked with `SwarmCode.Settings.Validate.check/2`
  and converted with `WireValue.from_json/2`. In `Preferences`, the old module attribute `@keys` is kept
  only as the mapping of the four legacy atom keys (`panel_mode → "panel"`, `show_diffs`, `theme`,
  `mouse? → "mouse"`) so `read/1`, `write/2`, `valid?/1` and the `{:save_preferences, _}` effect keep
  working unchanged for `/panel`, `/diff`, `/theme`, `/mouse`.
- `CliFile` API:

```elixir
@type snapshot :: %{
        values: %{String.t() => term()},     # valid known keys only (json name => wire value)
        invalid: [String.t()],               # known keys present with a bad value (default used)
        unknown: [String.t()],               # kept on every write, listed in Files & environment
        fingerprint: String.t() | nil,       # sha256 hex of the bytes read; nil when absent
        mode: non_neg_integer() | nil,       # file mode & 0o777
        size: non_neg_integer(),
        status: :ok | :absent | :too_large | :unreadable | :not_json | :symlink
      }
@spec read_all(Path.t() | nil) :: snapshot()
@type change :: term() | :remove
@type expectation :: term() | :absent | :any
@spec write_changes(Path.t(), %{String.t() => change}, %{String.t() => expectation}) ::
        {:ok, snapshot()} | {:conflict, %{String.t() => term() | :absent}} | {:error, :invalid, %{String.t() => String.t()}}
        | {:error, :too_large | :unreadable | :not_json | :symlink | :busy | File.posix()}
@spec write_text(Path.t(), String.t(), expected_fingerprint :: String.t() | nil) ::   # the external-edit return (§2.21)
        {:ok, snapshot(), warnings :: %{String.t() => String.t()}} | {:conflict, String.t() | nil}
        | {:error, {:not_json, line :: pos_integer()} | :too_large | :symlink | File.posix()}
```

- `write_changes/3` in order: `lstat` (a symlink → `{:error, :symlink}`; the words: `cli.json is a
  symbolic link; SwarmCode will not replace it`) → read the current bytes and map (absent = `%{}`; not
  JSON → `{:error, :not_json}` unless every change is a removal, never silently replace a broken file)
  → compare every expectation (`:any` skips; `:absent` means the key must not be present; values compare
  after `WireValue.normalize/2`); any mismatch → `{:conflict, current}` for the mismatched keys →
  validate every change (unknown json name or a failed check → `{:error, :invalid, %{name => message}}`)
  → put/remove → `JSON.encode!/1` of the merged map (unknown keys kept) → size check (> 65 536 →
  `{:error, :too_large}`) → write the temporary `.cli.json.<random>.tmp` in the same directory
  (`:exclusive`, chmod 0600) → **re-read the file's fingerprint just before the rename**: when it moved
  since step 2 (another process wrote in between), remove the temporary and start again from the read
  once; a second move → `{:error, :busy}` (words: `cli.json keeps changing; try again`) → rename; the
  temporary is removed on every path; directory created 0700 → `{:ok, read_all(path)}`. (A narrow race
  between the re-read and the rename remains; two writers of different keys would need to hit it within
  microseconds. The per-key CAS still refuses a same-key overwrite.)
- A write always leaves the file at mode 0600, which repairs a 0644 file; `▸ Make it private` in
  *Files & environment* is a `write_changes(path, %{}, %{})` (a rewrite with no changes).

#### 3.8.2 Who writes cli.json

- **The TUI**: every cli.json write goes through the session runtime's existing preferences task
  (`state.prefs` in `UI/session_runtime.ex`), which U1 turns into a FIFO of ≤ 32 jobs run one at a time
  in `Task.async` owned by the runtime (a 33rd job answers `{:error, :busy}`). Jobs: the legacy
  `{:save_preferences, map}` — now sending **only the changed key** with `expected` = the value the TUI
  last read for it (so `/diff` can no longer undo an external `swarmcode config set terminal.theme
  light`; a conflict there keeps the file's value and toasts `cli.json changed elsewhere; /settings shows
  it`) — and the new effect `{:settings_cli_write, generation, ref, changes, expected}` (→
  `write_changes/3`, answered as `{:settings_cli_result, generation, ref, result}`).
  `{:settings_cli_read, generation}` runs `read_all/1` in the same queue → `{:settings_cli_snapshot,
  generation, snapshot}`; `{:settings_cli_write_text, generation, ref, text, fingerprint}` runs
  `write_text/3` for the external-edit return. `Effect.validate/1` accepts them when `changes` is a map
  of ≤ 64 string keys, `expected` likewise, `text` ≤ 65 536 bytes, `generation` a non-negative integer
  and `ref` a reference or a positive integer.
- **`swarmcode config`** (S1) calls `CliFile.write_changes/3` directly (no runtime).
- Without a preferences path (tests, fake demos) the effects answer `{:error, :unavailable}` and the
  terminal rows say `This session does not keep terminal preferences (no cli.json).`

#### 3.8.3 Layering of terminal values (U1 `UI/settings/provenance.ex`, U3 launch facts)

`Provenance.cli_value(entry, cli_snapshot, launch_facts, values)` builds a SettingValue for a `:cli`
entry: layers in registry order; `flag`/`env` layers are present when `launch_facts.env_overrides`
names the entry (`%{"terminal.theme" => %{var: "SWARM_THEME", value: "dark"}}`, from U3's
`TerminalPreferences.launch/4`); the `cli` layer when the json name is in `values`; the `global`
layer for `terminal.theme` only (the desktop's `desktop.mode`, from the `values` of section
`desktop`); `default` from the entry. `effective` = the strongest present layer; `base` (the CAS
expectation) = the cli layer's value or `:absent`.

#### 3.8.4 Launch (S1 wires, U3 computes)

`SwarmCodeCLI.Release.TerminalPreferences` (U3, `REL/terminal_preferences.ex`):

```elixir
@spec launch(env :: map(), cli :: SwarmCode.Settings.CliFile.snapshot(), desktop_mode :: String.t() | nil, flags :: map()) ::
        %{theme: :dark | :light, theme_env: :dark | :light | nil, mouse?: boolean(), keymap: :default | :vim,
          color_mode: :truecolor | :ansi256 | :ansi16 | :monochrome, ascii?: boolean(),
          glyph_tier: atom(), ambiguous_width: :narrow | :wide, reduced_motion?: boolean(),
          accent: nil | {r, g, b}, companion?: boolean(), startup_conversation: :latest | :new | :ask,
          prefs: %{String.t() => term()},              # the cli values the reducer seeds state.prefs with
          env_overrides: %{String.t() => %{var: String.t(), value: String.t()}},
          flag_overrides: %{String.t() => %{flag: String.t(), value: String.t()}}}
```

Rules (each an env/flag layer of §2.14–§2.17): theme `SWARM_THEME` > cli `theme` > desktop mode >
dark (today's `start_preferences/3`); colours `NO_COLOR` present and non-empty → `:monochrome` (D21),
else cli `colors` when not `auto`, else the `COLORTERM`/`TERM` probe (today's `color_mode/0`); glyphs
`SWARM_ASCII` in `1 true yes` → ascii, else cli `glyphs` when not `auto`, else
`Capabilities.glyph_tier/4`; `SWARM_MOUSE` > cli `mouse` > on; `SWARM_KEYMAP=vim` > cli `keymap` >
standard (any other `SWARM_KEYMAP` value is an ignored layer, D40); `SWARM_COMPANION=0` > cli
`companion` > on; `SWARM_CONVERSATION` or a conversation flag > cli `startup_conversation` > latest
(`ask` opens the resume picker exactly as `--resume` does). `PersistedSession` (S1) replaces its inline `color_mode/0`,
`ascii?/1`, `start_preferences/3` and `Init.keymap_from_env/0` calls with one `launch/4` call when
`Code.ensure_loaded?(SwarmCodeCLI.Release.TerminalPreferences)`, else keeps today's code; it passes
`CliFile.read_all/1`'s snapshot (S1's own module) and puts the result into `%Init{}` (new `Init` fields, U1:
`prefs`, `launch_facts`, `settings_open`; set with `struct/2` so S1 compiles before U1 adds them) and
`%Capabilities{}` (its existing fields `color_mode`, `ascii?`, `glyph_tier`, `ambiguous_width`,
`reduced_motion?`). The accent is process-wide for the launch: `launch/4` returns it and S1 calls
`SwarmCodeCLI.UI.Theme.put_accent(rgb | nil)` (U3; a `:persistent_term` written once before the port
owner starts; `Theme`'s accent-derived roles — every style that uses `0xFF6A1A` today — read it and
derive their 256/16-colour twins by nearest colour) when `function_exported?/3` says it exists. The exit summary
(`persisted_session.ex:683`) uses the same `NO_COLOR` rule. The launcher script (`rel/overlays/bin/
swarmcode`, S1) resolves `startup_conversation` only when neither a flag nor `SWARM_CONVERSATION` chose,
by leaving `SWARM_CONVERSATION` unset; the release reads cli.json (not the script).

#### 3.8.5 Live consumers (U1 reducer, after a successful write)

| json name | state change | effect |
|---|---|---|
| `theme` | `theme_mode` (follow = `desktop.mode` value, else dark); `theme_env` untouched | `{:terminal_preferences, %{theme: mode}}` (skipped when `theme_env` is set; the toast names it) |
| `panel` | `panel_mode` (the `/panel` path) | — |
| `show_diffs` | `show_diffs` | — |
| `mouse` | `mouse?` | `{:terminal_preferences, %{mouse?: on?}}` (skipped when `SWARM_MOUSE` is set) |
| `keymap` | `keymap` (`:default`/`:vim`); leaving vim resets `vim` to its initial map (skipped when `SWARM_KEYMAP` is set) | — |
| `composer_rows` | `composer_height` (clamped by the layout as Ctrl-↑/↓ is) | — |
| `inspector_width` | `preferences.inspector_width` = 38 / 46 / 56 (`Layout.Preferences.preset/3`) | — |
| `notice_seconds` | `prefs["notice_seconds"]`; `State.notice_ms/1` (new, reads it; `notice_ms/0` stays = 6 000 for callers without a state) | — |
| `wheel_lines` | `prefs["wheel_lines"]`, read by the wheel handlers (today 3) | — |
| `editor` | `prefs["editor"]`, read by the runtime's external edit (`terminal.editor` > `VISUAL` > `EDITOR` > `vi`) | — |
| `hint_letters` | `prefs["hint_letters"]`; `Hint.letters/1` (new, U1) reads it; `Hint.letters/0` stays the default | — |
| `keys` | `key_overrides = Keymap.Overrides.compile(value)` (U3); every printed hint and the help sheet follow | — |
| `diff_lines` | `prefs["diff_lines"]`, read by the transcript's diff preview (`@diff_preview` today, U3) | — |
| `colors` `glyphs` `ambiguous_width` `reduced_motion` `accent` `startup_conversation` `companion` | none (next launch) | toast `… · applies at the next launch` |

The legacy `/theme`, `/panel`, `/diff`, `/mouse` commands and the palette's "Vim mode" toggle keep
working and now also update `state.prefs`, so an open settings layer shows their change.

**The terminal follows the desktop mode live (D18, C21).** On an accepted `desktop.mode` write from the
layer, or a `settings_update` touching `desktop` after which the re-queried `desktop.mode` differs from
`state.theme_mode`, when cli `theme` is absent (follow) and `theme_env` is nil, the reducer sets
`theme_mode` and emits `{:terminal_preferences, %{theme: mode}}`, toast `Mode → light · the terminal
follows it`.

### 3.9 Key bindings (U1 contexts and bindings; U3 overrides)

#### 3.9.1 Contexts

`Bindings.@contexts` gains `:settings` (browsing the rail or a page), `:settings_search` (the search
row or the `:` line — typing), `:settings_edit` (an open text-like editor — typing),
`:settings_paste` (the paste target), `:settings_capture` (the key-capture editor: every key is
data), `:settings_picker` (a picker popover: its filter types), `:settings_popover` (a confirmation,
help or pending-on-leave popover: letters are the buttons' letters, never typing). `@typing_contexts`
gains `:settings_search`, `:settings_edit`, `:settings_picker`. `:global`
bindings do **not** expand into the seven settings contexts (the layer has its own grammar; the
table-building reducer skips them), except `Ctrl-C` twice (quit) which stays reachable through the
settings `Ctrl-C` rule (§4.3).

`Context.of/1`: `hint` → `layers` (the palette and other shell layers) → **`settings`**
(`SwarmCodeCLI.UI.Settings.context(layer)` → one of the seven by `mode`/`popover`) → `overlay` →
focus. `Reducer.auto_open?/2` holds approvals and questions back while `settings` is set (as it does
for the overlay); the layer's header shows them.

#### 3.9.2 Bindings (U1, `bindings.ex` table, group `:settings`)

New binding ids (all `contexts` among the seven above, each with `label`, `help`, `hint` weight):
`settings_open` (F2 in `:main`, `:composer`, `:inspector`, `:composer_normal`) · `settings_close` (Esc,
`q`) · `settings_up`/`_down` (↑ ↓, `k`/`j` when `terminal.keymap` is vim) · `settings_page_up`/`_down`
· `settings_first`/`_last` (Home/End, `g g`/`G` in vim) · `settings_left`/`_right` (← → region/edit;
one `step` on a number) · `settings_big_left`/`_big_right` (Shift-← Shift-→: one `big_step`) ·
`settings_open_row` (Enter) · `settings_toggle` (Space) · `settings_search` (`/`: the in-page filter in
a long list, D37, else the global search) · `settings_command` (`:`) · `settings_prev_section`/
`_next_section` (`[` `]`) · `settings_jump` (Ctrl-F, badges on the rail) · `settings_rail` (Tab /
Shift-Tab cycles rail → page → detail; inside the cleanup wizard it cycles the tabs) · `settings_reset`
(`r`: reset, revert a staged field — everywhere, D8) · `settings_restart` (`R`: MCP *restart now*;
Project file *reload*) · `settings_undo` (`u`, Ctrl-Z) · `settings_redo` (`U`, Ctrl-Y; the terminal
cannot report Ctrl-Shift-Z) · `settings_add` (`a`) · `settings_add_key` (`+`: Key bindings, capture an
additional key) · `settings_delete` (`x`, Delete; on Key bindings: remove the focused key) ·
`settings_remove_all` (`X`: a list's *remove all*, asks; on Key bindings: unbind — every key removed,
asks) · `settings_move_up`/`_down` (`K`/`J`, Shift-↑/↓) · `settings_test` (`t`) ·
`settings_fetch` (`f`) · `settings_open_related` (`o`: an MCP server's output, a file's or path's
folder) · `settings_cancel_task` (`c` on a running row) · `settings_info` (`i`) · `settings_external`
(Ctrl-X) · `settings_save` (Ctrl-S) · `settings_refresh` (Ctrl-R) · `settings_needs_you` (Ctrl-N) ·
`settings_help` (`?`, F1) · `settings_copy` (`y`: copies the key or a path, never a secret) ·
`settings_new` (`n`, Library) · `settings_clear` (`C`, Memory) · `settings_edit_external` (`e`, alias of
Ctrl-X on file rows) · `settings_all_on` (`A`: MCP tools all on; storage sessions pick all shown) ·
`settings_all_off` (`N`, MCP tools) · `settings_alt` (`s`: the focused row's second action — *treat as
secret* on a shown MCP env/header entry, *sort* on the storage sessions table, *save it anyway* on a
refused key replacement) · `settings_goto` (`g` on a search result) ·
`settings_paste_clear` (Ctrl-U in `:settings_paste`) · `settings_paste_commit` (Enter in
`:settings_paste`) · `settings_paste_type` (Ctrl-T in `:settings_paste`: type instead, §3.7.7) ·
`settings_picker_*` (↑ ↓ Enter Esc, typing filters) · `settings_popover_*` (Tab/Shift-Tab, Enter, Esc,
the letters of a confirmation's buttons and of the pending popover's `s`/`d`).
Editors handle their own keys inside `:settings_edit` (Enter, Esc, ←→, Home/End, Ctrl-U, Ctrl-W,
Ctrl-A/E, Backspace, Delete, PgUp/PgDn big step in a number, Ctrl-S, Ctrl-X); those keys are listed
as bindings too so the help sheet and `docs/keybindings.md` document them. Letters that are page
actions are bound only in `:settings` (never in typing contexts). One binding id per key and context:
where a letter means different things on different rows (`A`, `s`, `R`, `x`), it is one binding whose
verb the focused row's section interprets through `act/3` (§4.3), and the footer shows the row's own
words. `mix swarm_code.keymap --write` regenerates `docs/keybindings.md` (a new "Settings" chapter); the
`--check` test must pass.

#### 3.9.3 Overrides (`UI/keymap/overrides.ex`, U3 after `c74-U1-api`)

```elixir
defmodule SwarmCodeCLI.UI.Keymap.Overrides do
  defstruct table: %{}, removed: MapSet.new(), by_id: %{}, errors: []
  @spec compile(%{String.t() => [String.t()]} | nil) :: t()
  @spec lookup(t(), context :: atom(), code :: term(), mods :: [atom()]) :: Binding.t() | :default | :unbound
  @spec keys_for(t(), binding_id :: atom()) :: [{code, mods}] | :default          # [] when unbound
  @spec check(t(), binding_id :: String.t(), [String.t()]) :: :ok | {:error, String.t()}
  @spec bindings_for_key(t(), key_name :: String.t()) :: [{Binding.t(), [context]}]  # reverse lookup (Key bindings `/ctrl-j`)
end
```

- U1 publishes a pass-through version by `c74-U1-api` (`compile/1` → `%Overrides{}`, `lookup/4` →
  `:default`, `keys_for/2` → `:default`, `check/3` → `:ok`, `bindings_for_key/2` → the default table's
  matches) and the call sites: `Keymap.resolve/3` → `Bindings.lookup(context, code, mods,
  state.key_overrides)` (new 4-arity: `:default` → the compiled table, `:unbound` → nil, a binding → it),
  `Bindings.key_in_context/3`, `keys_in_context/3`, `keys_for/2` (overrides first) used by `Hint`, the
  status footer, the dialog projector, the help sheet and the settings footer.
- U3 implements: binding ids are strings in cli.json, looked up in `Overrides`' own compile-time map
  `@ids Map.new(Bindings.all(), &{Atom.to_string(&1.id), &1.id})` (never `String.to_atom/1`); key names
  parsed by `Keymap.KeyName.parse/1` (`Ctrl-L`, `Alt-Enter`, `Shift-Tab`, `F5`, `PageDown`, `x`, `?`,
  `Space`, case rules §4.4) and printed by `KeyName.format/2` (glyph tier aware); an override replaces
  the binding's keys in every context it lists; **`[]` unbinds** a non-fixed binding (its key does
  nothing in those contexts, hints and footers omit it, help prints `unbound`); ≤ 4 keys per binding
  (`4 keys at most`).
- **Fixed** (D19; `"<label>" cannot be remapped` / `"<label>" cannot be unbound`): the bindings whose
  key is Esc, Enter, an arrow key, Ctrl-C, `?`/F1 or Ctrl-S in any context (in settings:
  `settings_close` on Esc, `settings_open_row`, `settings_up/_down/_left/_right`, `settings_help`,
  `settings_save`, the paste/picker/popover Enter/Esc bindings, the editor keys), the approval letters,
  and the in-hint bindings (`hint_again`, `hint_pick`, `hint_run`, `hint_runs_dashboard`, `hint_cancel`,
  `hint_backspace`). Every other binding — including `hint_mode` and the settings page letters (`a x X D J
  K t f o e n c C N A u U y g r R s i + /` and `:`) — is remappable. A key used by a fixed binding in a
  shared context cannot be taken (`<key> is fixed`).
- A key taken by another binding in any shared context → `<key> is taken by "<label>" in <contexts>`
  (the capture editor offers `s swap` → both overrides written in one cli.json write); keys the terminal
  cannot report (`Ctrl-Shift-<letter>`, `Ctrl-Enter`, `Ctrl-Tab` without the enhanced keyboard
  protocol — the CLI never enables it) → `this terminal cannot report <key>`. `compile/1` skips invalid
  entries into `errors` (attention AT14).
- Recovery: a user who remaps themselves out of reach runs `swarmcode config reset terminal.keys` (the
  help sheet and `docs/keybindings.md` say so).

### 3.10 Entry points and launch

#### 3.10.1 In the TUI (U1)

- **Slash:** `/settings [ARG]`, aliases `/config`, `/prefs` (the slash palette lists `/settings` with
  the help `Every setting: models, providers, search, MCP, keys, this terminal`). `Keymap.local_command/1`
  and the slash grammar route `{:settings_open, arg}`; `ARG` is the rest of the line (trimmed, ≤ 200
  bytes). `/settings` while the layer is open closes it. The built-ins shadow custom commands named
  `settings`, `config` or `prefs` (the Library says so, §2.13). In the `--plain` presenter and a `-p`
  one-shot, `/settings` (and its aliases) answers `/settings needs the full-screen terminal; use
  swarmcode config here.`
- **F2** (`settings_open`) opens at the resume point.
- **Palette** (Ctrl-P): the old "Settings" row (`Library.features/0` `:settings`) is replaced by
  "Settings" (opens Overview) and one row per section (`Settings › Providers`) and per scalar
  registry entry (`Settings › Theme  light`), searchable by label, key and synonyms; Enter opens the
  layer at that row. **Ranking:** settings rows rank below every existing palette kind (commands,
  conversations, runs, files keep their order), and per-entry rows appear only after 2 typed characters
  or under the `>settings:` prefix (as the approvals prefix does); the section rows and "Settings" follow
  the normal ranking. The `{:library, :settings}` / `{:feature_form, :settings, _}` layer specs and their
  projector branches are removed (D22).
- **Toasts** about provider failures (`Couldn't reach <provider>…`), missing prices, MCP failures and
  the exit-3 path carry a hint `/settings <section>`.
- **Provider missing (D11):** Enter in the composer while the conversation's effective chat provider
  is not usable does not send; the status reads `No model provider can answer: <name> has no key · F2
  opens Settings › Providers` (or `No model provider is set up yet · F2 opens Settings › Providers`
  when there is none), and the draft is kept. The header chip `no model provider · Providers`
  (`warning`) shows while this holds. The client decides from the workspace metadata's new
  `chat_provider: %{name, usable}` field (S1 projects it and adds it to `DTO.WorkspaceMetadata`, the R5 file) and the service refuses the dispatch
  anyway (§3.3.10).

#### 3.10.2 `swarmcode settings [QUERY]` (S1)

- The launcher script treats a first argument exactly `settings` as the subcommand (a directory named
  `settings` is opened with `swarmcode ./settings` or `swarmcode -- settings`; `--help` says so). The
  same rule and help text apply to `config` (Elixir and many other projects have a `config/` folder:
  `swarmcode ./config` opens it). The
  rest: `[QUERY words…] [--dir DIR]`; flags `--new/--continue/--resume/--model/-p/--plain` are usage
  errors with it (`swarmcode: settings takes a query and --dir only.`). It exports
  `SWARM_SETTINGS_OPEN=<query or "">` and `SWARM_SETTINGS_ONLY=1` and starts the TUI.
- `PersistedSession`: with `SWARM_SETTINGS_ONLY=1`, a missing usable provider is not an exit-3
  refusal; the session opens (latest conversation or a new one, as usual) and `%Init{settings_open:
  query}` makes the reducer open the layer at boot (`{:settings_open, query}` after `:boot`). Every
  other startup refusal (desktop running, schema) stays exit 3 with today's words; a held data lease
  (another swarmcode session) says `A swarmcode session is open (<dir>); change settings there with
  /settings, or close it first.` (exit 3).
- The exit-3 text for a missing provider becomes: `No model provider is set up yet.` / `Run
  'swarmcode settings providers' to add one, or set SWARM_MODEL, SWARM_BASE_URL and SWARM_API_KEY in
  ~/.secrets.`

#### 3.10.3 `swarmcode config` (S1, `REL/config_command.ex`)

Headless, for scripts, dotfiles, SSH and CI; the same registry, validators, text parser, service and
CAS as the TUI — enough to provision a machine without opening the TUI.

```
swarmcode config list [SECTION] [--modified] [--json]
swarmcode config get KEY [--json]
swarmcode config set KEY VALUE [--project DIR] [--conversation ID|latest] [--expect VALUE]
swarmcode config reset KEY [--project DIR] [--conversation ID|latest]
swarmcode config keys [--json]              # every registry key: section, scope, type, default
swarmcode config path                       # cli.json, database, log, project file, MEMORY.md, instructions file
swarmcode config records KIND [--project DIR] [--json]            # providers, search_providers, mcp_servers, pricing_rows, hooks, profiles, memory_files
swarmcode config record get KIND:NAME[.FIELD] [--json]
swarmcode config record set KIND:NAME.FIELD VALUE [--project DIR] [--expect VALUE]
swarmcode config record add provider --preset deepseek [--name N] # presets of §2.3; also: add mcp_server NAME --stdio CMD [ARGS…] | --http URL
swarmcode config record delete KIND:NAME [--yes]                  # without --yes: prints what would go and exits 2
swarmcode config secret KIND:NAME[.SLOT] --stdin [--no-test]      # provider:DeepSeek · search_provider:tavily · mcp_server:github.env.GITHUB_TOKEN
swarmcode config search enable|disable KIND                       # = record set search_provider:KIND.enabled on|off
swarmcode config search order KIND,KIND,…                         # search.move steps to that order
swarmcode config mcp toggle NAME | mcp reconnect NAME
swarmcode config export FILE [--no-terminal] [--no-project] [--include-records] [--mcp-plain-values]
swarmcode config import FILE [--apply]      # without --apply prints the plan
swarmcode config doctor [--json]
```

- `KEY` is a registry key or a synonym (§3.7.12); `VALUE` is parsed by
  `SwarmCode.Settings.TextValue.parse/2` (`on/off/true/false`, numbers with units `30m 90s 2h`,
  `default`/`null`, lists as comma-separated, models `provider/model`, colours `#RRGGBB`). Record fields
  are parsed by the same function against the `RecordKind` field type. Each record verb maps 1:1 to the
  `settings.command` action of §3.4.3 (`record set provider:DeepSeek.base_url …` → `provider.update`
  with `expected` = the field as just read, or `--expect`; `record delete` → `*.delete` with the
  fresh `updated_at`; `mcp toggle` → `mcp.toggle`; `search order` → the `search.move` steps) with the
  same messages.
- **Secrets never come from argv.** `set`/`record set` on a secret key or field prints `Secrets are read
  from stdin so they never reach your shell history: swarmcode config secret <KIND:NAME[.SLOT]> --stdin`
  (exit 2). `config secret … --stdin` reads exactly one line from stdin (≤ 8 192 bytes, then
  `Secrets.check_paste/1`): when stdin is a terminal, the launcher script prints `Paste the key, then
  Enter (not shown): ` to stderr and runs `stty -echo` with `trap 'stty echo' EXIT INT TERM` around the
  release call (the BEAM reads with `IO.gets/2`, no port); piped input (`pass show … | swarmcode config
  secret provider:DeepSeek --stdin`) is read as is. The value goes out in the command's `secrets` like
  the TUI's paste (`test_first: true` when a key is already set; a refused key prints `The new key was
  refused (<words>); the old key is kept. Add --no-test to save it anyway.` and exits 1).
- `list`/`get`/`records` print `key  value  (layer)` columns; `--json` prints `{"key", "value",
  "layer", "default", "section"}` objects (records: their wire fields). Secrets print as `set · ends
  a1b2` / `not set`; MCP env/header secret values as `<secret: set>`.
- Global/session/project keys and records are read and written through `SwarmCode.Daemon.Service.Settings`
  in a foundation-only boot: new `PersistedSession.with_foundation(opts, fun)` (log file, lease, verified
  migrations; no session selection, no provider resolution, no boot recovery, no daemon socket). Session
  keys need `--conversation` (`latest` = the project's latest conversation; none → exit 2 `No
  conversation in this project yet.`); project keys use `--project DIR` (default: the current directory,
  which must be a known project → else exit 2 `This folder is not a SwarmCode project yet.`).
- **Tasks headless.** Actions that are tasks (`export`, `import` preview and apply, `doctor`, `secret`
  with a test, `mcp reconnect`) run `TaskSpec.run` in a supervised `Task.async_nolink` child with the
  spec's timeout and stop rules and an in-process results map (§3.3.8 rule 10); `import FILE --apply`
  runs the preview and the apply in one process. `mcp reconnect` subscribes before reconnecting as in
  the TUI.
- **When the database is not available.** `cli` keys use `CliFile.write_changes/3` and need no boot
  (they work while the desktop app or a swarmcode session runs). DB keys and records:
  - the desktop app running → exit 3 with the standard sentence;
  - another swarmcode session holds the data lease (`:data_lease_held`) → exit 3 with `A swarmcode
    session is open (<dir>); change it there with /settings, or close it first.`; `list` and `get`
    still print the cli keys and mark database keys `(unavailable while a session is open)` (exit 0).
- `--expect VALUE` becomes the CAS expectation (else `$any`); a conflict exits 4 with `KEY changed:
  now VALUE.`
- Exit codes: 0 done (also "unchanged"), 2 usage or invalid value (`swarmcode: <key>: <message>`),
  3 startup refused, 4 conflict, 1 anything else. Output never contains a secret; `config` never writes
  the log at debug level with values.

#### 3.10.4 The mix task (S1)

`mix swarm_code.settings --check` fails when the registry and `docs/settings.md` differ; `--write`
regenerates `docs/settings.md` (one table per section: key, label, scope, type, default, applies,
env/flag override). The precommit alias does not run it; a test does.

### 3.11 Secrets, end to end (every owner checks their part)

1. Entry only by paste (§3.7.7), typing where the terminal cannot mark pastes or after `Ctrl-T type
   instead` (never echoed), or `swarmcode config secret … --stdin` (§3.10.3).
2. The value travels in `settings.command` `secrets` (never `attributes`), once per write attempt (a
   refused key replacement sends it a second time only when the user presses `s save it anyway`); the
   client decoder and `Codec` refuse a frame that has a `secrets` key anywhere else (S1).
3. `PersistedBackend` never ledgers a command with non-empty `secrets` (`durable: false`, no
   fingerprint of the secret; the ledger fingerprint uses `%{slot => "<secret>"}`), never keeps it in its
   state after the handler returns (a `test_first` task holds it in its own closure until it ends), and
   crash reports cannot contain it: `Settings.Command`, `ServiceRequest` and the client `Request` have
   custom `Inspect` implementations that print `secrets: [<N redacted>]`; `Connection` stores requests
   without the `secrets` body key; `format_status/1` of `Connection`, `PersistedBackend`,
   `DataSource.Daemon` (S1), `SessionRuntime` and the terminal port owner (U1) redacts `:message` and
   `:log` too (§3.3.10); `Context` has no whole environment and derives `Inspect, except: [:env,
   :task_results]`. A canary test makes a handler raise while handling a `settings.command` with the
   canary in `secrets` and asserts the captured log (`capture_log`) has no canary (S1).
4. Handlers write it with the desktop changeset (`Provider.changeset/2`, `SearchProvider`,
   `Server.changeset/2` for env/headers) and answer `{set: true, hint}` only (S2).
5. Every read path (`values`, `records`, `record`, `task`, `export`, `doctor`, overview, toasts, deltas)
   uses `Settings.Secrets.mask/1`; `mcp_servers.env`/`headers` values are masked by
   `SecretPattern.secret_kv?/2` — the desktop rule plus the CLI's broader name, token-prefix and
   `://user:password@` rules (D6) — and the client re-checks the same function on decode (§3.4.6 rule 3)
   (S1, S2).
6. Logs: the daemon's settings service never logs attributes; `Logger` metadata carries action and
   key only. The client never logs rows or editor state. Task messages are redacted with the target's
   secrets, including ones under 8 bytes (§3.3.8 rule 6).
7. The settings struct broadcast (R19): the backend's settings subscription matches
   `{:settings_updated, _}` and reduces it to a `settings_update` without values (S1); no delta or DTO
   carries the Tavily legacy key or any secret column.
8. Export excludes secrets (MCP env/header values only with *include plain MCP values*, and never the
   secret ones); import never carries them (`secret: true` fields in a file are refused with `the file
   contains a secret for <field>; secrets are pasted, not imported`); the MCP import's secret values
   live only in the task cache with a purge timer (§3.3.8 rule 7a).
9. Search, undo, changelog, the scene, the companion mirror (it mirrors the scene) and `Inspect` of
   `State`, `Layer`, `Paste`, `Draft` never contain the bytes (U1 tests with a canary value
   `sk-canary-7Q2X-DO-NOT-SHOW`).

### 3.12 Ownership, bounds and performance

- **Owned work only.** Daemon: settings tasks are `Task.Supervisor.async_nolink` children of the
  domain task supervisor, monitored by the backend, with a deadline timer and an explicit stop per kind
  (§3.3.8 rule 8); the backend's `terminate/2` stops them. Client: cli.json IO, external edits, copy and
  open-folder run in the session runtime's owned tasks; the reducer is pure. No `Task.start/1`.
- **No IO in state owners.** Settings queries and commands run as PersistedBackend jobs in their own
  pool of 4 (§3.3.10); filesystem work (MEMORY.md, the instructions file, commands, skills, workflows,
  project file, LSP `which`) runs in jobs or tasks, never in the GenServer callback.
- **No call into the backend from inside a transaction.** No code running inside `Repo.transaction`
  (service handlers, tasks) makes a `GenServer.call` to the backend. The c74 daemon test fixtures use a
  Repo `pool_size: 3` (the pass-73 fixtures use 1) so a job, a task and the backend's ledger writes can
  hold connections at once.
- **The bounds, stated once (D39)** — every other section refers here:

| Thing | Bound | On overflow |
|---|---|---|
| models per provider (stored, fetched, applied) | 2 000 | a longer fetch: `N models listed; only the first 2 000 can be kept`, `replace` refused, `add new` fills up to 2 000 |
| MCP tools per server (record view, `mcp.set_tools`) | 512 | the checklist says `showing 512 of N tools` |
| `values.patch` changes / `values.reset` keys | 256 (≥ `length(Registry.scalar_keys())`, compile-time assert) | `invalid`/`too many changes (256 max)` |
| `settings_result.results` | 256 (values actions) / 64 (others) | never reached by construction |
| `settings_result` encoded | < 120 KiB (the ledger guard) | status kept, rows dropped, `The answer was too large to keep; reloading.` |
| `settings_task` delta | summary ≤ 16 KiB, message ≤ 2 048 bytes | summary dropped |
| task progress | ≤ 4 deltas per second per task (≥ 250 ms apart); running deltas replace each other in the watch queue | — |
| `settings_update` coalescing | 100 ms per session | — |
| running tasks | 8 per session | `busy` |
| settings jobs | 4 per session (beside the job cap of 8) | query: capacity error; command: `busy` before the ledger |
| task cache | 64 entries, 4 MiB, LRU; secrets-bearing entries 10 min | evicted → `view=task` answers `that result is gone; run it again` |
| storage sessions store | 20 000 rows, 6 MiB | the largest kept, `showing the 20 000 largest sessions` |
| query page / task rows page | 200 | cursor |
| response encoded | 900 000 bytes (frame limit 1 MiB) | a file above it: `too large to show here (N KB) · Ctrl-X opens it in your editor` |
| file through the wire | 262 144 bytes | `too_large`, external editor only |
| in-place editing | 16 384 bytes | `e`/Ctrl-X only |
| attributes lists | 2 048 items | refused locally by `WireBounds` (§3.4.1) |
| search index | 8 000 entries, 2 MiB | oldest-loaded record items dropped, the results page says so |
| cli.json | 65 536 bytes | `is larger than 64 KB`, not read, not written |
| undo / redo / changelog | 100 / 100 / 200 | oldest dropped |
| client caches | §3.7.4 | oldest dropped (re-queried when needed) |

- **Rendering:** only visible rows are projected; the search index is rebuilt on data change, not per
  keystroke (a query over 8 000 entries answers in < 5 ms on the test machine — a bench test asserts
  < 20 ms); the layer adds no timers except the number-step settle, the status expiry, the elapsed
  clock of running tasks (1 s ticks, only while a task row is visible) and none under reduced motion
  beyond those.
- **Memory:** no full historical blob or unbounded list enters the layer; storage breakdown is the
  service's aggregates only; task results enter the layer page by page, only for visible rows.

---

## 4. The TUI

### 4.0 What is normative

`inv-tui-design.md` (T§) and `frames.md` (F1–F16) are the visual and interaction contract **as
amended by this section and by §1–§3**. Normative: T§3 principles S1–S18, T§6 geometry, T§7.1–7.3 and
7.5 navigation, T§8 search, T§9 editors, T§10 provenance (T§10.3 replaced by D17), T§11 apply/undo,
T§12 confirmations (as amended in §4.8), T§13 async words (timeouts from §3.3.8 win), T§14 states (as
amended in §4.10), T§15 colour/glyphs/motion, T§16 narrow rules, T§17 help, T§18 words, T§24 sketches
and the §4.15 sketches for the pages without frames (both normative for layout; the frames fix the
style). Not normative: T§5.16 (Notifications, N3), T§7.4 (replaced by §3.9),
T§19 (replaced by §3.10.3), T§20–21 (replaced by §3.12 and §6), T§22 (resolved in §4.0.1).

#### 4.0.1 Resolutions of T§22

| Q | Resolution |
|---|---|
| 1 project-file effort | D15: shown as `SwarmCode ignores this key`, `x` removes it; `merge_defaults/2` stays unwired. |
| 2 unset vs default | D16. |
| 3 secret storage | D6: the database, as the desktop; words `stored in SwarmCode's database · shared with the desktop app`. |
| 4 CAS | D7: value-based per key/field; `updated_at` for record deletes; sha256 for files. |
| 5 `/approval full` asks? | No (D14 keeps today's behaviour); settings' approvals row asks. |
| 6 reduced motion source | CLI-only `terminal.reduced_motion`; `desktop.reduce_motion` stays desktop-only. |
| 7 show reasoning | Desktop app row (`desktop.show_reasoning`), no effect in the terminal. |
| 8 new CLI preferences | All of §2.14–§2.17 (no notifications, N3). |
| 9 cli.json bound | 64 KB (D20). |
| 10 persist the last page | No; `settings_resume` lives for the session only. |
| 11 MCP import sources | `.mcp.json` (project root and a typed path); Codex TOML not ported (N8). |
| 12 desktop window state | Shown read-only in *Desktop app › window state* (collapsed), `r` resets those that have a reset. |
| 13 `/theme` bare | Keeps its toggle; `/theme` with an unknown argument says `…or /settings theme`. |
| 14 section count | 21 + Overview (D4). |

### 4.1 Frame amendments (apply to every frame that shows the item)

1. **Rail** (F1–F13): group *tools* is `Search & web · Deep research · MCP servers · Language
   servers`; *agents* ends `Project file · Memory & instructions · Library` (the rail label may cut to
   `Memory & instr…` only below 26 cells, §4.11); *this terminal* is `Appearance · Layout & transcript ·
   Keys & input · Session & startup` (no Notifications). The rail marks are computed (`•N` changed-from-default count of the section's
   scalar entries, `!N` its attention items, a plain number = record count for Providers, MCP servers,
   Library).
2. **Search placeholder**: `/ search N settings, providers, servers and keys` where N =
   `length(Registry.scalar_keys())` (the frames' `212` is an example).
3. **Secrets** (F5, F6, F8, F12): `●●●●●●●● set · ends a1b2` (hint only when present), else `set`;
   the storage words are `stored in SwarmCode's database` + `shared with the desktop app` (never
   "Keychain"); F6's detail line `the old key is replaced in the Keychain` → `the old key is replaced`.
   F12's `its API key is removed from the Keychain` → `its API key is deleted with it`.
4. **Times**: fetch/test times read `fetched this session 18:42` / `answered 18:42`; nothing claims a
   time from before this session for fetches or tests (D31). F3/F4 `fetched 2 h ago` → `6 models ·
   not fetched this session` until a fetch runs; `last run 2 h ago` → `not run this session`. Storage
   `last cleanup 12 days ago` stays (a real column).
5. **No `S` write-target key** anywhere (D17); the status row right side always says `writes to
   <layer> · <meaning>` (`writes to this conversation`, `writes to the global default · shared with the
   desktop app`, `writes to cli.json · this machine's terminal`, `writes to ailogic (project)`,
   `writes to .swarm_code/config.json`).
6. **Next-launch rows** (F10: colours, glyphs, accent, ambiguous width, reduced motion; startup rows):
   after a change the row's continuation reads `applies at the next launch` (`info`) until the layer
   closes; the toast says the same.
7. **F2 / search** result counts follow §3.7.11 (`7 of N · 3 sections`).
8. **F7** is two pages now: *Search & web* (engines table, reader, web fetch facts) and *Deep research*
   (tiers, clocks, research model/effort rows); the stepped number and list examples stay on their
   pages as the catalogue places them.
9. **F11** capture: the taken-key message is `<key> is taken by "<label>" in <contexts>` with `s swap ·
   Esc keep` (§3.9.3).
10. **F13** help lists the settings contexts from `Bindings` (generated, §4.12), not the frame's
    hand-typed list.
11. **Header right** in every frame: the needs-you chip `! N needs you ^N` when something waits
    (§3.7.3), then the context (Overview only), then `Esc <where>`.
12. **MCP restart key** (F1, F8): every `r reconnect now` / `r apply and reconnect` reads `R restart now`;
    `r` is reset/revert everywhere (D8). F8's tools checklist footer reads `Space one · A all on · N all
    off · / filter`.
13. **F3 groups**: the frame's `this project's file` and `from the environment` groups become the two
    link rows of §2.2 (`this project's file · 1 key SwarmCode ignores → Project file`, `from the
    environment → Files & environment`); the project-file keys themselves live on *Project file* and the
    variables on *Files & environment*. The four mode toggles of F3 are the one `Mode` row (D35).
14. **F7 tiers**: every research tier's null label is `the sub-agent model` (the frame's Reporter `the
    lead's model` is wrong; desktop: unset falls back to the swarm default).
15. **F5/F6 key replacement**: pasting over a set key shows `◷ checking the new key…` on the key row
    before anything is saved (§3.7.7); F6's `Enter saves` reads `Enter checks and saves`.
16. **Presets** (F5 draft, Providers `a`): the list and order of §2.3 (with llmotions).

### 4.2 Geometry

T§6.1–6.5 exactly, with: size classes by the terminal's current size (`state.size`), re-evaluated on
every resize (focus, scroll and editors kept; a page that loses the detail column shows the drawer).
Numbers at other widths: wide page column = `columns - 26 - 48`; label column 29 cells from the page's
col 3; value column starts at page col 33 when the page is ≥ 84, else at `max(22, page * 2 / 5)`;
the tag is right-aligned to the page's right edge − 1 and never overlaps the value (the value wraps
under itself first; the tag drops to the continuation row when the value needs the whole width).
Standard/narrow drawer: 4 rows (standard) / 3 rows (narrow) above the status row, separated by a
`─` rule. Small (80–89): drill-down (T§6.1 row 4), the header crumb is the only location cue, `i`
opens the detail as a page. Too small: the T§6.1 sentence, centred, Esc closes. Heights below 30 at
standard width use the narrow layout.

### 4.3 Keys by context (what the footer and help show; letters are `Bindings` ids of §3.9.2; every key below is the default and follows the user's overrides)

| Context | Keys |
|---|---|
| `settings` (rail) | ↑↓ move · Enter/→ open the section in the page · `/` search · `:` command · Ctrl-F jump badges on the rail · Tab page · Esc/`q` close · `?` keys |
| `settings` (page, any row) | ↑↓ PgUp PgDn Home End · Enter open/edit/run · Space toggle (toggles, enabled switches, checklist items) · ←→ step an enum or number in place · Shift-←→ big step · `r` reset (on a staged MCP field: revert) · `u` undo · `U`/Ctrl-Y redo · `[` `]` section · Tab detail/rail · `i` detail (drawer sizes) · `y` copy key/path · `/` search (filter in a list of more than 20 rows) · `:` · Ctrl-R refresh · Ctrl-N needs you · Esc back one level · `?` |
| `settings` (record table, list sub-page, checklist) | adds `a` add · `x` delete (`D` on a record page) · `J`/`K` move (ordered tables) · `t` test · `f` fetch (providers) · `o` output (MCP) · `R` restart now (MCP) · `A` all on / `N` all off (MCP tools) · `c` cancel the running task on the row · `/` filter this list (D37) |
| `settings` (Key bindings sub-page) | Enter capture a new key (replaces) · `+` add a key (≤ 4) · `x` remove the focused key · `X` unbind (asks) · `r` reset this binding · `/` filter by words or a key name (`/ctrl-j` lists what Ctrl-J does in every context) · Enter on the `Context: all ▾` row picks a context |
| `settings` (file rows) | adds `e`/Ctrl-X edit in `terminal.editor` · Enter view (≤ 256 KB) · `o` open the folder · `n` new (library) · `C` clear (memory) |
| `settings` (cleanup wizard) | Tab/Shift-Tab the choose tabs · Space pick · `A` pick all shown · `s` sort · `/` filter sessions · Enter review · Esc back one step (ignored while running) |
| `settings_edit` | typing · Enter commit (multi-line: new line; Ctrl-S commit) · Esc cancel · ←→ Home End Ctrl-A Ctrl-E Ctrl-W Ctrl-U · PgUp/PgDn big step (numbers) · Tab complete (keys, paths, models, env names) · Ctrl-X external editor (multi-line) |
| `settings_paste` | Cmd-V (bracketed paste) · Ctrl-T type instead (not shown) · Enter check and save · Ctrl-U clear · Esc drop the paste |
| `settings_capture` | the next key chord is the value · Esc twice within 1.5 s cancels (a single Esc is captured as `Esc`, which is then refused as fixed) · `s` swap after a taken-key message |
| `settings_search` | typing · ↑↓ results · Enter open/edit the result · `g` go to its section (after ↓ moves into results) · Esc clear, then leave · Tab completes a `@filter` or key |
| `settings_picker` | ↑↓ · typing filters · Enter choose · Esc close once |
| `settings_popover` | Tab/Shift-Tab move between buttons (trapped) · Enter press the focused button · the destructive button's letter (`D`, `F`, `R`…) · `s`/`d` in the pending popover · Esc close once |

**Ctrl-C in settings:** in an editor or search it clears the text (then cancels); on a page it
closes the layer (pending check first); a second Ctrl-C within 1.5 s after the layer closed arms the
shell's quit ladder as usual. **Vim keymap:** `j`/`k`/`g g`/`G` also move in `settings` (not in
typing contexts).

**Row letters.** `a x X D J K t f o e n c C A N R r s + Space` in `:settings` resolve to `{:settings,
{:verb, <binding verb>}}`; U1 calls the current section's `act(ctx, row, verb)`; `:default` runs the
generic meaning (reset, delete-with-confirmation, move, …) or, when the row has no such meaning, shows
`<key> does nothing on this row` for 2 s. The footer shows only the letters the focused row lists in
`Row.keys`, with that row's own words (`t test the connection`, `o all of its output`, `R restart
now`).

### 4.4 Key names (`Keymap.KeyName`, U3)

`Ctrl-`, `Alt-`, `Shift-` prefixes in that order, then the key: a lowercase letter (`x`), a shifted
letter written as the capital (`X`, never `Shift-x`), a digit, a symbol (`?`, `[`, `/`), or a named
key: `Enter`, `Esc`, `Tab`, `Backspace`, `Delete`, `Space`, `Up`, `Down`, `Left`, `Right`, `Home`,
`End`, `PageUp`, `PageDown`, `Insert`, `F1`–`F12`. Parsing is case-insensitive for prefixes and named
keys, case-sensitive for letters. Printing uses `↑ ↓ ← →` in rich/measured glyph tiers and `Up Down
Left Right` in ascii; `Ctrl-` stays spelled (never `^`), except the needs-you chip's existing `^N`.
Stored form = the parse form (`"Ctrl-L"`).

### 4.5 Values by type (the row's value column)

| Type | Display |
|---|---|
| toggle | `on` / `off` (`[✓]`/`[ ]` only inside checklists) |
| enum | the choice label; segmented editor draws `‹ auto  read-only  full ›` with the current in `title` |
| int / money / duration | `6`, `$50`, `30 min` (largest whole unit; stored unit in the detail); specials by their label (`no limit`); null → `null_label` (`same as the chat model`) in `text_muted` |
| text | the text, one line, `…` cut only at the value column's end with the whole text in the detail |
| multiline | first line + `(+N lines)`; empty → `empty` (`text_ghost`) |
| list | `a, b, c` up to the width, then `+N more`; empty → `none` |
| key-value | `N entries` + first names; secret values `●●●●●●●●` |
| model | `model · provider name` (`deepseek-v4-pro · DeepSeek`); missing provider → `! the provider was deleted; pick another` (warning) |
| effort | the level's label (`high`), plus `· default` when null resolves to a default |
| color | a `██` swatch in the colour (twins: `[#FF6A1A]`) + `#FF6A1A` |
| keys | `Ctrl-L, F5` (effective) + `· default` or `· changed` |
| secret | §4.1 item 3; `not set` in `text_ghost` |
| path | `~`-abbreviated; `✗ missing` / `✓` check marks from owned checks |
| invalid (D34) | `✗ stored value not understood: <raw, ≤ 40 chars>` (`error`), tag `r resets it` |
| fact | as text, `text_muted` |
| action | `▸ Label` + the last result with its time |

### 4.6 The detail pane

T§6.5 order. Line 2 = `<key> · <stored_name>` (`cli.json "panel"` for cli keys). Facts: `value`,
`default`, `range` (`1–16`), `step`, `unit`, `applies` (the vocabulary of §2.0), `scope` (`this
conversation` / `global · shared with the desktop app` / `ailogic (project)` / `this machine's
terminal` / `.swarm_code/config.json`), `env`/`flag` names. Secrets add `stored` (§4.1.3) and `sent to`
(`https://api.deepseek.com · as a Bearer token` / `as the x-api-key header` / `in the request body`
for Tavily). *where it comes from* lists every layer of the entry strongest first, winner marked `›`
and `✓`. Desktop-only rows add `no effect in the terminal`; scheduler-only rows add `runs only while
the desktop app runs its scheduler`.

### 4.7 Toasts (status row, 4 s, T§11.2)

- Value: `<Label> → <new>` (`Side panel → compact`), plus `· <layer>` when the home layer is not the
  winner (`saved to cli.json · SWARM_THEME=dark still wins`), plus `· applies at the next launch` /
  `· next turn` / `· restarts <server>` by `applies`.
- Reset: `<Label> back to <default>`; section reset: `Reset 7 values in <Section>`.
- Records: `Added DeepSeek`, `Deleted DeepSeek`, `Renamed to …`, `Moved Exa above Brave`.
- Secrets: `DeepSeek API key saved · ends a1b2` / `… saved` / `… removed`.
- Files: `Saved MEMORY.md (42 lines)`.
- Undo/redo: `Undid: Side panel full → compact` / `Redid: …`.
- Failures (`error`, 6 s): `Couldn't save: <reason>`, `Couldn't <verb> <object>: <reason>`.
- Every toast is appended to the changelog; secrets appear as `<Label> replaced · no undo`.

### 4.8 Confirmations (T§12 amended)

| Action | Title · buttons | Body (counts come from the target's `record` view — e.g. provider `used_by`, MCP `tools` — re-read when the dialog opens, 10 s) |
|---|---|---|
| Delete a provider | `Delete DeepSeek?` · `Keep DeepSeek` / `D  Delete DeepSeek` · `not undoable` | defaults it serves (chat, sub-agent, research tiers…) each with a required replacement picker; `N conversations use it · their messages stay; new turns use the replacement`; `N scheduled tasks`; `its API key is deleted with it`; the only provider → `SwarmCode will have no model to talk to until you add one` |
| Delete an MCP server | `Delete github?` · `Keep github` / `D  Delete github` | `Agents lose its N tools; conversations that used them keep their history` |
| Clear a secret | `Remove DeepSeek's API key?` · `Keep it` / `R  Remove the key` | `Requests to api.deepseek.com will be refused until you paste a new key` |
| Approvals → full access | `Give ailogic full access?` · `Keep auto` / `F  Give full access` | `Agents run commands and make edits without asking you.` |
| Trust a project | `Trust ailogic?` · `Not now` / `T  Trust` | `Agents read AGENTS.md, edits are allowed, and the project's hooks start running:` + each hook `event · command` |
| Untrust a project (D13) | `Stop trusting ailogic?` · `Keep trust` / `U  Stop trusting` | `Hooks stop running and approvals go back to read-only.` |
| New or changed hook | `Run this on your machine?` · `Cancel` / `S  Save the hook` | `In ailogic, whenever <event>: <command>`; untrusted → `It will not run until you trust ailogic.` (no confirmation then) |
| Clear memory | `Clear ailogic's memory?` · `Keep it` / `C  Clear` · `not undoable` | `N lines the agents saved.` + `e opens it in your editor instead` |
| Forget all always-allowed commands | `Forget N commands?` · `Keep them` / `F  Forget all` | the list (≤ 12, then `+N more`); undoable |
| Delete a library file (command, agent, skill, workflow) | `Delete /deploy?` · `Keep it` / `D  Delete` · `not undoable` | the path; `shadows the bundled one` when it does |
| Reset a section | `Reset <Section>?` · `Cancel` / `R  Reset N values` | `key · now → default` lines; undoable |
| Reset every key binding | `Reset N key bindings?` · `Cancel` / `R  Reset` | undoable |
| Storage cleanup | the review step; typed `delete` (or `delete N`) then Enter | the desktop's plan words (T§5.18); Esc ignored while running |
| Vacuum | part of the cleanup review | `rewrites the database file; needs N GB free`; refused while runs are live (`runs are live; stop them first`) |
| Import | the difference table with ticks | `Apply N changes` button; records and secrets rules §2.22 |
| Reset everything | typed `reset` | not undoable; lists the counts per layer |
| Provider kind change | `Switch DeepSeek to Anthropic?` · `Cancel` / `S  Switch` | `The effort levels go back to the built-in ones for Anthropic.`; undoable |
| Hooks through an external edit of config.json (D14) | `Run these on your machine?` · `Cancel` / `S  Save the file` | `In ailogic, the file now runs:` + each new or changed `event · command` (from the service's `needs_confirmation`, §3.5.7); Cancel keeps the edited text in the temp copy (`e edit again`) |
| A refused key replacement | not a dialog: the key row reads `The new key was refused (<words>). s save it anyway · Esc keep the old key` (§3.7.7) | — |
| Quit while a non-cancellable task runs (Ctrl-C twice, `/quit`, `q` on the shell) | `A cleanup is running.` (or `An import is running.`) · `Stay` / `Q  Quit anyway` | `Quitting stops it midway: some sessions may be deleted and others not.` / `…some settings may be imported and others not.` |
| Pending on leave | §3.7.10 | — |

Dialog mechanics: T§12 (safe button first and focused, the letter presses the destructive one,
Tab trapped, Esc closes once, background inert, focus back to the opener; counts `counting…` with the
destructive button disabled until they arrive or fail — a failure enables it with `unknown` counts).

### 4.9 Async rows (T§13 with §3.3.8's timeouts)

- A running task row: `◷ <start words> · N s` (`info`; elapsed from the delta's `elapsed_ms` plus the
  local clock since it arrived, whole seconds, 1 s ticks only while visible) and the tag `c stop` when
  cancellable, else `can't be stopped`. Progress: `◷ fetching 2 of 4 providers · 7 s`,
  `◷ deleting 3 of 14 · 12 s` (storage).
- Done: `✓ <success words> · HH:MM` (`success`), kept for the session (the backend's result cache
  feeds `last_test`/`last_fetch`, so a reopened layer shows it). Failed: `✗ <message>` (`error`) with
  the time. Timeout: `✗ no answer in N s`. Cancelled: `stopped · HH:MM` (`text_muted`).
- Words (start → success; failure examples come from the service message):
  `provider.test` `testing the connection` → `listed N models in M ms`; `provider.fetch_models`
  `fetching the model list` → `N models from <host> · M ms` + the difference rows (`+ new`, `− gone
  (N conversations use it)`, `unchanged N`), `a apply all · + add new only · Esc keep`;
  `provider.fetch_all` `fetching K of N providers` → `N providers · K changed lists`; `search.test`
  `searching · uses 1 search from your <provider> plan` → `N results · M ms`; `mcp.test` `starting
  <name> to list its tools` → `connected · N tools`; `mcp.reconnect` `restarting with the new settings`
  → `connected · N tools, K off`; `mcp.import.read` `reading .mcp.json` → `N servers found`;
  `lsp.check` `looking for the servers` → per language `✓ installed` / `✗ not installed: <exe>`;
  `storage.measure` `measuring` → `measured HH:MM`; `storage.plan` `planning the cleanup` → the review;
  `storage.run` `deleting K of N` → `Freed X from N items`; `storage.vacuum` `reclaiming disk space`
  → `Reclaimed X of disk space · the file went from A to B`; `storage.apply_retention` `applying
  retention` → `N sessions deleted, K pruned`; `provider.set_key`/`search.set_key` with `test_first`
  `checking the new key` → `<Name> API key replaced · the new key listed N models` (search: `… answered
  in M ms`); non-cancellable tasks past their reporting deadline add `· still running after N s`; `workflow.smoke` `checking N workflows` → per workflow `✓`/`✗ <reason>`; `export` `writing
  <file>` → `Exported N values to <file>`; `import.preview` `reading <file>` → the difference table;
  `import.apply` `applying N changes` → `Imported N changes`; `doctor` `checking` → `✓ everything
  answers` or the failing lines.
- Automatic runs: after a first key (`provider.set_key` without `test_first`) the test starts by
  itself; opening a provider record whose
  `last_test` is absent does **not** start one (the user presses `t`); the Providers page never
  starts tasks by itself; Language servers starts `lsp.check` when the page opens (5 s, cheap);
  Storage starts `storage.measure` when the page opens if no measure ran this session.

### 4.10 Empty, loading, error, offline (T§14 amended)

T§14 rows apply with: the *Secret store unavailable* row is dropped (no Keychain); cli.json bound
reads `is larger than 64 KB`; add:

| Situation | Where | Words |
|---|---|---|
| Unsaved live session (`LiveBackend`, D28) | every non-terminal section, Overview | `Settings for the database are available in saved sessions only. The terminal sections work here.` |
| `settings` capability not granted | the whole layer (terminal sections still work) | `This SwarmCode service does not offer settings. Update the CLI and the daemon together.` |
| A record deleted while its page is open | the record page | `<name> was deleted (elsewhere in this session).` + Esc back |
| A file changed on disk while shown | the file row | `changed on disk · Ctrl-R reloads` (`warning`) |
| Project not trusted (hooks) | Project file › hooks | `Hooks run only in trusted projects. ailogic is not trusted.` + link to Approvals & trust |
| Desktop app running | never reached (the CLI does not start) | — |
| No usable provider (settings-only launch, or the effective chat provider has no key) | header chip | `no model provider · Providers` (`warning`) until one is usable (D11) |
| A stored value the CLI does not understand (D34) | the row | §4.5 *invalid*; Overview AT18 |
| An `outcome` reply to a settings command (§3.4.2) | status row | `Couldn't tell whether that was saved; reloading.` then the rows re-query |
| An evicted task result | the task row | `that result is gone; run it again` (`text_muted`) |
| `--plain` presenter / `-p` one-shot | the transcript | `/settings needs the full-screen terminal; use swarmcode config here.` |

### 4.11 NO_COLOR, ASCII, narrow

- Every mark has a word or glyph besides colour (T§15.1): `!`, `✗`, `✓`, `•`, `◷`, `not saved`,
  `conflict`. Under `:monochrome` roles map as the CLI's monochrome theme does (bold/underline/
  reverse from `Theme`), focus = reverse video, selection = reverse on the focused row only.
- ASCII tier twins (F15 notes, T§15.2): `▌`→`>`, `•`→`*`, `›`→`>`, `·`→`-`, `✓`→`v`, `✗`→`x`,
  `[✓]`→`[v]`, `●●●●●●●●`→`********`, `◷`→`~`, `←→`→`<- ->`, `↑↓`→`Up Down`, `▸`→`>`, `─│┌┐└┘`→`-|++++`,
  `▰▱`→`#.`, `██` swatch→`[#RRGGBB]`, `…`→`...`. The projector reads `caps.glyph_tier` through
  `SwarmCodeCLI.UI.Settings.Glyphs.get(id, tier)` (U1; a compile-time table with rich/measured/ascii
  twins for every glyph above), so no owner has to edit `Theme` for them.
- Narrow/small: T§16 plus §4.2. Labels are never cut while space remains (R14); table columns drop
  right to left by priority (the section's `columns` priorities); a record's name and its key state
  never drop.

### 4.12 Help (F13)

`?`/F1 over settings opens a popover sheet generated from `Bindings.for_context/1` of the current
settings context plus the focused row's `Row.keys`, grouped: *move*, *change*, *this row*, *search and
commands*, *leave*. It lists the effective keys (overrides applied; unbound ones as `unbound`). The last lines:
`/settings <words> opens straight at a setting · :set <key> <value> · swarmcode config in a shell` and
`Remapped yourself out of a key? swarmcode config reset terminal.keys`. Esc closes.

### 4.13 Words (T§18 plus these exact strings)

- Header: `Settings`, crumbs `Settings › Providers › DeepSeek › Effort levels`, `Esc back to chat` /
  `Esc back to <parent>` / `Esc sections` (small).
- Status right: `writes to …` (§4.1.5), `read-only · <why>` (`set by the desktop's retention sweep`,
  `a fact about this machine`, `SWARM_THEME=dark wins while set`).
- Loading: `…`; saving: `saving…`; stale: `as of 18:42`.
- Disabled: `only when <Label> is <value>` (`only when Wheel scrolling is on`).
- Unknown `/settings` argument that matches nothing: the search page with `Nothing matches “<words>”.`
- Never: `daemon`, `invalid` (except quoting a changeset message), `error occurred`, `Are you sure?`,
  UUIDs, column names in rows (they appear only in the detail's key line), `Keychain`.

### 4.14 Pages (what U2 and U3 build; rows in the order of §2's tables inside each §2 group)

Every framed page has a scene-text test at 160×45 with Appendix A data in its owner's task (§5): F1
U1-16 · F2 U1-12 · F3 U3-4 · F4 U2-2 · F5/F6/F12 U2-4 · F7 U2-7 (Search & web) + U3-5 (Deep research)
· F8 U2-9 · F9 U3-6 · F10 U3-9 · F11 U3-3/U3-10 · F13 U1-13 · F14 U3-7 · F15/F16 U1-15. Every page
sketched in T§24 or §4.15 has a page-column text test at 160×45 in its owner's task (Effort levels U2-5,
Storage review/choose U2-11, Pricing U2-6, MCP import U2-8, Library U2-13, Project file U3-8, Key
bindings U3-10, Import preview U3-13, hint mode and the `:` line U1-12).

| Section | Owner | Page |
|---|---|---|
| Overview | U1 | F1: *needs attention* (≤ 8, `Enter open`), *at a glance* (the service's `glance`), *changed from default* (first 9, then `… N more` → `@modified`), *where values come from* (count per layer + names), *changed in this session* (from `State.settings_history`, newest first, ≤ 6). |
| Models & effort | U3 | F3 (§4.1 item 13); groups §2.2; model rows use U2's `ModelPicker` editor (F4) when loaded; `Mode` is one segmented row (D35); the consensus sub-page (`Enter open`, while the mode is consensus) lists rounds, judge, implementer, checks (`Consensus.checks/0` as a checklist). |
| Providers | U2 | table `name · kind · key · models · last test` (priorities 1,4,2,3,5); `a` add from a preset (the §2.3 list, in its order) → draft page (F5/F6 layout, *Effort levels* `<preset> · from the preset`) `Ctrl-S` creates; record page F5 with `▸ Use <name> · <model> for new chats`; paste F6 (test first when replacing, §3.7.7); effort levels sub-page (`EffortLevels` editor, T§24: rows `key · label · hint · body JSON`, `a x J K`, `Ctrl-S` saves, `Esc` asks when dirty; scope switch `provider · <model>`); models list sub-page (≤ 2 000, `/` filter); `▸ Fetch every provider's models`. |
| Pricing | U2 | sketch §4.15: group *used but unpriced* (AT5 models, `Enter` adds a row prefilled); table `model · in $/M · out $/M · cache read · cache write · context` (priorities 1,2,3,5,6,4); `a` add (draft until both prices valid), `x` delete (undoable), `/` filter. |
| Search & web | U2 | F7 (first page): engines table `name · on · key · order · last test` in `search_providers` order (`J K` move = `search.move`), Space toggles, record page with key paste (test first when replacing), base URL (where the kind has one), `t` test; then `web.reader` (with AT15's note), `web.fetch_facts`. |
| Deep research | U3 | F7 (second page): §2.6 rows (level with measured medians, clocks, `max_live`, tier models via `ModelPicker`, efforts; tier null label `the sub-agent model`). |
| MCP servers | U2 | groups `every project` / `<project> only` (project picker, D12); rows `name · transport · state · tools on/total`; `a` add (draft), `▸ Import from .mcp.json` is an action row (Enter; there is no import letter, `i` is the detail drawer) → the import preview (sketch §4.15: ticks, name conflicts, variables with `v`/`p`/`k`, SSE rows unticked) → apply; record page F8: connection fields staged (D8; `r` reverts one, `R restart now` applies), env/headers `KeyValueSecrets` editor (secret values are paste targets; `s` treat as secret), tools checklist (`Space` one tool, `A` all on, `N` all off, `/` filter), `t` test, `o` output, `D` delete; scope row `every project · <project> only` changes scope explicitly (D23/R7). |
| Language servers | U2 | 13 rows `language · extensions · default · state` with the LspCommand editor; `lsp.check` results per row; unknown `lsp_servers` keys after them with `x remove`; `▸ Stop running language servers` (`lsp.stop`). |
| Agents & limits | U3 | F9; §2.9 groups; agent definitions link rows → Library. |
| Approvals & trust | U3 | F14; project picker row first; approvals (escalation confirm), trust/untrust, always-allowed families (`x` forget one, undoable; `▸ Forget all…`), *other projects* group collapsed. |
| Project file | U3 | sketch §4.15: header path + parse state; top-level keys (§2.11), hooks table `event · matcher · command · timeout` (`a x J K`, confirm per D14), profiles table `name · model · effort · sub-agent effort`; *ignored entries* rows with `x remove`; ignored keys with `x remove` (D15); `e` edits the file externally (fingerprint CAS, hook confirmation). |
| Memory & instructions | U2 | three file rows (project memory, global memory, project instructions — §2.12): lines · size · `Enter` edit (≤ 16 KB) · `e` external · `C` clear (memories only, asks) · `o` folder; the instructions row adds its loading facts and the trust warning. |
| Library | U2 | sketch §4.15: four groups (§2.13) with the keys listed there; `t` smoke on workflows; `/` filter in a group over 20. |
| Appearance | U3 | F10 incl. the live preview block (a 6-row sample of transcript roles in the chosen theme and accent: the preview is drawn with the *candidate* palette while the editor is open, and the real palette changes only after commit); contrast line `4.9:1 on the page ✓` / `3.1:1 · hard to read` (`warning`). |
| Layout & transcript | U3 | §2.15 rows (incl. `Diff lines shown`). |
| Keys & input | U3 | F11; §2.16 rows; the Key bindings sub-page (sketch §4.15) lists every binding grouped by `Bindings.groups/0`: `label · keys · contexts`, a `Context: all ▾` picker row, `/` filter by words or key name, `Enter` capture (replace), `+` add a key, `x` remove a key, `X` unbind, `r` reset one, `▸ Reset every key binding…`; fixed bindings listed faint with `fixed`. |
| Session & startup | U3 | §2.17 rows (`On launch` with `ask`). |
| Storage | U2 | §2.18: the page text, retention rows with their quick picks, `storage.last_sweep`, the measured overview (bar + legend + the desktop line), `▸ Clean up…` (the three-tab wizard of §2.18, sketches T§24 *Review* and §4.15 *Choose*), `▸ Reclaim disk space (VACUUM)`, `▸ Apply retention now`. One label for VACUUM everywhere: `Reclaim disk space (VACUUM)`. |
| Budget & usage | U3 | §2.19; this month's spend gauge and `by model` table `model · in · out · cost` (`no price` when unpriced). |
| Desktop app | U3 | §2.20; *window state* collapsed. |
| Files & environment | U3 | §2.21 facts with checks and actions; the env list (§2.25 List B) with secrets masked. |
| Import & export | U3 | §2.22 actions; export dialog (path + scope toggles incl. *include plain MCP values*), import preview table (sketch §4.15) `key · now · after · ✓` with ticks, `Apply N changes`. |

### 4.15 Sketches of the unframed pages (normative for layout, T§24 style)

Page-column width, Appendix A data; roles as in the frames (focus `▌`, `warning` for `unsaved`/`!`,
`error` for `✗`, `text_muted` for facts).

**Pricing**:

```
 Pricing · $ per million tokens                                             / filter · a add
 used but unpriced                                                                 2 models
 ! claude-sonnet-5        used by 14 conversations · a default       Enter adds a row
 ! qwen3-coder            used by 3 conversations                    Enter adds a row
   model                  in $/M   out $/M   cache read   cache write    context
▌  claude-opus-5          15.00    75.00     1.50 ·       18.75 ·        200 000 ·
   deepseek-v4-flash      0.07     0.28      0.007 ·      0.09 ·         family default
   deepseek-v4-pro        0.27     1.10      0.027 ·      0.34 ·         family default
   · = derived from the input price (read × 0.1, write × 1.25)
 Enter edit the cell   a add   x delete   / filter   u undo                     writes to the global default
```

**Project file** (ailogic):

```
 Project file · ~/dev/ailogic/.swarm_code/config.json · ✓ read                 e edit the whole file
 keys SwarmCode ignores
   effort                 high · SwarmCode ignores this key                        x remove
 hooks · run only in trusted projects · ailogic is trusted
   event            matcher          command                          timeout
▌  post_tool_use    ^edit_file$      mix format                       10 s
 ignored entries
   ✗ hooks.post_edit · unknown event post_edit                                     x remove
   ! profiles.fast.mode · not a profile key                                        x remove
 profiles
   name     model                  effort    sub-agent effort
   fast     —                      low       —
 a add a hook   Enter edit   x delete   J K order   Ctrl-R reload        writes to .swarm_code/config.json
```

**Library**:

```
 Library · ailogic                                                    n new · / filter
 commands
▌  /deploy     project   build   Deploy the app to staging
   /review     global            Review the staged diff
 agent definitions
   reviewer    project   the sub-agent model · medium        shadows the bundled one
   reviewer    bundled   the sub-agent model                 shadowed
   scout       user      claude-opus-5 · high
 skills
   html-report project   Build a report page · 3 files
 workflows
   nightly     user      ✓ smoke ok
   broken      project   ✗ calls System.os_time/0                               t check again
 Enter open in hx   n new   x delete   o folder   y copy path   t smoke
```

**Storage › Clean up · choose** (Sessions tab; Quick and Advanced share the tab row):

```
 Storage › Clean up        [ Quick ]  [ Sessions ]  [ Advanced ]              Tab next tab · Esc back
 / Filter by title or project…                        sort: size ▾   3 picked · 612 MB
   title                              project    updated        size
▌  [✓] Refactor the parser (old)      ailogic    142 days ago   402 MB
   [✓] Try the new router             notes      98 days ago    180 MB
   [ ] Refactor the parser            ailogic    today          88 MB    locked · open in this terminal
   [✓] pinned: Release checklist      ailogic    61 days ago    30 MB    pinned — picked by you
   … 210 more · PgDn
 Space pick   A pick all shown   s sort   / filter   Enter review 3 sessions
```

**Keys & input › Key bindings**:

```
 Keys & input › Key bindings        Context: all ▾      / filter or a key (/ctrl-j)     ▸ Reset every key binding…
 palette
▌  Open the palette            Ctrl-P                   main, composer, inspector        · default
   Open settings               F2                       main, composer, inspector        · default
 transcript
   Toggle diffs                Ctrl-D, F6               main                             · changed
   Jump to hints               Ctrl-F                   main, composer                   · default
   Old focus binding           unbound                  main                             · changed
 approvals
   Allow once                  y                        approval                         fixed
 Enter capture   + add a key   x remove key   X unbind   r reset   / filter
```

**Import & export › Import preview**:

```
 Import · ~/swarmcode-settings-2026-09-20.json · 71 values, 3 providers, 1 MCP server     / filter
   ✓   key or record                     now                 after
▌  [✓] limits.max_concurrent_agents     6                   8
   [✓] terminal.panel                   compact             full
   [ ] web.reader                       web_fetch           jina
   [✓] provider DeepSeek                (exists)            base URL changes · paste the key after import
   [✓] mcp_server github                (exists)            2 env · 1 secret value kept
       research.max_live                12                  12              same
     ✗ desktop.theme                    carbon              nord            is invalid · not applied
 Space tick   A tick all   Enter apply 5 changes   Esc back          scalars are one undo step
```

**MCP servers › Import from .mcp.json**:

```
 Import MCP servers · ~/dev/ailogic/.mcp.json · 3 servers                        Esc back
▌  [✓] github        stdio   npx -y @modelcontextprotocol/server-github   1 env
         GITHUB_TOKEN = ${GITHUB_TOKEN} · SwarmCode does not expand variables
         v take it from this shell now (set)   p paste a value   k keep it literally
   [✓] docs          http    https://mcp.example.test/mcp                 1 header · masked
   [ ] events        sse     https://events.example.test/sse
         SSE servers are not supported; use the server's streamable http URL
   a server named github exists · n import as github-2 · x skip
 Space tick   v p k choose for the focused variable   Enter import 2 servers   scope: every project ▾
```

---

## 5. Owners, files and tasks

### 5.0 Rules for every owner

- **Repo:** `/Users/zaali/dev/swarm-code-cli` at `main` = `fb99d0f`. Read its `AGENTS.md` first (Commands,
  Test gotchas, Provenance, TUI facts). Never edit `DOM/` (synced desktop domain) or anything in
  `provenance/`; never add a dependency; never add a migration; never open the real database
  (`~/Library/Application Support/SwarmCode`); no network or LLM calls (loopback test servers only:
  `DMNT/../support/loopback_http.ex`).
- **Worktrees and branches exist** (all at `fb99d0f`): `/Users/zaali/dev/swarm-code-cli-wt/c74-{S1,S2,U1,U2,U3,F}`
  on `c74/S1 c74/S2 c74/U1 c74/U2 c74/U3 c74/integrate`. Check `deps` and `priv/native` are symlinked;
  if a worktree is missing, create it exactly so:

```sh
cd /Users/zaali/dev/swarm-code-cli
git worktree add -b c74/<X> /Users/zaali/dev/swarm-code-cli-wt/c74-<X> fb99d0f
ln -s /Users/zaali/dev/swarm-code-cli/deps /Users/zaali/dev/swarm-code-cli-wt/c74-<X>/deps
ln -s /Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/priv/native \
      /Users/zaali/dev/swarm-code-cli-wt/c74-<X>/apps/swarm_code_daemon/priv/native
```

  An owner whose start is a tag begins with `git merge --ff-only <tag>` in its worktree (the branch
  is still at `fb99d0f`, so it fast-forwards); a later tag is merged with `git merge --no-ff <tag>`.

| Owner | Branch | Starts when | Merges |
|---|---|---|---|
| S1 | `c74/S1` | at once | — |
| U1 | `c74/U1` | at once (U1-1..U1-2 need nothing from S1) | `c74-S1-wire` before U1-3 |
| S2 | `c74/S2` | when `c74-S1-core` exists | `c74-S1-core` first; `c74-S1-wire` optionally (S2 needs nothing from it) |
| U2 | `c74/U2` | when `c74-U1-api` exists (it contains `c74-S1-wire`) | `c74-U1-api` first; `c74-U1-api-2` when it exists |
| U3 | `c74/U3` | when `c74-U1-api` exists | `c74-U1-api` first; `c74-U1-api-2` when it exists |
| F | `c74/integrate` | when all five report done | every branch (F-1) |

- **Interface tags** (`git tag <name>` on the owner's branch; later changes to tagged interfaces are
  additive only — new optional fields/callbacks — and announced in the owner's notes file):
  - **`c74-S1-core`** (S1, after S1-4): the core types, the registry with every entry of §2 (values may
    be refined later; keys and types frozen), `terminal.ex` and `records.ex` complete as S1 knows them,
    `WireBounds`, `CliFile`, `SecretPattern`, `TextValue`; the daemon structs (`Context`, `Command`,
    `Result`, `Error`, `TaskSpec`), `Handler` (incl. `cache_reads/1`), `Router`, `Wire`, `Layers`, `Cas`,
    `TaskCache` (pure). S2 starts here.
  - **`c74-S1-wire`** (S1, after S1-6): + the protocol ops and capability, client `Request`/`Codec`/DTOs
    (incl. the `outcome` mapping), the `Effect.validate` clause, `EffectRunner`, `Fake` + `Fake.Settings`
    (values/overview/facts/usage/open/task/projects views, `values.*`/`profile.apply`/`task.cancel`,
    the data-driven record store, the generic task lifecycle, `stub_reply/3`, dispatch to
    `Fake.SettingsIntegrations` when loaded) seeded with Appendix A.
  - **`c74-U1-api`** (U1, after U1-7, having merged `c74-S1-wire`): `Section`/`Row`/`Op`/`Ctx`/`Detail`/
    `Attention`/`Editor`, `Rows.scalar/2`, the `use Section` defaults, `Sections.module_for/1`, `Glyphs`,
    the pass-through `Keymap.Overrides` and `KeyName`, the new `State`/`Init` fields, the `Preferences`
    wrapper, the reducer's open/close/data/commit paths, the minimal Toggle/Enum/Number/Text editors and
    a **text-only page projector** (`UI/projector/settings/text_page.ex`: the page as `label · value ·
    tag` lines, no geometry) — a layer that opens, shows every section's registry rows through the
    defaults and commits scalar values against `Fake.Settings`. U2 and U3 start here; **until they merge
    `c74-U1-api-2`, their section tests assert rows and requests only, not scene text.**
  - **`c74-U1-api-2`** (U1, after U1-15): the full projector (§4.2 geometry, tables, drawer, NO_COLOR/ASCII),
    every generic editor, popovers and task rows. U2/U3 merge it and add their scene-text tests (§4.14).
- **Nobody merges an untagged branch.** An owner who needs an additive change from upstream asks in its
  notes file; the upstream owner cuts `<tag>-2`/`-3` when it lands.
- **Files.** Only the files of your row in §3.1 (and your test files). A file you need changed that
  another owner owns → a note in `/Users/zaali/.cache/c74/notes/<you>.md`: `## <file>` + the exact change
  (a diff or the new function) + why. The finisher applies notes. Tests: your own new files only, named
  `<area>/c74_<topic>_test.exs` (e.g. `CLIT/ui/settings/c74_search_test.exs`,
  `DMNT/daemon/service/settings/c74_providers_test.exs`); shared test support you add is
  `CLIT/support/c74_<owner>_*.ex` or `DMNT/../support/c74_<owner>_*.ex`. c74 daemon fixtures use a
  fixture Repo with `pool_size: 3` (§3.12). Existing tests you must update because your change alters
  their expectation (e.g. the capability count, `Library.features/0`) are yours only when the file under
  test is yours; otherwise note it.
- **Compile alone.** Every branch compiles with `--warnings-as-errors` and passes its tests on its own
  (`@compile {:no_warn_undefined, [...]}` + `Code.ensure_loaded?/1` fallbacks for other owners'
  modules; `struct/2` for fields other owners add).
- **Commits:** small, one task or less each, message `pass74 <task id>: <what changed, in words>` (e.g.
  `pass74 S1-7: values.patch writes with compare-and-set in the write's transaction`), with the
  attribution lines the orchestrator gives. Never amend or rebase a pushed tag.
- **Gate per task:** `mise exec -- mix format`, `mise exec -- mix compile --warnings-as-errors`, the
  focused tests you touched (`mise exec -- mix test <files>` from the umbrella root). **Gate at the end:**
  `mise exec -- mix precommit` in your worktree; the only accepted failure is
  `ui/renderer/locked_branch_test.exs` (it fails in any worktree whose `deps` is a symlink — AGENTS.md).
  If you touched `Bindings`: `(cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap --write)`.
- **Report** (StructuredOutput to the orchestrator): branch head, tag(s), task ids done/partial with
  reasons, test counts, the notes file path, deviations from this spec with the reason (never silent).
- **Output hygiene:** read with offset/limit and grep; keep tool output small; no report `.md` files
  besides the notes file.

### 5.1 S1 — registry, wire, service frame, backend, launcher (17 tasks)

| # | Task | Files | Done when (tests) |
|---|---|---|---|
| S1-1 | Core types: `Entry`, `RecordKind` (`%{kind, table, fields: [%{name, type, secret?, required?, max, validate, messages}], id_field, order}`), `Sections` (22 sections, groups, synonyms), `WireValue` (`type_ok?/2`, `normalize/2` incl. the integral-float rule, `from_json/2`, `to_json/2`), `TextValue.parse/2` + `format/2` (§3.10.3 grammar incl. record fields), `Validate.check/2` (§3.2.4), `SecretPattern` (§3.2.5: the desktop rule copied by value + the broader rules), `WireBounds.valid?/2` (§3.4.1). | `CORE/settings/*.ex` | `CORET/settings/c74_types_test.exs`: every type's round trip; every validator's exact message; `TextValue` table of 40 inputs → values/errors; `SecretPattern`: the 40-row table of §3.5.4 (superset of the desktop rule + `GH_PAT`, `STRIPE_KEY=sk_live_…`, `DATABASE_URL=postgres://u:pw@h/db`); `WireBounds` just inside/just outside every bound. |
| S1-2 | Registry entries part 1: §2.2 models & effort (one `session.mode`, D35), §2.5 web, §2.6 research, §2.9 limits, §2.10 approvals/session/project (`registry/{models,research,web,limits,session,project}.ex`); `big_step` on every numeric entry over 50 steps. | `CORE/settings/registry/*.ex` | compile-time checks (§3.2.6) pass; `c74_registry_test.exs` asserts the key list of these sections equals §2 exactly (a literal list in the test). |
| S1-3 | Registry part 2: §2.8 lsp, §2.11 project file, §2.18 storage, §2.19 budget, §2.20 desktop (all 79 settings-row fields accounted for: §2.26), §2.21 facts, §2.22 actions, §2.14–§2.17 `terminal.ex` (hand-off to U3; incl. `terminal.diff_lines` and `startup_conversation` `ask`), §2.23 `records.ex` (hand-off to S2); `Registry` API incl. `synonyms/0`, `cli_entries/0`, `scalar_keys/0` (asserted ≤ 256); the daemon-side **choice parity tests** (§3.2.6). | same + `DMNT/settings/c74_registry_parity_test.exs` | a test that every `settings` column of `DOM/settings/setting.ex` is either a registry storage or listed in §2.24/§2.25 by name; `length(Registry.all())` printed in the test name; synonyms resolve; the parity tests pass. |
| S1-4 | `CliFile` (§3.8.1: `read_all/1`, `write_changes/3` with per-key CAS and the fingerprint re-check before rename, `write_text/3`, 64 KiB, symlink/not-JSON refusal, atomic 0600, temp cleanup) and the daemon frame: `Settings` facade, `Context` (Inspect except env/task_results), `Command` (Inspect hides secrets), `Result`, `Error`, `TaskSpec`, `Handler` (+ `cache_reads/1`), `Router` (static table §3.3.2; unloaded modules → `unsupported`), `Wire`, `Layers` (ignored layers, D40), `Cas` helpers (§3.3.5), `TaskCache` (pure LRU + TTL bookkeeping + sessions store bounds). **Then tag `c74-S1-core`.** | `CORE/settings/cli_file.ex`, `SVC/settings.ex`, `SVC/settings/{context,command,result,error,task_spec,handler,router,wire,layers,cas,task_cache}.ex` | `CORET/settings/c74_cli_file_test.exs`: unknown keys kept; CAS conflict; invalid value; 0644 → 0600; symlink refused; not-JSON not replaced; a concurrent writer between read and rename is retried once then `:busy` (simulated with a hook); temp files never left (list the dir). `DMNT/daemon/service/settings/c74_router_test.exs`: every action of §3.4.3 routes; an unknown action is refused before any module call; `inspect(command)`/`inspect(ctx)` never contain a canary; `TaskCache` eviction by bytes and count. |
| S1-5 | Protocol: `settings.query`/`settings.command` in `ServiceRequest` (ops, atoms, `@reads`, param key sets, `valid_params?/3` through `WireBounds`), capability `settings` (handshake list, default grant, `Connection.capability?/2`), `Inspect` for `ServiceRequest` hiding `secrets`; `Connection`: requests stored without the `secrets` body key, `fail_request/3` using the stored operation, `:settings_query` in its read list, `format_status/1` redacting `:message`. | `CORE/protocol/{service_request,service_handshake}.ex`, `SVC/connection.ex`, `DMN/service.ex` | `CORET/protocol/c74_settings_request_test.exs`: every bound (just inside, just outside); scope other than global refused; the capability list has 17 names; existing handshake tests updated. A Connection test: a deadline on a settings query answers a typed error, on a settings command an `outcome_unknown` outcome; the connection stays open. |
| S1-6 | Client wire: `Request` kinds/constructors/`validate/1` (WireBounds)/Inspect, `Delta` kinds, `Codec` request bodies + the two response kinds + the `outcome` → `SettingsResult` mapping + delta decoding with the §3.4.6 rules, DTO modules, the `Effect.validate` clause (§3.6), `EffectRunner` failures → `{:settings_failed, …}`, `daemon.ex` `request_capability/1` + `format_status/1`, `Fake` + `Fake.Settings` (§3.6, generic parts only), conformance fixtures. **Then tag `c74-S1-wire`.** | §3.1 "Client wire" row | `CLIT/ui/data_source/c74_settings_codec_test.exs`: a secret field as a string, a 5-char hint, an extra key → whole response rejected, no connection close; an invalid scalar → only that value `invalid`; an `outcome` reply → `SettingsResult` `unavailable`, no close; `Fake.Settings` answers every generic view/action and `unsupported` for S2 actions without U2's module; conformance suite green. |
| S1-7 | `Values`: snapshot (§3.3.3: layers incl. ignored ones, winner, base, invalid state and normalisation, dynamic choices via `effective_model`, AT4/AT16 states, cache hygiene marks) and writes `values.patch`/`values.reset`/`profile.apply` (§3.3.4: ≤ 256 changes, `{:conversation_mode}`, post-commit invalidation, override clearing for both session model rows) through the domain changesets inside one `Repo.transaction` with a fresh read and value CAS; `{:project_file_key, _}` delegated to `Settings.ProjectConfig` when loaded; exact messages. | `SVC/settings/values.ex` | `c74_values_test.exs` (fixture Repo, pool 3): patch/reset/conflict/unchanged/rejected per scope; a write never touches another column; D16 nullable clear; D24 no insert on read (row count unchanged after a snapshot); `session.mode` writes the four columns as `mode_fields/1` does for all five modes; reset-all of every scalar key in one request and undo of a 70-key batch; `theme = "nord"`, `research_max_live = 40`, `monthly_budget_usd = 12.5` → rows `invalid`, other rows fine, `r` resets with the raw base; `50.0` reads `50`; SWARM_APPROVAL=ask and SWARM_CONVERSATION=<uuid> set → no env winner; project file `effort` → ignored layer, the global value wins; `--model` → `flag` on both session model rows, a write clears it; a cached `get_cached` filled between write and commit sees the new approval mode after the command (M2). |
| S1-8 | `Overview`, `Facts`, `Usage`, `Projects` (§3.3.6) with attention/glance merged from every loaded handler (AT4, AT10 with the usable predicate, AT11, AT16, AT18); `records:projects` (non-scratch projects); the `open` view. | `SVC/settings/{overview,facts,usage,projects}.ex` | tests: attention order and cap 64; facts contain no secret env value (canary); usage `no price` rows; AT10 on a fixture seeded by `Providers.seed_defaults/0` with `LLMOTIONS_API_KEY` unset; a keyless `http://192.168.1.20:8000/v1` provider is usable; `open` equals the four separate views. |
| S1-9 | Settings tasks in `PersistedBackend` (§3.3.8 rules 1–10): start/replace/cap 8, kill vs reporting deadlines, `ProbeRunner`, per-kind stop, progress throttle (250 ms) and watch-queue replacement of running deltas, summaries, redaction (incl. < 8-byte secrets), `TaskCache` + sessions store + purge timers, the `task` view, `task.cancel`, `terminate/2` cleanup. | `SVC/persisted_backend.ex`, `SVC/settings/{tasks,probe_runner}.ex` | `c74_tasks_test.exs`: a held cancellable task times out with `no answer in N s`; a held non-cancellable one reports `still running after N s` and is not killed; cancel of a probe of a fixture stdio server (`test/support/os_process.ex`) leaves no OS process; cancel of an export leaves no temp file; a 9th is `busy`; 300 progress reports produce ≤ 4 deltas per second and never fill the watch queue; a task whose result is > 128 KiB is readable page by page with `view=task` and no delta exceeds 16 KiB of summary; a purge timer drops a secrets-bearing entry; secrets in a failing task's message are redacted. |
| S1-10 | Backend wiring (§3.3.10): the settings job pool of 4, query keys with `slot`, command jobs (never replaceable, pool check before admit, every settle path completes the ledger with a settings_result, timer = timeout − 1 s), the 120 KiB ledger guard, ledger rules for secrets, topic subscriptions + 100 ms coalesced `settings_update` + `schedule_refresh/1` (R3) + marking rules (§3.3.9) + never keeping the settings struct (R19), `UIState.opened/1` on init and switch, `format_status/1`, `LiveBackend` answers (D28), dispatch refusal (D11); `SVC/settings/deltas.ex`. | `SVC/{persisted_backend,live_backend}.ex`, `SVC/settings/deltas.ex` | `c74_backend_settings_test.exs`: a command with secrets leaves no ledger row and a retry re-runs it and answers `unchanged` (a secret write whose stored secret already equals the pasted one answers `unchanged`, checked before CAS); a command job killed mid-run, timed out, or cancelled by terminate leaves its ledger row `completed` with `unavailable` (query the table); a 5th concurrent settings job is refused before `admit`; a conflict on a 200 KB file does not crash the backend and replays from the ledger; two `file` queries with different refs both answer; a desktop-side `Settings.update/1` produces one `settings_update` with origin `elsewhere`; workspace metadata re-projects the new chat model; a fixture session older than a retention cutoff that is the backend's conversation survives `storage.apply_retention`; dispatch on a seeded fresh DB (keyless llmotions) is refused with the D11 words; a handler raising on a command with the canary in `secrets` leaves no canary in `capture_log`; LiveBackend `unavailable`. |
| S1-11 | R1: canonical `FeatureRequest` error messages + agreement test; R5: `DTO.WorkspaceMetadata.models` ≤ 400 and the new `chat_provider: %{name, usable}` field (the session conversation's effective chat provider after the `--model` overlay, projected by the backend); `SessionConfiguration.usable?/1` public and widened to private hosts (D11). | `SVC/{feature_request,session_configuration}.ex`, `SVC/persisted_backend.ex` (`workspace_metadata/1` projection), `UI/data_source/dto/workspace_metadata.ex` (+ `workspace_snapshot.ex` where it embeds the metadata keys; S1 owns these DTO edits), the contract fixtures | tests for both risks; the new field round-trips through the codec's exact-shape check; `usable?/1` table (key, loopback, 192.168.x, `.local`, public keyless). |
| S1-12 | `Transfer` (export v1 format §3.3.7 with `mcp_plain_values`, import preview/apply with records matched by name, secrets refused, `kind: :file` cleanup) and `Doctor` (§3.3.7 checks). | `SVC/settings/{transfer,doctor}.ex` | round trip export → import on a fresh fixture DB gives identical `values` snapshots; MCP env values are `<secret: set>` by default; a file containing a secret field is refused with the §3.11.8 words; doctor reports a missing research root. |
| S1-13 | Launcher: `swarmcode settings [QUERY] [--dir DIR]` in `rel/overlays/bin/swarmcode` (help text, usage errors, the `./settings`/`./config` rule) and in `Release.parse/1`; `PersistedSession` settings-only mode (no exit 3 for a missing provider, `%Init{settings_open: q}`), the new exit-3 texts (provider, lease held), `TerminalPreferences.launch/4` wiring with `CliFile.read_all/1` and the fallback, `Theme.put_accent/1` call, `NO_COLOR` rule in the exit summary (D21), `/settings` words in `--plain`/`-p` (D2). | `release.ex`, `REL/persisted_session.ex`, `rel/overlays/bin/swarmcode` | `CLIT/entry/c74_settings_entry_test.exs` (parse grammar, usage errors); a script test through `bash -n` + the existing launcher test pattern; `persisted_session_release_test.exs` updated for the exit-3 texts. |
| S1-14 | `swarmcode config` (§3.10.3) in `REL/config_command.ex` + `PersistedSession.with_foundation/2` + script dispatch (`config` → headless eval; `config secret` with the `stty -echo` wrapper): scalars, records, secrets from stdin, search/mcp synonyms, headless tasks, the lease-held and desktop-running behaviour. | `REL/config_command.ex`, `REL/persisted_session.ex`, `release.ex`, script | `CLIT/entry/c74_config_command_test.exs` against a fixture DB and a temp cli.json: list/get/set/reset/keys/path/records/record get·set·add·delete/secret --stdin (piped)/search enable·order/mcp toggle/export/import/doctor, every exit code, a secret in argv refused with the stdin sentence, `--expect` conflict exit 4, a held lease (`test/support/lease_fixture.ex`) → exit 3 with the session sentence while `set terminal.panel hidden` still works, output never contains a canary. |
| S1-15 | `mix swarm_code.settings --write/--check` + `docs/settings.md` + docs test; `docs/keybindings.md` untouched (U1 regenerates). | `apps/swarm_code_cli/lib/mix/tasks/swarm_code.settings.ex`, `docs/settings.md` | `CLIT/c74_settings_docs_test.exs` fails on a stale file. |
| S1-16 | Socket end-to-end: a real `Connection` + `PersistedBackend` on a fixture DB: hello grants `settings`; `settings.query open`; `values.patch` accepted then conflict; an `outcome` reply path; a deadline on a query and a command keep the connection open; `provider.set_key` (if S2 not merged: `unsupported`) — the frame bytes on the socket never contain the canary except in the one request that carries it. | `DMNT/daemon/service/settings/c74_socket_test.exs` | green on the S1 branch alone. |
| S1-17 | Notes, deviations, `mix precommit`, report. | — | precommit green (except the worktree test). |

### 5.2 S2 — integration handlers (14 tasks; starts at `c74-S1-core`)

| # | Task | Files | Done when (tests in `DMNT/daemon/service/settings/c74_<name>_test.exs`, fixture Repo pool 3) |
|---|---|---|---|
| S2-1 | `Secrets` (§3.5.9: `mask/1` → `%{set, hint}`, `hint/1` (last 4 when ≥ 12), `check_paste/1` messages incl. the 8-byte floor, `redaction_list/1`, `masked_entries/1` by `secret_kv?/2`); own `registry/records.ex` from now on (complete every §2.23 field with `secret?` and `max`: `provider.models` 2 000, `mcp_server.tools` 512, `file` with `instructions`, `project_config.ignored_entries`). | `SVC/settings/secrets.ex`, `CORE/settings/registry/records.ex` | hint rules; paste checks; every record kind with a secret field is listed. |
| S2-2 | `Providers` records/record/create/update/set_key (both `test_first` modes)/clear_key/delete with replacements (§3.5.1, written directly with `Settings.update/1`), `used_by`, attention (AT2, AT3 with the usable predicate), glance; post-commit invalidation. | `SVC/settings/providers.ex` | CAS conflicts; delete replaces defaults in the same transaction; a key never appears in any result (canary); desktop changeset messages verbatim; `test_first` with a refused key (loopback 401) leaves `providers.api_key` unchanged; `test_first: false` saves. |
| S2-3 | Provider tasks: `provider.test` (incl. an unsaved key in `secrets` and a draft), `fetch_models` (difference rows paged, `removed_in_use` counts, `truncated` above 2 000), `apply_models` from the fetch task (replace refused when truncated), `fetch_all` (≤ 4 concurrent, progress), `forget_caps`; loopback models server. | same | 200 with 3 models; 401 → the domain's words; timeout words; fetch writes nothing until apply; a 2 500-model stub → `truncated`, replace refused, add fills to 2 000; `fetch_all` progress deltas. |
| S2-4 | `Efforts` (`efforts.save` with `Efforts.from_rows/1` exact errors → `field_errors rows[i]`, `remove_override`, presets) and `Models` (`records:model_options` with price/context/in_last_fetch). | `SVC/settings/{efforts,models}.ex` | row errors mapped; model options sorted and paged. |
| S2-5 | `Pricing` (`put_row` validation, `delete_row`, `records:pricing_rows`, `records:unpriced_models`, AT5). | `SVC/settings/pricing.ex` | a row needs both prices; unpriced detection over defaults and the last 30 days' conversations. |
| S2-6 | `Search` (records synthesised for missing kinds without writes — D24; `update`, `set_key` (both modes), `clear_key`, `move` (order column CAS), `test` via `Search.test/2` with a loopback stub; AT6, AT15, AT17). | `SVC/settings/search.ex` | no insert on read (row count); order swap; test success/failure words (432 → `rate or plan limit`); a refused replacement keeps the old key. |
| S2-7 | `MCP` (records grouped by scope with status/tools from the MCP supervisor's public API, `create`/`update` (explicit scope only — R7)/`set_secret`/`toggle`/`set_tools` (one write)/`reconnect` (subscribe first; disabled → rejected)/`test` (probe kind)/`delete`); env/header masking by `secret_kv?/2`; AT1. | `SVC/settings/mcp.ex` | update never changes `project_id` unless `scope` is in attributes; secret env values (desktop-rule names, `GH_PAT`, `sk_live_…`, `postgres://u:pw@`) never returned; reconnect completes when the status message arrives before the task would have waited (the subscribe-first ordering); `set_tools` of 300 tools is one row update. |
| S2-8 | `MCPImport` (`.mcp.json` from the project root or a typed path confined to the user's home; `mcpServers` shape; variables with `in_shell`; SSE unsupported; drafts cached daemon-side with secret values, 10-minute TTL; `apply` by `import_id` + ticked names + per-value choices + renames). | `SVC/settings/mcp_import.ex` | secrets never in the read result; `${GITHUB_TOKEN}` detected, `shell` resolves from the environment at apply, `paste` uses the slot, `literal` stores the text; an SSE entry cannot be applied; expired id → `not_found` with words. |
| S2-9 | `Storage` (`measure` into the sessions store, `plan`, `run` (subscribe first, monitor), `vacuum` and `apply_retention` inside the `:storage_cleanup` registration, selection from non-nil days only, `records:storage_sessions`). | `SVC/settings/storage.ex` | a plan over fixture sessions; run progress; retention on a fixture with old sessions deletes them and stamps `storage_last_cleanup_at`; retention while a cleanup runs → `busy`; an open conversation is kept back. |
| S2-10 | `LSP` (`lsp.check` which-lookups in a task with 5 s timeout, `unknown_keys`; `lsp.stop`; `lsp.remove_key`). | `SVC/settings/lsp.ex` | a missing executable → `not installed: <exe>`; an unknown key is listed and removable. |
| S2-11 | `Files` (§3.4.5 refs incl. `instructions`; `file` view ≤ 256 KB; `file.save`/`create`/`delete`/`clear` with sha256 CAS and fingerprint-only conflicts, `AtomicFile.replace/3`, confinement, temp cleanup on every path; `Memory.file/2` paths; config.json `needs_confirmation` for new hook commands in a trusted project; `Projects.broadcast/0` after config.json saves). | `SVC/settings/files.ex` | path traversal names refused; CAS conflict carries no content; a failed write leaves no temp file; MEMORY.md round trip; the instructions winner (`CLAUDE.md` only → it; none → create `AGENTS.md`); a trusted project's config.json save with a new hook answers `needs_confirmation` until `confirmed_hooks: true`. |
| S2-12 | `Library` (commands (incl. `shadowed_by_builtin`), agent definitions (three tiers, shadowing), skills, workflows lists; `file.create` templates with 0700 tier dirs; `workflow.smoke` via the domain smoke check; bundled/builtin read-only; AT12). | `SVC/settings/library.ex` | lists on a fixture project; create from template; bundled delete refused; a `settings.md` command is marked shadowed. |
| S2-13 | `ProjectConfig` (record view with parse state, line/column and `ignored_entries`; hooks/profiles CRUD + move; `remove_key`; `remove_entry`; `remove_top_level/3` for `Values`; fingerprint CAS; unknown keys semantically preserved; atomic write; `Projects.broadcast/0` after every write; AT7, AT8, AT9). | `SVC/settings/project_config.ex` | invalid JSON reported with position; every §3.5.8 ignored-entry reason on a fixture; a hook add keeps unknown keys semantically equal; conflict on a changed file; `move_hook` twice within one second → the engine-side `Hooks.cached_config/1` returns the new order. |
| S2-14 | Attention/glance for every handler (§2.1 AT list: AT1–AT3, AT5–AT9, AT12, AT15, AT17), notes, precommit, report. | — | a test calls every S2 handler's `attention/1` on the Appendix A fixture and gets the expected items. |

### 5.3 U1 — the client shell (19 tasks)

Tests live under `CLIT/ui/settings/` and drive the reducer with `Fake.Settings` (after U1-3) or pure
fixtures (U1-1..U1-2); scene tests follow `CLIT/support/pass73_scenes.ex` (text of the scene grid, roles
by span).

| # | Task | Files | Done when |
|---|---|---|---|
| U1-1 | Pure structs and behaviours: `Layer`, `Page`, `Row`, `Op`, `Ctx` (`%{state_view, data, caps, size, now, project, conversation, prefs, launch_facts, overrides}`), `Detail`, `Attention`, `Section` (+ `use` defaults), `Editor`, `Sections.module_for/1`, `Glyphs`, `Paste`, `Undo` skeletons. | `UI/settings/*.ex` | `c74_structs_test.exs`: `inspect/1` of `Layer`/`Paste` with a canary shows no canary; `module_for/1` covers the 22 ids. |
| U1-2 | Keymap: seven contexts, `@typing_contexts`, `:global` not expanding into them, settings bindings (§3.9.2) incl. F2, `Context.of/1` order, `Bindings.lookup/4`, `key_in_context/3`, `keys_in_context/3`, `keys_for/2`; pass-through `Keymap.Overrides` (incl. `bindings_for_key/2`) + `Keymap.KeyName`; call sites (`keymap.ex`, `hint.ex`, `projector/{status,dialog}.ex`, help); `docs/keybindings.md` regenerated. | `UI/keymap.ex`, `UI/keymap/{bindings,context,docs,overrides,key_name}.ex`, `UI/hint.ex`, projectors, `docs/keybindings.md` | existing keymap tests green; `c74_keymap_test.exs`: F2 opens from main/composer, never Ctrl-K, no Alt-only binding, one binding per key and context, every settings letter bound only in `:settings`; `mix swarm_code.keymap --check` green. |
| U1-3 | Merge `c74-S1-wire`. `State`/`Init` fields (§3.7.1 incl. `settings_history`); `Preferences` v2 as a wrapper over `CliFile` (§3.8.1); runtime prefs queue with `{:settings_cli_write|read|write_text, …}` effects, the legacy save sending only the changed key, and `Effect.validate/1`; `settings_external_edit` effect (private temp 0600, `terminal.editor` > `VISUAL` > `EDITOR` > `vi`, temp removed on every path); the `{:copy}`/`{:open_folder}` runtime effects (§3.7.2); `format_status/1` of `SessionRuntime` and the port owner redacting `:message`. | `UI/{state,init,effect,session_runtime}.ex`, `UI/init/preferences.ex`, `UI/renderer/ratatui_port/owner.ex` | `c74_preferences_test.exs`: legacy API unchanged; a 33rd job busy; `/diff` after an external change of `theme` keeps the external value; open-folder without a display toasts the words; a crash report of the runtime with a paste event in flight has no canary. |
| U1-4 | `Reducer.Settings` open/close/levels/restore/resume (§3.7.3), entry points (§3.10.1: `/settings`, `/config`, `/prefs`, F2, palette rows with the ranking rule, D22 removal of the library settings form, toast hints, plain/one-shot words), `auto_open?` hold, `DeepLink.resolve/2` (§3.7.12), `%Init{settings_open: q}` at boot. | `UI/reducer.ex`, `UI/reducer/settings.ex`, `UI/settings/deep_link.ex`, `UI/{slash_palette,switcher,library,layer_spec}.ex` | open → Esc restores focus/draft/scroll exactly; `/settings theme` focuses `terminal.theme`; `/settings tavily` opens the Tavily record once records load; `/settings nonsense` shows the empty search; approvals do not pop over the layer and Ctrl-N reaches them; typing `mo` in the palette lists `/model` before any settings row. |
| U1-5 | Data flow: `loads/1` → queries with generation/purpose; the `open` view at open; snapshot/record/file handling; `settings_update`/`settings_task` deltas; `view=task` fetch on done and re-query after resync; stale responses and superseded `:stale_revision` failures dropped; revision re-query rule; reconnect words (§4.10); capability missing words; LiveBackend `available: false`; `outcome` replies. | `UI/reducer/settings.ex`, `UI/settings/data.ex` | a response for an old generation changes nothing; an `elsewhere` update marks changed rows for 2 s; a lost final task delta is recovered by the resync re-query; an `outcome` reply keeps the connection and re-queries. |
| U1-6 | `Provenance` + `Rows.scalar/2` (§3.7.5, §3.8.3, ignored layers, invalid rows) + the commit path (§3.7.6: write keys, one in flight, queued value dropped on conflict, 300 ms `saving…`, outcomes, WireBounds refusals, conflicts §3.7.9) + live consumers (§3.8.5 incl. `diff_lines` and the desktop-mode follow) + toasts (§4.7). | `UI/settings/{provenance,rows,commit,conflict,toast}.ex`, `UI/reducer/display.ex` | `c74_commit_test.exs`: two quick commits → two requests in order with the right `expected`; a conflict on the first drops the queued second and shows it as *mine*; keep-mine sends `expected = theirs`; take-theirs; rejected shows the message; `terminal.panel` changes `panel_mode` at once; `/theme` updates an open layer; a `desktop.mode` change repaints when Theme follows. |
| U1-7 | Minimal editors (Toggle, Enum segmented, Number stepping/typing, Text) and the text-only page projector (`UI/projector/settings/text_page.ex`). **Then tag `c74-U1-api`.** | `UI/settings/editors/{toggle,enum,number,text}.ex`, `UI/projector/settings/text_page.ex` | every section opens through the defaults and a scalar of each type commits against `Fake.Settings` (text-page assertions). |
| U1-8 | Editors 1 complete: Enum picker, Checklist (filter over 20), Number specials/nullable/units/big step (Shift-←→, PgUp/PgDn), ReadOnly, Action. | `UI/settings/editors/{enum,checklist,number,read_only,action}.ex` | per editor: keys → commits/cancels; out-of-range typed value shows the exact message and does not commit; Shift-→ moves `limits.command_timeout` by 60 s. |
| U1-9 | Editors 2: Text (completion), Multiline (16 KB, Ctrl-S, Ctrl-X round trip), List (windowed, `/` filter over 20), KeyValue (secret by `secret_kv?/2`, `s` treat as secret), Path, LspCommand, ModelFallback. | `UI/settings/editors/{text,multiline,list,key_value,path,lsp_command,model_fallback}.ex` | list add/edit/remove/move/remove-all(confirm) and filter on a 2 000-item list (only visible rows projected); key-value secret detection incl. `GH_PAT`; external edit result applied with fingerprint CAS. |
| U1-10 | Paste target (§3.7.7): paste, Ctrl-T type instead, the 8-byte floor, first key vs test-first replacement (`pending_task`, `s save it anyway`, Esc keep), secret rows, draft secrets. | `UI/settings/paste.ex` | `c74_secret_canary_test.exs`: paste the canary, commit; assert it is absent from the scene text, `inspect(state)`, undo, changelog, search index, toasts, the companion snapshot and every logged line (capture log); `Fake.Settings.requests/1` shows `[REDACTED]` and `Fake.Settings.secret_writes/1` holds exactly one `{slot, sha256}` whose hash is the canary's; a refused replacement sends nothing more unless `s`; typing ignored unless `caps.paste == :unavailable` or Ctrl-T. |
| U1-11 | Undo/redo/changelog in `State.settings_history` (survives close), reset (incl. staged revert and invalid rows), section reset (confirm), drafts, pending on leave (§3.7.10). | `UI/settings/{undo,drafts,pending}.ex` | undo of a value sends the inverse CAS; undo after close and reopen still works; secrets `· no undo`; leaving with a paste asks; valid staged MCP fields apply on leave (via a stub section). |
| U1-12 | Search (§3.7.11: index with models and tools, ranking, `@filters`, fuzzy), the in-page filter (D37) and the `:` command line. | `UI/settings/{search,command_line}.ex` | ranking table test; `@modified`, `@env`, `@section:providers`; `deepseek-v4-lite` finds the provider record; fuzzy header; `/` in a 312-item list filters in place and `/` on an empty filter opens the global search; `:set terminal.panel compact` writes; `:set` with a bad value keeps the line with the message; F2 scene at 160×45. |
| U1-13 | Popovers: pickers (filter), confirmations (T§12 mechanics, counts loading, typed confirmations, the §4.8 rows incl. hooks via external edit and quit while a non-cancellable task runs), help sheet (generated §4.12), project picker (D12), pending popover; focus trap; Esc once. | `UI/settings/popover.ex`, `UI/projector/settings/popover.ex` | Tab trapped; letter presses destructive; typed `delete` required; focus returns to the opener; F13 scene at 160×45. |
| U1-14 | Task rows (§4.9): running/elapsed (1 s ticks only while visible)/progress/done/failed/timeout/cancelled/still running; `c` cancel; closing the layer cancels cancellable tasks it started; needs-you chip. | `UI/settings/tasks.ex` | ticks stop when the row scrolls out; close sends `task.cancel` for cancellable ones only; a non-cancellable row survives close and reopen. |
| U1-15 | Projector: size classes and geometry (§4.2), header/search/strip/rail/page/detail/drawer/status/footer, row states (T§6.4), tables with column priorities, NO_COLOR/ASCII (§4.11), too-small words. **Then tag `c74-U1-api-2`.** | `UI/projector.ex`, `UI/projector/settings.ex`, `UI/projector/settings/*.ex` | scene snapshots at 160×45, 120×30, 90×30, 80×24, 72×18 for Overview and a registry-default page (F15, F16); ASCII twin scene has no non-ASCII byte; monochrome scene carries every mark as a glyph/word; paint nodes ≤ 4 096 on a 400-row page. |
| U1-16 | Overview page (§4.14) from `overview` + client attention (AT13 cli.json, AT14 overrides) + *changed in this session* from `settings_history`. | `UI/settings/sections/overview.ex` | F1 layout at 160×45 with Appendix A data (text compare of the page column rows). |
| U1-17 | Provider-missing composer refusal words (§3.10.1 with the provider name), the `no model provider · Providers` header chip from the workspace `chat_provider.usable`, `swarmcode settings` boot open. | `UI/reducer.ex`, `UI/projector/{status,composer}.ex` | Enter with an unusable effective provider keeps the draft and shows the words; F2 opens Providers. |
| U1-18 | Performance and safety tests: search < 20 ms over 8 000 entries; no timers while idle (count `:timer` effects); no `Task.start` in new code (grep test); architecture test still forbids `UI/` → daemon/Repo. | tests | green. |
| U1-19 | Notes, precommit, report. | — | — |

### 5.4 U2 — integration sections (14 tasks; starts at `c74-U1-api`)

Each section module implements `Section` (§3.7.2); tests under `CLIT/ui/settings/sections/c74_<section>_test.exs`
drive `Reducer.Settings` against `Fake.Settings` + U2's `Fake.SettingsIntegrations` and assert rows and
requests; after merging `c74-U1-api-2` they add the scene-text tests of §4.14 (160×45, Appendix A).

| # | Task | Files | Done when |
|---|---|---|---|
| U2-1 | `Fake.SettingsIntegrations` (§3.6): the S2 actions against the Fake store with the §3.5 messages, Appendix A's task results (fetch difference, reconnect failure, lsp check), `test_first` refusals, MCP import with variables. | `UI/data_source/fake/settings_integrations.ex` | every S2 action of §3.4.3 answers; a held `provider.set_key` test can be released with a refusal. |
| U2-2 | `ModelPicker` editor (F4): providers grouped, filter over name/model, price and context columns, `not in the last fetch` marks, the null choice (`same as …`) where the entry is nullable, `f` refetch of the group's provider (task). | `UI/settings/model_picker.ex` | choosing writes the model wire value; filter; F4 scene rows at 160×45 (after api-2). |
| U2-3 | Providers list page (§4.14), presets draft (`a`, §2.3 list with effort presets), create with `Ctrl-S` (key paste inside the draft), empty state. | `UI/settings/sections/providers.ex` | draft → `provider.create` with the secret in `secrets` and the preset's `effort_levels`; name taken → field error under the row; DeepSeek preset → `deepseek` levels. |
| U2-4 | Provider record page (F5/F6/F12): fields with instant writes, key paste (first key: save then test; replacement: test first), clear (confirm), test/fetch with the paged difference and apply (`a`/`+`, `+` only when truncated), `▸ Use <name> for new chats`, forget caps, delete with replacement pickers, models list sub-page. | same | fetch difference rows exact; delete sends replacements for every default it serves; conflict on a field; a refused replacement keeps the old key and `s` sends `test_first: false`; F5/F6/F12 scenes (after api-2). |
| U2-5 | `EffortLevels` sub-page editor (draft table, JSON body validation, scope provider/model, preset, reset to built-in, `Ctrl-S` → `efforts.save`, row errors). | `UI/settings/effort_levels.ex` | row error `rows[2]` lands under row 3; T§24 sketch text. |
| U2-6 | Pricing page (sketch §4.15: unpriced group, table in the fixed column order, draft rows, filter). | `UI/settings/sections/pricing.ex` | a row with one price stays a draft; both → `pricing.put_row`; sketch text. |
| U2-7 | Search & web page (F7 first page: engines table, toggle, move, key paste (test first when replacing), test words, reader with AT15's note, facts). | `UI/settings/sections/search_web.ex` | `J` sends `search.move`; enabling a key-needing engine without a key opens the paste first; test words with the plan warning; F7 scene (after api-2). |
| U2-8 | MCP list page (scope groups, project picker, add draft) and the import preview (`UI/settings/mcp_import.ex`: ticks, conflicts/rename, variables `v`/`p`/`k`, SSE unticked, scope picker) → apply. | `UI/settings/{sections/mcp.ex,mcp_import.ex}` | import preview shows masked secrets and `${GITHUB_TOKEN}` with its choices; apply sends `import_id`, names, renames and choices, pasted values only in `secrets`; sketch text. |
| U2-9 | MCP record page (F8): staged connection fields (D8; `r` reverts, `R restart now`), `KeyValueSecrets` editor (`s` treat as secret), tools checklist (`Space`/`A`/`N`, `/` filter), `t` test, `o` output, scope row, delete. | `UI/settings/{sections/mcp.ex,key_value_secrets.ex}` | leaving applies staged fields in one `mcp.update`; `r` on a staged field reverts without a request; an invalid staged field asks; scope changes only from the scope row; F8 scene (after api-2). |
| U2-10 | Language servers page (LspCommand rows, check results, unknown keys with `x remove`, stop action). | `UI/settings/sections/language_servers.ex` | `off` / custom / default writes; an unknown key row sends `lsp.remove_key`. |
| U2-11 | Storage page + `CleanupWizard` (§2.18: overview, Quick presets with previews, Sessions table with pick/pick all/sort/filter/locks/pinned, Advanced options, review with typed `delete N`, running, done with the vacuum nudge; `▸ Reclaim disk space (VACUUM)`; apply retention now). | `UI/settings/{sections/storage.ex,cleanup_wizard.ex}` | Esc ignored while running; each Advanced change sends `storage.plan` and a stale plan is dropped; a Quick preset goes straight to review; progress words; retention fields' quick picks; the choose sketch text. |
| U2-12 | Memory & instructions page (project/global memory and the instructions file rows, edit ≤ 16 KB, external edit, clear with confirm for memories, folder, the trust warning). | `UI/settings/sections/memory.ex` | save with fingerprint; conflict words after an external change (re-read, `s`/`e`/Esc); an untrusted project's instructions row warns; Enter on a missing AGENTS.md creates it. |
| U2-13 | Library page (sketch §4.15: four groups, `n` new from template, `x` delete, `t` smoke, bundled read-only, shadowed-by-built-in commands). | `UI/settings/sections/library.ex` | smoke results per workflow; bundled delete shows why not; sketch text. |
| U2-14 | Notes, precommit, report. | — | — |

### 5.5 U3 — general sections and the terminal (14 tasks; starts at `c74-U1-api`)

Tests as U2's; actions U3's pages send that `Fake.Settings` does not simulate (`project_config.*`,
`file.save` of config.json) are scripted with `Fake.Settings.stub_reply/3`.

| # | Task | Files | Done when |
|---|---|---|---|
| U3-1 | Own `CORE/settings/registry/terminal.ex` (final §2.14–§2.17 entries incl. `diff_lines` and `startup_conversation` `ask`, cli validators: hint letters, accent parsing, editor one line); `REL/terminal_preferences.ex` `launch/4` (§3.8.4 every rule, ignored env layers); `Theme.put_accent/1` + accent-derived roles; glyph forcing through `Capabilities`. | `CORE/settings/registry/terminal.ex`, `REL/terminal_preferences.ex`, `UI/theme.ex`, `UI/capabilities.ex` | `CLIT/release/c74_terminal_preferences_test.exs`: a table of env × cli.json × desktop mode cases → results (incl. `NO_COLOR=` empty = colour, D21; `SWARM_KEYMAP=emacs` ignored); accent twins for 256/16 colours. |
| U3-2 | `Keymap.Overrides` and `KeyName` full implementation (§3.9.3, §4.4): compile, lookup, keys_for, check (fixed, taken, unreportable, unknown, 4 keys), `[]` unbind, `bindings_for_key/2`, settings letters remappable, errors → AT14. | `UI/keymap/{overrides,key_name}.ex` | an override moves `palette_open` to F5 and the footer/help print F5; `settings_test` remapped to `T` works on a provider row; `[]` unbinds `palette_open` (hints omit it, help says `unbound`); Esc/Enter/arrows/`?`/Ctrl-S/approval letters refused; `Ctrl-Shift-A` unreportable; `bindings_for_key("Ctrl-J")` lists every context. |
| U3-3 | `KeyCapture` (F11: raw events, Esc twice cancels, swap, `+` add mode) and `Color` (hex, `#RGB`, swatch, contrast ratio vs the page colour, twins) editors. | `UI/settings/editors/{key_capture,color}.ex` | capture of Ctrl-L writes `["Ctrl-L"]`; `+` then F6 writes `["Ctrl-D","F6"]`; swap writes both bindings in one cli.json change set; F11 capture scene (after api-2). |
| U3-4 | Models & effort page (F3 with §4.1 item 13) with `ModelPicker` when loaded else `ModelFallback`; one `Mode` row; the consensus sub-page. | `UI/settings/sections/models_effort.ex` | session and global rows write to their own layers; effort choices follow the chosen (overlaid) model; choosing *Consensus* sends one `session.mode` change; F3 scene (after api-2). |
| U3-5 | Deep research page (F7 second page; tier null labels). | `UI/settings/sections/deep_research.ex` | level hints show medians or `not measured yet`; F7 scene (after api-2). |
| U3-6 | Agents & limits page (F9). | `UI/settings/sections/agents_limits.ex` | bounds messages verbatim; F9 scene (after api-2). |
| U3-7 | Approvals & trust page (F14): project picker, full-access confirm, trust confirm listing hooks, untrust (D13), families (`x`, undo, forget all). | `UI/settings/sections/approvals.ex` | going down to auto does not ask; full asks; after an accepted change of the session project's mode and the workspace snapshot that follows, the transcript has one policy notice and one toast (the existing `note_policy_change/2`); F14 scene. |
| U3-8 | Project file page (sketch §4.15): header state, top-level keys, hooks (confirm D14 when trusted), profiles, ignored entries with `x remove`, ignored keys (D15), external edit with fingerprint and the hook confirmation on `needs_confirmation`. | `UI/settings/sections/project_file.ex` | invalid JSON state words; a new hook in a trusted project asks; an external edit adding a hook command shows the D14 dialog and re-sends with `confirmed_hooks: true`; sketch text. |
| U3-9 | Appearance page (F10) with the live preview and contrast line; theme live apply; next-launch rows. | `UI/settings/sections/appearance.ex` | preview uses the candidate palette while editing; `SWARM_THEME` override words; F10 scene (after api-2). |
| U3-10 | Layout & transcript (incl. `Diff lines shown` and the `@diff_preview` read in `turns.ex`), Keys & input (+ the Key bindings sub-page: sketch §4.15, context picker, filter/reverse lookup, add/remove/unbind/reset), Session & startup pages. | `UI/settings/sections/{layout,keys_input,session_startup}.ex`, `UI/projector/workspace/turns.ex` | wheel lines disabled when mouse is off; `diff_lines` 4 shows 4 lines then `… N more lines`; `/ctrl-j` lists its bindings; reset every binding confirm; hint letters messages; sketch text. |
| U3-11 | Budget & usage page (gauge, by-model table) and Desktop app page (window state collapsed). | `UI/settings/sections/{budget_usage,desktop_app}.ex` | `no price` rows; desktop rows say `no effect in the terminal`; a stored `12.5` budget shows the invalid row. |
| U3-12 | Files & environment page (cli.json checks + make private + edit round trip through `write_text/3` with the not-JSON and warning outcomes, database/log/project file/MEMORY/instructions paths, env list masked). | `UI/settings/sections/files_env.ex` | a 0644 cli.json shows the fix and the fix writes 0600; an external edit to broken JSON keeps the file and offers `e`/`d`; secret env values masked. |
| U3-13 | Import & export page (export dialog incl. *include plain MCP values*, import preview (sketch §4.15) with ticks paged from `view=task`, apply; reset everything typed `reset`). | `UI/settings/sections/import_export.ex` | only ticked rows are sent; typed confirmation required; the preview sketch text. |
| U3-14 | Notes, precommit, report. | — | — |

### 5.6 F — the finisher (8 tasks; `c74/integrate` in `/Users/zaali/dev/swarm-code-cli-wt/c74-F`)

| # | Task | Done when |
|---|---|---|
| F-1 | Merge in order `c74/S1`, `c74/S2`, `c74/U1`, `c74/U2`, `c74/U3` (`git merge --no-ff`), compiling and running the owner's c74 tests after each merge. Resolve conflicts by reading both sides; never "keep both" blindly (it has dropped `end`/`}` before). | every merge compiles with `--warnings-as-errors`. |
| F-2 | Apply every note in `/Users/zaali/.cache/c74/notes/*.md` (each as its own commit `pass74 F-2: <note>`); list the notes not applied with why. | notes list closed. |
| F-3 | Replace every remaining `Code.ensure_loaded?` fallback whose module now exists only if the fallback hides a missing wire-up; keep the `no_warn_undefined` lists minimal. Regenerate `docs/keybindings.md` and `docs/settings.md`; `--check` both. | checks green. |
| F-4 | Write `CLIT/c74_acceptance_test.exs` covering §6 items marked *test*, on the merged tree (pointing to the owner test where one already proves an item). | green. |
| F-5 | Full `mise exec -- mix precommit` in the F worktree (only the known worktree test may fail) and the PTY suites (`test_saved_session_pty.py`, `test_terminal_demo_pty.py`). | green. |
| F-6 | Sandbox acceptance (§6 items marked *sandbox*) with a release built from the F worktree (`scripts/dev/build_release.sh`), `HOME` a copy of `~/.cache/p70cli/sandbox-home` at `/Users/zaali/.cache/c74/sb/<run>` (`cp -c -R`), a loopback models stub (`python3` one-file server returning `{"data":[{"id":"stub-a"},{"id":"stub-b"}]}` on 127.0.0.1, and a `401` mode for A43), GNU screen `-L` to drive the TUI; DB checks with `sqlite3 -readonly` on the **sandbox** database only. | every sandbox item passes; the transcript files kept under `/Users/zaali/.cache/c74/sb/`. |
| F-7 | CLI repo docs: `AGENTS.md` (the settings layer, `swarmcode settings`/`config` incl. records and `secret --stdin`, cli.json 64 KB and new keys, new contexts, the settings job pool, tags), `CHANGELOG.md` pass 74 entry. | written. |
| F-8 | Report to the orchestrator: head, precommit counts, acceptance table (A-number → pass/fail/evidence), deferred items. The orchestrator (not F) merges to `main` and runs precommit in the main checkout. | — |

**Totals:** S1 17 · S2 14 · U1 19 · U2 14 · U3 14 · F 8 = 86 tasks.

---

## 6. Acceptance

*test* = an ExUnit test on the merged tree (F-4 collects them in `CLIT/c74_acceptance_test.exs` or points
to the owner test that proves it); *sandbox* = F-6 with the release, a sandbox `HOME`, GNU screen and
`sqlite3 -readonly` on the sandbox database. Canary secret: `sk-canary-7Q2X-DO-NOT-SHOW` (ends `SHOW`).

### 6.1 Reach and structure

| # | Check | How |
|---|---|---|
| A1 | `/settings`, `/config`, `/prefs`, F2, the palette's "Settings" row and `swarmcode settings` each open the layer; Esc (or `/settings` again) closes it and focus, draft text and chat scroll are exactly as before. | test + sandbox |
| A2 | Every one of the 22 sections is reachable from the rail with ↑↓ Enter, with `[`/`]`, with Ctrl-F badges, and with `/settings <section id>`; each page renders without a crash at 160×45, 120×30, 90×30 and 80×24 (a loop over `Sections.all/0` × sizes asserting a non-empty page region and no `nil` text). | test |
| A3 | Every registry entry of §2 (`length(Registry.all())`, printed by the test) appears on its section page exactly once and in search by its label, by its key and by each synonym; `/settings <key>` focuses its row. | test (loop over `Registry.all/0`) |
| A4 | Every record kind page opens from its section (provider, search provider, MCP server, pricing row, hook, profile, memory file, instructions file, command, agent definition, skill, workflow, language, storage session). | test |
| A5 | Below 80×20 the layer shows exactly `Settings needs 80 × 20; this terminal is 72 × 18. Make it larger, or use `swarmcode config` in a shell.` and Esc closes it. | test |

### 6.2 Editing, persistence, provenance

| # | Check | How |
|---|---|---|
| A6 | For every writable scalar entry (a loop): committing `entry.example` (symbolic model examples resolved against Appendix A) through the row's editor path (reducer actions, not direct calls) sends exactly one write with `expected` = the snapshot's base, the next snapshot shows the example as the winner with the entry's home layer, and reset returns the default. Session keys write the conversation row (`session.mode` the four mode columns together), project keys the projects row, global keys the settings row, cli keys cli.json, project-file keys `.swarm_code/config.json`. | test (Fake) + test (daemon `Values` on a fixture DB for DB layers) |
| A7 | **Desktop parity:** in the sandbox, set `limits.max_concurrent_agents` 6, `research.max_live` 12, `web.reader` jina, `budget.monthly_usd` 50, `storage.retention_days` 90, `desktop.mode` light, `project.approval_mode` auto, `session.mode` consensus; `sqlite3 -readonly` on the sandbox DB shows `settings.max_concurrent_agents=6`, `research_max_live=12`, `research_reader='jina'`, `monthly_budget_usd=50.0`, `storage_retention_days=90`, `mode='light'`, `projects.approval_mode='auto'`, and the conversation row `consensus=1, ultra=0, authoring_workflow=0, mode='build'`; no other column of those rows changed (compare a before/after `SELECT *` dump). | sandbox |
| A8 | Out-of-range and malformed values show the desktop's exact message (`must be between 1 and 16`, `is invalid`, `can't be blank`, `has already been taken`) under the row, write nothing and keep the typed text for correction. | test |
| A9 | Provenance: with `SWARM_THEME=light` and cli.json `"theme": "dark"`, the Theme row shows `light` with tag `env SWARM_THEME` and the line `SWARM_THEME=light wins while set · cli.json: dark`; changing it writes cli.json and the toast says SWARM_THEME still wins at the next launch. `--model M` shows on Chat model and Sub-agent model · this conversation as `flag --model`. A project file `effort` shows `SwarmCode ignores this key` and the global default stays the winner (D15, D40). `SWARM_APPROVAL=ask` and `SWARM_CONVERSATION=<uuid>` set: no row names env as the winner and every section still opens. | test + sandbox |
| A10 | Live terminal preferences: `terminal.panel`, `show_diffs`, `mouse`, `keymap`, `composer_rows`, `inspector_width`, `notice_seconds`, `diff_lines`, `wheel_lines`, `editor`, `hint_letters`, `keys` change the running session at once; `colors`, `glyphs`, `ambiguous_width`, `reduced_motion`, `accent`, `startup_conversation`, `companion` say `applies at the next launch` and take effect after a relaunch (sandbox relaunch shows the accent in the focus bar colour bytes of the screen log; `ask` opens the resume picker). | test + sandbox |
| A11 | cli.json keeps unknown keys and legacy values across writes, is 0600 after any write (a 0644 file becomes 0600), refuses a symlink, never replaces a non-JSON file, a > 64 KB file is reported, not read; `/diff` after an external `swarmcode config set terminal.theme light` keeps `light`. | test |
| A12 | Undo/redo: `u` restores the previous value with a CAS write; `U`/Ctrl-Y redoes; secrets and deletions are listed `· no undo`; a section reset is one undo step. | test |
| A13 | `swarmcode config set limits.max_agent_depth 3` then `get` prints `3 (global)`; `set terminal.panel hidden` works while the desktop app is (simulated) running and while another session holds the lease; with the lease held, `set limits.max_agent_depth 2` exits 3 with `A swarmcode session is open (<dir>); change it there with /settings, or close it first.`; `swarmcode config set provider.DeepSeek.api_key x` and `record set provider:DeepSeek.api_key x` are refused with the stdin sentence (exit 2; `ConfigCommand` recognises secret keys and fields before the unknown-key message); `--expect 2` on a changed value exits 4 with `limits.max_agent_depth changed: now 3.` | test + sandbox |

### 6.3 Conflicts and live updates

| # | Check | How |
|---|---|---|
| A14 | Open a row's editor; change the same key elsewhere (`Fake.Settings.put/3`; in the daemon test a direct `Settings.update/1`); commit → the row shows `! changed while you edited (elsewhere in this session): now X` with keep/take; keep sends `expected = X` and wins; take shows X; nothing was overwritten before the choice; a second queued commit of the same key is not sent after the conflict. | test (Fake + daemon) |
| A15 | Record CAS: deleting a provider whose `updated_at` moved → conflict; editing an MCP env value changed elsewhere → conflict on that field only. File CAS: MEMORY.md changed on disk while shown → `changed on disk · Ctrl-R reloads`, and a save conflicts with a fingerprint-only answer, then the re-read and `s`/`e`/Esc choice. | test |
| A16 | A change made by the desktop domain (`Settings.update/1`, `Providers.update/2`) while the layer is open produces one `settings_update` delta, the visible rows update within one frame of the re-query and show `changed elsewhere in this session` for 2 s; the chat header's model/effort re-project (R3). | test |

### 6.4 Secrets

| # | Check | How |
|---|---|---|
| A17 | Pasting the canary into DeepSeek's key row stores it (`providers.api_key` in the sandbox DB equals the canary — the only place it may appear), the row then shows `●●●●●●●● set · ends SHOW` and `stored in SwarmCode's database · shared with the desktop app`. | test + sandbox |
| A18 | The canary never appears in: any scene/screen (sandbox: `grep -c` over the screen log = 0), `inspect/1` of State/Layer/Request/ServiceRequest/Command/Context, the command ledger table, `cli.log` (sandbox: `grep -c` = 0), a crash report of a handler that raises while holding it (`capture_log`), toasts, undo, changelog, search results, export files, `swarmcode config list/get/records/export` output, `settings_update`/`settings_task` deltas, snapshots, task views or results (socket capture in S1-16). | test + sandbox |
| A19 | Typed characters on a secret row are ignored with the words `typing is ignored here · paste with Cmd-V · Ctrl-T types instead`; after Ctrl-T typing is accepted and not echoed; a two-line paste is refused with `the paste had 2 lines; paste only the key`; a 5-byte paste with `that is too short to be a key`; `x` asks before removing a key. | test |
| A20 | The client rejects a snapshot whose secret field is a string or has a 5-character hint, without closing the connection, and says `Couldn't read settings right now.`; a snapshot with one out-of-type scalar is kept and only that row is `invalid`. | test |
| A21 | MCP env: `GITHUB_PERSONAL_ACCESS_TOKEN`, `GH_PAT`, `STRIPE_KEY=sk_live_…` and `DATABASE_URL=postgres://u:pw@h/db` are masked, `GITHUB_TOOLSETS` shown; `s` on a shown entry masks it; `.mcp.json` import with a token shows it masked and the created server has the token (sandbox DB); `${GITHUB_TOKEN}` offers `v`/`p`/`k` and `v` stores the shell's value; an SSE entry cannot be ticked; export writes MCP env values as `<secret: set>` unless *include plain MCP values* is on. | test + sandbox |

### 6.5 Async work

| # | Check | How |
|---|---|---|
| A22 | `t` on a provider against the loopback stub shows `◷ testing the connection · N s` then `✓ listed 2 models in M ms · HH:MM`; nothing is written (the sandbox DB `providers.models` unchanged). | test + sandbox |
| A23 | A held test (stub that never answers) shows elapsed seconds, `c` cancels it (`stopped · HH:MM`, the backend task's monitor sees `:DOWN`); cancelling an MCP probe of a fixture stdio server leaves no OS process; leaving the page / closing the layer cancels the other cancellable tasks this layer started; an uncancellable storage run cannot be stopped, says so, reports `still running after N s` past its deadline and is never killed by it; quitting while it runs asks first. | test |
| A24 | Timeouts: a stub that answers after the timeout gives `✗ no answer in 15 s` (test with a shortened timeout through the TaskSpec). | test |
| A25 | Fetch models shows the difference (`+ new`, `− gone (N conversations use it)`, `unchanged N`) and writes only after `a`/`+`; `f` twice replaces the first fetch (one running task per key); a 2 500-model stub offers only `+` and `replace` is refused (D39). | test |
| A26 | MCP reconnect (`R`) waits for the status message and shows `✓ connected · N tools, K off`, or `✗ command not found: <exe>` for a bad command, also when the status arrives immediately; a disabled server answers `turn it on first`; the MCP server's scope never changes on reconnect or field edits (R7); `r` on a staged field reverts it without a request. | test |
| A27 | Storage: measure on page open; cleanup through each tab (Quick preset → review; Sessions picks with sort/filter/pick all and a pinned pick; Advanced options each re-plan) → typed `delete N` → progress → `Freed …` → the vacuum nudge; vacuum refused while a run is live; `Apply retention now` stamps the last sweep, is `busy` while a cleanup runs, and keeps the conversation the TUI has open. | test |

### 6.6 Keys

| # | Check | How |
|---|---|---|
| A28 | Rebinding `palette_open` to F5 through the capture editor writes `"keys": {"palette_open": ["F5"]}` to cli.json, F5 opens the palette at once, the footer/help/`?` print F5; `+` adds a second key; `x` removes one; `X` unbinds (`[]`, hints omit it, help says `unbound`); `/ctrl-j` lists what Ctrl-J does in every context; `settings_test` remapped to `T` works; capturing a key used elsewhere shows `<key> is taken by "<label>" in <contexts>` and `s` swaps both; Esc/Enter/arrows/Ctrl-C/F1/`?`/Ctrl-S/approval letters cannot be rebound; `Ctrl-Shift-A` is refused as unreportable; `swarmcode config reset terminal.keys` restores every default. | test |
| A29 | `docs/keybindings.md` lists the Settings chapter and `mix swarm_code.keymap --check` passes; no binding uses Ctrl-K and none is Alt-only; one binding per key and context. | test |
| A30 | The vim keymap setting switches the composer to vim modes at once and back; `j`/`k` move in settings only when vim is on. | test |

### 6.7 Rendering

| # | Check | How |
|---|---|---|
| A31 | 160×45 Overview with Appendix A data matches F1's page and rail rows (text), with the §4.1 amendments. | test |
| A32 | 90×30 Approvals & trust matches F14's structure (section strip, full-width page, 3-row drawer). | test |
| A33 | 80×24: drill-down pages (F16): sections list → section → record → sub-page, Esc goes back one level each time; every row's label is whole. | test + sandbox |
| A34 | `NO_COLOR=1`: the scene has no colour attributes, every mark still reads (`!`, `✗`, `✓`, `•`, `not saved`); `NO_COLOR=` (empty) keeps colour (D21). `SWARM_ASCII=1`: no byte ≥ 0x80 in the settings region of the scene (F15 twins). | test + sandbox |
| A35 | A 400-row page paints ≤ 4 096 nodes and only visible rows are projected; a 2 000-model list scrolls with only visible rows projected; search over 8 000 index entries answers in < 20 ms. | test |

### 6.8 Robustness and scope

| # | Check | How |
|---|---|---|
| A36 | On a fresh database (`Providers.seed_defaults/0`, `LLMOTIONS_API_KEY` unset) `swarmcode settings` opens the layer (no exit 3), the header shows `no model provider · Providers`, and Enter in the composer keeps the draft and says `No model provider can answer: llmotions has no key · F2 opens Settings › Providers` (the service refuses the dispatch too); after adding a provider with a pasted key and the stub URL and pressing `▸ Use <name> · <model> for new chats`, a send starts a run (Fake LLM in tests; sandbox stops at the provider test — no LLM call). | test + sandbox |
| A37 | An unsaved live session (`run_live_session.sh` path, LiveBackend) shows the D28 words on DB sections and edits terminal sections normally. | test |
| A38 | A settings request without the `settings` capability is never sent; an old daemon answer (`unsupported`) shows `This part of settings is not available in this build.` on the section. | test |
| A39 | Reads never insert rows: the row counts of `settings`, `search_providers`, `providers`, `mcp_servers` are unchanged after opening every section (fixture DB, also with no settings row at all). | test |
| A40 | Owned work: closing the layer or quitting leaves no settings task process (`Task.Supervisor.children/1` of the domain supervisor filtered by the backend's tasks is empty), no probe OS process and no temp file under the config dir or the project's `.swarm_code/`. | test |
| A41 | Every section works against `Fake.Settings` (+ `Fake.SettingsIntegrations`) with the daemon absent (`mix swarm_code.demo.*` unaffected) and the plain-demo golden output is unchanged. | test |
| A42 | `mix precommit` green on the merged tree (the only allowed failure in the F worktree is `locked_branch_test.exs`; green in the main checkout after the orchestrator merges). | F-5 / orchestrator |

### 6.9 Section behaviours and parity (one item per section not covered above)

| # | Check | How |
|---|---|---|
| A43 | **Key replacement tests first:** pasting a key the stub answers `401` over DeepSeek's working key leaves `providers.api_key` unchanged (sandbox DB) and shows `The new key was refused (401). s save it anyway · Esc keep the old key`; `s` saves it; a good key replaces it with `DeepSeek API key replaced · the new key listed 2 models`. Same for a search key. | test + sandbox |
| A44 | **Pricing:** put, rename and delete rows; a row with one price stays a draft; the unpriced group lists AT5's models and Enter prefills a row; the sandbox DB `settings.pricing` JSON holds the new row after a put. | test + sandbox |
| A45 | **Search & web:** enabling a key-needing engine without a key opens the paste first; `J` on Exa moves it below Brave and the sandbox DB `search_providers.position` order follows; clearing Tavily's key also turns it off with the words; test words with the plan warning; AT15 with the Firecrawl reader and no key. | test + sandbox |
| A46 | **Language servers:** `off`, a custom command and back to default write `settings.lsp_servers` (sandbox DB: key present with `"off"`, then the command, then absent); check results per row; stop; an unknown key is listed and removed. | test + sandbox |
| A47 | **Project file:** hook and profile create/edit/move/delete; unknown keys semantically preserved; invalid JSON with line and column; a new hook in a trusted project asks (structured and through an external edit); every ignored-entry reason listed and removable; after a hook reorder the engine's hook config read returns the new order. | test |
| A48 | **Library:** create a command/agent/skill from its template (tier directory 0700), delete a user file, bundled delete refused with the words, shadowing marks, workflow smoke results; a `settings` command is marked shadowed by the built-in. | test |
| A49 | **Memory & instructions:** edit and save project memory in place, clear global memory (confirm), the instructions row names the winning file (`CLAUDE.md` when it is the only one), creates `AGENTS.md` when none exists, and warns in an untrusted project. | test |
| A50 | **Budget & usage:** the by-model table with `no price` rows; a stored `12.5` budget shows the invalid row and `r` resets it. | test |
| A51 | **Desktop app:** on *Key · Toggle side chat*, capturing Ctrl-J writes `ctrl+j` and the detail's typed fallback `meta+shift+s` writes that combo; a combo already used by another action shows `conflict: <a> and <b> are both bound to <combo>`; `▸ Reset all desktop keys` writes `{}`; changing *Mode* repaints the terminal when Theme follows the desktop. | test |
| A52 | **Files & environment:** doctor's checklist; secret env values masked; `▸ Make it private` turns 0644 into 0600; an external edit of cli.json into broken JSON keeps the file and offers `e edit again · d discard your edit`. | test |
| A53 | **Import & export:** export then import onto a fresh sandbox database gives an identical values snapshot (compare `swarmcode config list --json` before and after); a 70-key import is one undo step; `▸ Reset everything…` needs the typed `reset` and leaves providers, secrets, records, sessions and projects untouched (sandbox DB row counts and `api_key` columns unchanged). | test + sandbox |
| A54 | **Approvals & trust:** raising to full access and trusting ask; untrust asks and the sandbox DB shows `projects.trusted_at` NULL and `approval_mode='read_only'`; a change of the session project's mode leaves one transcript policy notice. | test + sandbox |
| A55 | **Effort levels:** a bad body in row 3 shows `body: must be a JSON object` under row 3 (`rows[2]`); a preset replaces the rows; reset to built-in; the DeepSeek provider preset creates the `deepseek` levels. | test |
| A56 | **Provider delete:** deleting DeepSeek with replacements re-points `models.chat` and `models.sub_agent` (sandbox DB pair columns) in the same step; the only provider warns `SwarmCode will have no model to talk to until you add one`. | test + sandbox |
| A57 | **Invalid stored values (D34):** a fixture DB with `theme = "nord"` and `research_max_live = 40` opens every section; the two rows read `✗ stored value not understood`, Overview lists AT18, `r` resets each with a CAS against the raw value. | test |
| A58 | **Wire robustness:** a conflict on a 200 KB file does not crash the backend and the reply replays from the ledger; an `outcome` reply to a settings command keeps the connection open and re-queries; a deadline on a settings query and on a settings command keeps it open; a task result over 128 KiB is read page by page and no delta carries it; an oversize attribute is refused locally without a request. | test |
| A59 | **Mode:** `/plan` then opening settings shows Mode `Plan`; choosing `Ultra` in settings writes `ultra=1, consensus=0, authoring_workflow=0, mode='build'`; no settings write produces two modes at once. | test |
| A60 | **Long lists:** `/` on a provider's 312-model list filters in place with the count in the header; `/` on the empty filter opens the global search; global search for `deepseek-v4-lite` and for `create_issue` opens the owning record with the item focused. | test |
| A61 | **Headless provisioning:** on a fresh sandbox, `swarmcode config record add provider --preset deepseek`, `printf 'sk-…' \| swarmcode config secret provider:DeepSeek --stdin --no-test`, `swarmcode config set models.chat DeepSeek/deepseek-v4-pro`, `swarmcode config search enable tavily` and `swarmcode config mcp toggle github` produce the rows the TUI would (sandbox DB), and a TUI session opened afterwards can send. | test + sandbox |
| A62 | **Undo survives closing:** change a value, close the layer, reopen, `u` undoes it (and conflicts properly when the value moved meanwhile); *changed in this session* still lists it. | test |
| A63 | **Palette:** typing `mo` in Ctrl-P lists `/model` and conversations before any settings row; `>settings:theme` lists the Theme row. | test |

---

## Appendix A — fixture data (`Fake.Settings` seed and the daemon fixture helpers `c74_*`)

Session: project **ailogic** (`/Users/dev/ailogic`, id `11111111-1111-4111-8111-111111111111`, trusted,
approval `auto`, allow `["mix test", "git status", "rg", "ls", "mix format"]`); a second project
**notes** (untrusted, read-only); conversation `4f2a0000-0000-4000-8000-000000000001` titled `Refactor
the parser`, mode `build` (all four mode columns at their defaults), session effort `high`, session model
DeepSeek `deepseek-v4-pro`.

Providers (global):

| name | kind | base_url | key | models | default_model |
|---|---|---|---|---|---|
| DeepSeek | openai_compatible | `https://api.deepseek.com/v1` | `sk-test-deepseek-00000000a1b2` (hint `a1b2`) | `deepseek-v4-pro`, `deepseek-v4-flash` | `deepseek-v4-pro` |
| Anthropic | anthropic | `https://api.anthropic.com` | `sk-ant-test-000000000000c3d4` (hint `c3d4`) | `claude-sonnet-5`, `claude-opus-5` | `claude-sonnet-5` |
| Ollama | openai_compatible | `http://127.0.0.1:11434/v1` | none (local, usable) | `qwen3-coder` | `qwen3-coder` |
| OpenRouter | openai_compatible | `https://openrouter.ai/api/v1` | none (unusable) | — | nil |

Global values (changed from default): `models.chat` DeepSeek/`deepseek-v4-pro`, `models.sub_agent`
DeepSeek/`deepseek-v4-flash`, `limits.max_concurrent_agents` 6, `limits.max_agent_depth` 2,
`limits.max_agent_turns` 60, `limits.sub_agent_timeout` 30 min, `research.max_live` 12,
`web.reader` `web_fetch`, `budget.monthly_usd` 50, `storage.retention_days` nil, `desktop.mode`
`light`, `desktop.theme` default. Pricing rows: `deepseek-v4-pro` (0.27/1.10), `deepseek-v4-flash`
(0.07/0.28), `claude-opus-5` (15/75); unpriced in use: `claude-sonnet-5`, `qwen3-coder` (AT5).

Search providers: Tavily on (key `tvly-test-000000000000e5f6`), Exa on (key, hint `g7h8`), Brave off (no
key), Serper off, Jina off, Firecrawl off (no key → reader note).

MCP servers: **github** (global, stdio `github-mcp-server stdio`, env `GITHUB_PERSONAL_ACCESS_TOKEN=
ghp_test_0000000000000000i9j0` + `GITHUB_TOOLSETS=repos,issues`, status error `command not found:
github-mcp-server`), **fs** (ailogic only, stdio `mcp-fs /Users/dev/ailogic`, ready, 12 tools, 2
disabled), **docs** (global, http `https://mcp.example.test/mcp`, header `Authorization: Bearer
test-token-0000000000k1l2`, ready, 29 tools, 1 disabled).

cli.json: `{"panel": "compact", "show_diffs": false, "theme": "dark", "keys": {"palette_open":
["Ctrl-P"]}, "x-unknown": 1}`. Env: `SWARM_THEME=light`, `VISUAL=hx`. Flags: `--model
deepseek-v4-pro`.

Files: ailogic `MEMORY.md` 42 lines; global `MEMORY.md` absent; ailogic `AGENTS.md` 120 lines (the
instructions winner); notes has only `CLAUDE.md` (so its instructions row names `CLAUDE.md` and warns
`not read until you trust notes`); commands `/review` (global),
`/deploy` (project); agent definitions `scout` (user), `reviewer` (bundled, shadowed by a project
`reviewer`); skills `html-report` (project); workflows `nightly` (user, smoke ok), `broken` (project,
smoke `✗ calls System.os_time/0`). Project file `.swarm_code/config.json` (one valid hook and two
deliberately ignored entries):

```json
{"effort": "high",
 "hooks": {"post_tool_use": [{"matcher": "^edit_file$", "command": "mix format", "timeout_ms": 10000}],
           "post_edit": [{"matcher": "*.ex", "command": "mix format"}]},
 "profiles": {"fast": {"mode": "auto", "effort": "low"}},
 "x-custom": true}
```

→ `top_level: {effort}`, `ignored_entries`: `hooks.post_edit` (unknown event post_edit),
`profiles.fast.mode` (not a profile key); one runnable hook (`post_tool_use`, `^edit_file$`); unknown
key `x-custom` kept.

Storage: database 1.8 GB, 214 sessions, last cleanup 12 days before `now`; usage this month $38.20
(by model: deepseek-v4-pro $30.10, claude-opus-5 $8.10, claude-sonnet-5 `no price`).

Tasks (Fake defaults): `provider.test` DeepSeek → `{count: 2, ms: 412}`; `provider.set_key` with
`test_first` → saved, `{count: 2}` (`fail_next` makes it refuse with `401`); `provider.fetch_models`
DeepSeek → added `deepseek-v4-lite`, removed `deepseek-v4-flash` (used by 3 conversations), unchanged
1; `search.test` Tavily → 3 results 612 ms; `mcp.reconnect` github → `command not found:
github-mcp-server`; `lsp.check` → elixir installed, others not; `mcp.import.read` of the ailogic
`.mcp.json` → the three servers of the §4.15 sketch.

Other fixtures: **fresh** (A36) — an empty database after `Providers.seed_defaults/0` with
`LLMOTIONS_API_KEY` unset (one keyless llmotions provider, the chat and sub-agent defaults pointing at
it); **invalid values** (A57) — Appendix A plus `settings.theme = "nord"` and `research_max_live = 40`
written with raw SQL; **no settings row** (A39) — Appendix A with the `settings` row deleted.

Expected Overview (A31): attention `github MCP server failed to start` (AT1), `2 models in use have no
price` (AT5), `ailogic's project file has entries SwarmCode ignores` · `effort, hooks.post_edit,
profiles.fast.mode` (AT8) — in that order: errors first, then warnings, then rail order; OpenRouter
raises nothing (no default uses it; DeepSeek, the chat default, is usable, so no AT10); changed from
default: the first 9 rows then `… N more`. Layer counts are computed by the test from the fixture with
the registry's rules and must include these fixed points: flag 2 (`session.model`,
`session.sub_agent_model` — the `--model` overlay covers both), env 2 (`SWARM_THEME`, `VISUAL`),
project file 0 (the project file's `effort` is shown but ignored, D40).

---

## Critique log (revision 2)

Two critiques reviewed revision 1: a completeness review (C1–C27) and a feasibility review against the
CLI code at `fb99d0f` (B1–B3, M1–M16, m1–m18). Every blocker and major finding is fixed; the minors are
fixed unless noted. Where a fix differs from the one proposed, the reason is given.

| Id | What changed |
|---|---|
| B1 | D33; §3.3.5: file conflicts return the fingerprint only and the client re-reads (§3.7.9); §3.4.2 caps every settings_result; §3.3.10 guards below the ledger's 128 KiB raise (120 KiB) before `CommandLedger.complete/3`; test in S1-10, A58. |
| B2 | §3.3.8 rule 5 and §3.4.4: `settings_task` deltas carry state/progress/message and a ≤ 16 KiB summary, never the result; new `view=task` (§3.3.6, §3.4.2) pages results; running deltas replace each other in the watch queue; the client re-queries tasks after a resync (§3.7.3). |
| B3 | §3.4.2 rewritten on the real `result`/`response_kind` framing; the codec maps an `outcome` reply to `SettingsResult` (no close); `:settings_query` joins `fail_request/3`'s read list; one `WireBounds.valid?/2` for `valid_params?/3` and the client's `Request.validate/1` so oversize requests never reach the wire (§3.4.1, §3.6); the `Effect.validate` clause is given to S1-6 as a hand-off of `UI/effect.ex` (§3.1, §5.0). |
| M1 | §3.3.10: command jobs are never replaceable; a settings pool of 4 is checked before `CommandLedger.admit`; every settle path (DOWN, timer, terminate) completes the ledger with an `unavailable` settings_result; the job timer is `timeout_ms − 1 s`. Tests in S1-10. |
| M2 | §3.3.4 step 5 and §3.3.5: caches are invalidated again after the commit, outside the transaction (settings, projects incl. untrust, providers, search); test fills `get_cached` between write and commit. |
| M3 | §3.3.10: `UIState.opened/1` on backend init and conversation switch; §3.5.5: `apply_retention` and `vacuum` check `Storage.running?/0` and hold the `:storage_cleanup` registration, selection only from non-nil days; tests S1-10, S2-9, A27. |
| M4 | §3.3.8 rule 4: instead of backend-side await buffering, the task process subscribes to the topic **before** calling `MCP.reconnect/1` / `Storage.run/1` and waits itself (monitoring the storage pid; DOWN without a result = failed); no message can be lost, and the backend needs no await state. Non-cancellable tasks get a reporting deadline instead of ∞; reconnect of a disabled server is rejected (`turn it on first`). |
| M5 | §3.3.8 rules 3 and 8: non-cancellable tasks are never killed by a timer; `kind: :probe` tasks run under `ProbeRunner`, which reaps the OS process tree on cancel; `kind: :file` tasks trap exits, clean up in `after` and stop with `Task.shutdown(task, 2_000)`; tests in S1-9, A23, A40. |
| M6 | §3.3.2: handlers declare `cache_reads/1`; the backend copies only those entries into `ctx.task_results`; §3.3.8 rule 7: the storage sessions store lives outside the LRU (20 000 rows, 6 MiB); purge timers for secrets-bearing entries, cancelled in `terminate/2`. |
| M7 | §3.3.10: query keys include kind, id, project and an optional `slot`; superseded `:stale_revision` failures are ignored; a separate settings pool of 4; the new `open` view makes opening the layer one job (§3.3.6, §3.7.3). |
| M8 | D35; §2.2: one `session.mode` enum (build · plan · consensus · ultra · workflow) with the `{:conversation_mode}` descriptor writing the four columns via the `mode_fields/1` mapping and read in `current_mode/1` order (§3.2.2); A7, A59. Entry count 170 (three rows fewer, `terminal.diff_lines` added). |
| M9 | D11; §3.3.10: dispatch is refused when the effective chat provider is not usable, even when `effective_model` succeeds (the keyless seeded llmotions case); the workspace metadata gains `chat_provider: %{name, usable}` for the chip and words (§3.10.1, S1-11); A36 rewritten with a fresh-DB fixture and the new `Use <name> for new chats` action (§2.3), without which adding a provider would not change the refused chat default. |
| M10 | §3.10.3: lease-held words and behaviour (exit 3 for DB keys; `list`/`get` still print cli keys; cli writes still work); headless task execution; `import --apply` in one process; tests in S1-14, A13. |
| M11 | §3.8.1: the cli.json file layer moved to core as `SwarmCode.Settings.CliFile` (S1, in `c74-S1-core`); `UI.Init.Preferences` becomes U1's thin wrapper; S1-13/S1-14 use `CliFile` directly. |
| M12 | §5.0: four tags — `c74-S1-core` (after S1-4; S2 starts), `c74-S1-wire` (after S1-6), `c74-U1-api` (after U1-7: the reducer paths, minimal editors and a text-only page projector), `c74-U1-api-2` (after U1-15, the full projector); U2/U3 assert rows and requests until api-2, scene text after. The integration simulation moved from S1's Fake to U2's `Fake.SettingsIntegrations`; `Fake.Settings.stub_reply/3` serves U3. |
| M13 | D40 and §3.3.3: ignored layers carry `ignored: true` and never win (project-file effort, out-of-space env values); E removed from `project.approval_mode`; `session.sub_agent_model` gains the F layer, its write clears the override, and dynamic choices use the overlaid model (§2.2). Tests in S1-7. |
| M14 | D34, §3.3.3, §3.4.6 rule 1: integral floats normalise; out-of-contract values become `state: "invalid"` rows that stay writable and resettable; only secret-shape violations reject a whole response; AT18, A50, A57. |
| M15 | §3.3.10 and §3.11 item 3: `format_status/1` of Connection, PersistedBackend, DataSource.Daemon, SessionRuntime and the port owner redact `:message`/`:log`; Connection stores requests without the `secrets` body key and fails requests by the stored operation; `Context` holds only list-B env names and hides env/task results from `Inspect`; a raising-handler canary test. |
| M16 | §3.5.8: `Projects.broadcast/0` after every config.json write (structured, `file.save`, `remove_top_level`) so `Hooks.cached_config/1` re-reads same-size edits and reorders; test in S2-13, A47. |
| m1 | §3.3.3 reads the settings row with `Repo.one(…)`, never `Settings.get/0` (D24 extended). |
| m2 | §3.3.3 uses `Providers.effective_model(%Conversation{}, :chat)`; §2.23 `default_model` note no longer names the private `fallback/0`. |
| m3 | §3.5.4 `mcp.set_tools`: one `disabled_tools` write in the CAS transaction, one `set_tool_enabled/3` after commit to republish. |
| m4 | 100 ms coalescing, `{:settings_updated, _}`, `write_changes/3` used throughout; `UI/settings/sections/overview.ex` listed in U1's row (§3.1). |
| m5 | §3.3.9: storage progress no longer marks sections (only done/failed); conversation updates mark models_effort only when a registry-backed column changed. |
| m6 | §3.8.1: `write_changes/3` re-reads the fingerprint just before the rename and retries once (then `:busy`); §3.8.2: legacy saves send only the changed key with its last-read expectation; A11. The remaining microsecond race is documented. |
| m7 | §3.3.9 documents the desktop-started-later limitation; §3.3.3 compares `max(updated_at)` per table on every values snapshot and invalidates the matching caches. |
| m8 | §3.3.3/§3.7.3: snapshots carry the admission revision and older ones are re-queried; §3.7.6: a queued value is dropped (never auto-sent) after a conflict or rejection and shown as *mine*. |
| m9 | §3.5.9/§3.7.7: pasted secrets under 8 bytes are refused (`that is too short to be a key`); §3.3.8 rule 6 also removes shorter legacy secrets exactly. |
| m10 | Folded into C6 and C8. |
| m11 | §3.2.6: daemon-side parity tests for themes, search kinds, consensus checks, research levels, LSP defaults and changeset inclusion lists (S1-3). |
| m12 | §3.2.1: symbolic `{:model, provider, model}` examples resolved against Appendix A; `shell.path` example `/bin/sh`; A6 notes it. |
| m13 | §3.5.8 and S2-13: unknown keys are asserted semantically equal (order and nesting kept), not byte-for-byte. |
| m14 | D2, §3.10.1/§3.10.2: plain and one-shot words; the `./config` rule and help for `config`. |
| m15 | §3.12 and §5.0: c74 fixtures use `pool_size: 3`; the no-`GenServer.call`-inside-a-transaction rule. |
| m16 | §4.8: quitting while a non-cancellable task runs asks (`Q Quit anyway`); §3.3.8 rule 9 notes the interruption. |
| m17 | §2.12, §3.5.7: global memory via `Memory.file(:global, nil)`, never a hand-built path. |
| m18 | §3.7.7: `Ctrl-T type instead` in the paste context under every `caps.paste` value, never echoed; A19. |
| C1 | D36; §2.12 renamed *Memory & instructions* with the instructions file row (winner, loading facts, trust warning, create AGENTS.md); `file_kind: instructions` (§2.23, §3.4.5, §3.5.7); synonyms `agents.md`/`instructions` (§3.7.12); S2-11, U2-12, A4, A49; coverage (§2.26). |
| C2 | D39 and the single bounds table in §3.12 (models 2 000, tools 512, coalescing 100 ms, progress ≤ 4/s, attributes lists 2 048); `provider.apply_models` applies the cached fetch by `fetch_task_id` (the list never travels back); a truncated fetch refuses `replace` and offers only `add`; record field lists are bounded by each `RecordKind` field `max` (§3.4.6 rule 4) and windowed in the client. |
| C3 | §3.3.4: `values.patch` takes up to 256 changes (compile-time assert ≥ scalar count); reset-all and import use the same bound; tests in S1-7, A53. |
| C4 | §2.10: `project.approval_mode` layers `P→ D`; out-of-space env values are ignored layers (D40); A9 sets `SWARM_APPROVAL=ask` and `SWARM_CONVERSATION=<uuid>`. |
| C5 | Same fix as M14 (D34). |
| C6 | §3.2.5 `SecretPattern.secret_kv?/2`: the desktop rule OR the env-name rule OR token prefixes OR `://user:pass@`; `s` *treat as secret* (session only); export writes MCP env/header values as `<secret: set>` unless *include plain MCP values*; the client re-checks on decode; A21. |
| C7 | §3.5.1/§3.5.3: `provider.test` takes an unsaved key; `set_key` with `test_first` (the default when a key is already set) tests before writing and keeps the old key on refusal, with `s save it anyway`; §3.7.7 flow; A43. |
| C8 | §2.7, §3.5.4: `${NAME}`/`$NAME` detected with `v` shell / `p` paste / `k` literal choices (the shell value is read at apply time and never leaves the daemon before); SSE entries cannot be imported; renames for name conflicts; S2-8, A21. |
| C9 | §3.10.3: `config records`, `record get/set/add/delete`, `secret … --stdin` (stty-echo wrapper in the launcher; piped input for provisioning), `search enable/order`, `mcp toggle/reconnect`; secrets in argv refused with the stdin sentence; the lease-held words (M10's wording, which names the other session's folder); A13, A61. |
| C10 | §6.9 adds A43–A63: key replacement, pricing, search, LSP, project file, library, memory & instructions, budget, desktop app, files & environment, import/export/reset everything, approvals & trust, effort levels, provider delete, invalid values, wire robustness, mode, long lists, headless provisioning, undo after close, palette ranking. |
| C11 | §4.14 maps every frame and sketch to its owning task's scene/page-text test (F1 U1-16, F2 U1-12, F3 U3-4, F4 U2-2, F5/F6/F12 U2-4, F7 U2-7 + U3-5, F8 U2-9, F9 U3-6, F10 U3-9, F11 U3-3/U3-10, F13 U1-13, F14 U3-7, F15/F16 U1-15); new §4.15 sketches for Pricing, Project file, Library, Storage choose, Key bindings, Import preview, MCP import preview (normative, §4.0), each with a page-text test. |
| C12 | §2.18 rewritten as the one description of Storage: page text, overview line, the Quick/Sessions/Advanced tabs with the desktop's presets, controls, options and words, review, running, done with the vacuum nudge; one VACUUM label; §4.14 refers to it; U2-11, A27. |
| C13 | D8, §3.9.2, §4.1 item 12: `r` is reset/revert everywhere (on MCP it reverts a staged field or discards all staged fields); `R restart now` applies and reconnects. |
| C14 | D19, §3.9.3, §4.3, §4.15 sketch: `[]` unbinds; `+` adds a key (≤ 4), `x` removes one, `X` unbinds; `/` filters by words or key name (`bindings_for_key/2`); a context picker row (not a Tab strip — Tab stays region cycling); settings page letters are remappable while Esc, Enter, arrows, Ctrl-C, `?`/F1, Ctrl-S, approval letters and in-hint bindings stay fixed; recovery via `swarmcode config reset terminal.keys`; A28. |
| C15 | D37, §3.7.11: `/` filters lists, tables and checklists of more than 20 rows in place; `/` on an empty filter (or `:goto`) opens the global search; provider models and MCP tools are indexed per record (index bound raised to 8 000 entries); A60. |
| C16 | `A` all-on with its own binding; the §2.3 preset list (with llmotions) everywhere; one VACUUM label; one pricing column order (`in · out · cache read · cache write · context`); §4.1 item 13 for F3's groups; §4.1 item 14 and §2.6 for the tier label; `XDG_CACHE_HOME`, `TMPDIR` and `SWARM_SETTINGS_ONLY` added to §2.25. |
| C17 | Added `terminal.diff_lines` and `startup_conversation = ask`; the rest are §2.24 N13–N24 with reasons (panel width, narrow thresholds, timestamps/wrap, Enter behaviour, alternate screen, confirm quit, budget warn, log level, companion port, run-hook-once, hint leader). `log_level` and `confirm_quit` were not added: the first weakens the redaction contract, the second changes the quit ladder. |
| C18 | §3.5.8 `ignored_entries` with the reasons of the domain parser; `project_config.remove_entry`; unknown `lsp_servers` keys listed with `lsp.remove_key`; running a hook once is N23 (no engine event outside a turn); Appendix A's config.json now has one valid `post_tool_use` hook and two deliberately ignored entries. |
| C19 | §2.3: each preset names its effort preset (Anthropic → `anthropic_adaptive`, OpenAI → `openai`, OpenRouter → `openrouter`, DeepSeek → `deepseek`, the rest built-in) and the draft's create writes those levels; U2-3, A55. |
| C20 | D38: undo/redo/changelog live in `State.settings_history` for the session; reopen keeps them; A62. |
| C21 | §3.8.5: a `desktop.mode` change (local write or `settings_update`) repaints the terminal when Theme follows the desktop; A51. |
| C22 | §3.3.4: no new code — the post-commit `Projects.broadcast/0` → `schedule_refresh/1` → workspace snapshot path already drives the reducer's `note_policy_change/2`; U3-7 and A54 assert one transcript notice. |
| C23 | §3.7.2: `{:copy}` uses the runtime's existing clipboard effect (OSC 52) with a fallback toast; `{:open_folder}` runs `open`/`xdg-open` as owned work only with a display and not over SSH. A missing folder is **not** created by opening it (the desktop's `mkdir_p` is not copied: a read never writes); `n` creates the first file and its 0700 tier directory. |
| C24 | §2.21 and `CliFile.write_text/3`: a broken cli.json edit is not written (`e edit again · d discard your edit`), bad known values are warnings; §3.5.7: config.json saves diff hook commands and answer `needs_confirmation` in a trusted project until the D14 dialog confirms (§4.8). |
| C25 | AT15 (Firecrawl reader without a key), AT16 (effort not a level of its model), AT17 (search engine failed its last test); AT3/AT10 and D11 use one usable predicate that counts private hosts (`WebFetch.private_host?/1`), and `SessionConfiguration.usable?/1` is widened to it (S1-11). |
| C26 | §3.10.1: settings palette rows rank below every existing kind and per-entry rows need 2 characters or the `>settings:` prefix; commands named settings/config/prefs are marked shadowed in the Library (§2.13); A63. |
| C27 | §3.2.1/§3.2.6: `big_step` required for every numeric entry over 50 steps; Shift-←/→ (and PgUp/PgDn in an open number editor) use it (§3.7.8, §3.9.2, §4.3). |
