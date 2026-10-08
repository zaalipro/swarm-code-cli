# Lane L (fix round): A5, the live runtime uses the synced LLM

Branch `cli020/fixL` from CLI `main` `55dbe5a2`, worktree `~/dev/swarm-code-cli-wt/fix-L`.
Brief: `01_fix_round.md` L1-L3. Commits: `504459d6` (L1, L2), `449a98b6` (L3), then this file
with `cli020 L: done`. Logs: `~/.cache/ncode/cli020/fix-L/`.

## L1: the live runtime streams through `SwarmCode.Domain.LLM`

- `daemon/runtime/run.ex`: `@adapters` maps the live kinds to the synced adapters
  (`"openai"` → `Domain.LLM.OpenAI`, `"anthropic"` → `Domain.LLM.Anthropic`), so runtime
  input never selects a module and an unsaved session needs no `:llm_providers` registry
  (the launchers register it; tests do not). `config/1` turns the validated live
  `%SwarmCode.Providers.Provider{}` into a `%SwarmCode.Domain.Providers.Provider{}` row
  (`"openai"` → `"openai_compatible"`, same id, so `Domain.LLM.ProviderCaps` learns per
  endpoint for the session). The synced `{:error, kind, message}` becomes
  `{:error, message}` at the adapter call, so the run's events and canonical records keep
  their shape.
- BUGS-29 in the runtime: a `max_tokens` turn with tool calls goes on to them (a text-only
  one is still `:response_limit`); a call with `truncated: true` is reported with the
  desktop's sentence ("your call to X was cut off at the output limit (max_tokens N) before
  the arguments were complete — split the content: write the first part with write_file,
  then add the rest with edit_file"; the live tool set has no `edit_files`), never run.
- BUGS-49 in the runtime: the model operation's timer was `request_timeout_ms + 1 s`,
  which cut a healthy long stream. It is now a backstop past the largest hard cap a body
  can carry (`HTTP.hard_cap_ms(timeout, %{"max_tokens" => 128_000}) + 5 s`); the HTTP layer
  ends a stalled call at the no-progress deadline or the hard cap.
- Removed through the tooling: `lib/swarm_code/llm.ex`, the 11 `lib/swarm_code/llm/*.ex`
  and the four frozen tests `test/swarm_code/llm/{chunks,efforts,sse,tool_args}_test.exs`
  (16 ledger entries). The entries were dropped with the sync tooling's byte-compatible
  writer, `SwarmCode.Governance.ProvenanceSync.Ledger.write/2`, by
  `mise exec -- mix run --no-start --no-compile <script>` (the script, kept at
  `~/.cache/ncode/cli020/fix-L/drop_frozen_llm.exs`, loads the ledger, refuses any
  destination that still exists, and rejects the `lib/swarm_code/llm.ex`,
  `lib/swarm_code/llm/` and `test/swarm_code/llm/` destinations of the daemon app). The
  ledger diff is exactly 16 entries × 8 lines; no hash was edited by hand. `repin` has no
  removal mode and the brief forbids hand edits, so this is the smallest tooling route (no
  new task added; see "For the integrator").
- Kept: `providers/provider.ex`, the 13th frozen LLM entry. It is still called: it is the
  live runtime's validated, database-free configuration (`LiveBackend.init/1` matches it,
  `Runtime.Configuration.from_env/2` builds it, the CLI's live-session tests use it). Only
  `SwarmCode.LLM.Efforts.validate/1` → `SwarmCode.Domain.LLM.Efforts.validate/1` changed
  (same function, same shape). Repinned with `run.ex`.
- The ledger now has 287 entries: 199 under `domain/`, 70 under `priv/`, and 18 others
  (`run.ex`, `providers/provider.ex`, the 9 `tools/**` copies, their 4 tests, core
  `commands.ex`, `commands/files.ex`, `command_dispatcher.ex`).

Files outside the L row, smallest changes (the fix is impossible without them):

- `daemon/application.ex`: the `SwarmCode.LLM.ProviderCaps` child is gone (the module is
  deleted; the synced table is started by `Domain.Runtime`).
- `daemon/runtime/configuration.ex`: `Efforts.key_format/0` from the synced module (one
  line; not a ledger entry).
- `test/swarm_code/domain/llm/sse_test.exs` (mapped): its "no data line is appended" case
  read `lib/swarm_code/llm/sse.ex`, which in the CLI was the frozen copy. Recorded patch:
  it reads `lib/swarm_code/domain/llm/sse.ex`.
- Tests of the removed modules: `application_test` (its first case goes through a `Run`
  instead of the frozen `LLM.stream/2`), `run_test`/`run_sink_test` setups reset the synced
  `ProviderCaps`, `provider_config_test`'s module name, `live_transport_test` rewritten for
  the synced stack (L2), the frozen `efforts_test` ported to the synced module as
  `test/swarm_code/llm/synced_efforts_test.exs` (kind `openai_compatible`; all its cases
  pass unchanged otherwise; the desktop's own test needs its database).

## L2: every CLI-specific behaviour of the frozen copies, and what became of it

Found by diffing each frozen file against its recorded upstream (`fb1b4ff8`) and by the
frozen copy's own CLI test (`live_transport_test.exs`, 22 cases). Kept behaviours are
recorded patches (`provenance/patches/apps/swarm_code_daemon/lib/swarm_code/domain/llm/
{http,anthropic,openai}.ex.diff`, written by `mix swarm_code.provenance.sync --ref
7b8f379f…`), each with a test in `apps/swarm_code_daemon/test/swarm_code/llm/
live_transport_test.exs` (LT) or `…/daemon/runtime/run_synced_llm_test.exs` (RS).

| # | Frozen behaviour (file) | Synced had it? | Decision, where | Test |
| --- | --- | --- | --- | --- |
| 1 | Owned transport: the request runs in a monitored process, the caller relays every chunk to its `into` callback (callbacks, progress keys and `on_event` stay in the caller) and stops waiting at the deadline itself on the monotonic clock, so a silent socket or silence after a keep-alive ends exactly at the deadline; a guardian kills the transport when the owner dies; a raising callback closes the socket (`http.ex`) | no: Finch's `receive_timeout` restarts per chunk and is floored at 1 s, so silence ran up to one `receive_timeout` past the deadline | **kept** (`http.ex` `owned_request/4`), adapted to BUGS-49: the owner waits until `min(last progress + idle, hard cap)`. BUGS-50's pool-timeout rescue moved into the transport process; any other exception there is re-raised in the caller as before | LT "an idle stream observes a short call deadline", "a keep-alive chunk cannot restart the no-progress deadline", "transport relays callbacks on the caller and closes its socket if a callback raises", "cancelling the stream owner closes the socket and prevents retries"; RS BUGS-49 stalled (ends in 400..900 ms, socket closed), BUGS-50 |
| 2 | One deadline per provider call across its re-attempts (`HTTP.with_deadline/2` around `Anthropic.stream/2`, `OpenAI.stream/2`) | no: each `stream_post` started a new clock | **kept** as `HTTP.with_call_clock/1`, wrapped by both providers' `stream/2`: every attempt of the call shares the first one's start and hard cap; each attempt keeps its own idle window (BUGS-49's rule) | LT "semantic effort fallback shares the original deadline" (with `max_tokens: 1` the cap is the deadline) |
| 3 | Absolute deadline: a stream still producing is cut at `deadline_ms` | – | **superseded** by BUGS-49 (no-progress bound + hard cap of 40 ms per `max_tokens`), which the brief asks for | RS "a stream that keeps producing outlives its idle deadline" |
| 4 | `receive_timeout` floor 1 ms, connect timeout ≤ the deadline (`http.ex`) | 1 s floor, pool connect 15 s | **subsumed** by 1 (the owner's deadline fires first); the synced floor stays | as 1 |
| 5 | Response byte ceiling while reading, `:llm_max_response_bytes` (16 MiB) for the stream (an unterminated SSE event included) and for model listing | no | **kept** (`http.ex` `bounded/2` wraps the synced `into`, untouched; `get_json/3` reads into `Chunks` with the ceiling) | LT "the streaming response has a byte ceiling, including unterminated SSE", "model listing bounds oversized JSON responses" |
| 6 | The request's own credentials (`authorization`/`x-api-key`) redacted from an error body before the 300-character snippet is cut, at any length; a body that reached the 64 KiB retention cap is omitted, not rendered (`http.ex`) | no: regex redaction only, and the providers redacted the key after the cut (a 10-character prefix leaked) | **kept** (`http.ex` `credentials/1`, `error_body/1`, new public `redact_key/2`) | LT "oversized error bodies cannot expose a credential prefix at the retention boundary", "error redaction precedes snippet truncation and includes short API keys", "401 is not retried and error bodies cannot echo credentials" |
| 7 | Model-listing errors redacted with the exact key (`anthropic.ex`, `openai.ex` `list_models/1`) | no | **kept** in `http.ex` `get_json/3` (one place for both providers) | LT "model listing redacts an arbitrary echoed credential" |
| 8 | Short keys redacted too (`redact/2` filtered `> 0`, the desktop `>= 8`) | no | **kept for provider keys only**: `HTTP.redact_key/2` (any length) in `http.ex` and in the providers' own redaction (`anthropic.ex` `redact/2`, `openai.ex` `settle_error/3`). `redact/2` keeps the desktop's 8-byte floor (MCP flags like `1` are not secrets) | LT "error redaction precedes snippet truncation and includes short API keys" (key `tiny`) |
| 9 | `redirect_log_level: false` (Req logs a redirect's `location`, query included) and a cross-origin refusal logged without its target (`http.ex`) | no: Req's debug line, and the target `scheme://host:port` in the warning | **kept** (`http.ex` `request/1`, `guard_redirect/1`) | LT "credentialed same-origin redirects never log secret query values", "a refused cross-origin redirect logs neither the target host nor its port" (new) |
| 10 | Model listing on the owned transport with a 30 s absolute deadline | no (`receive_timeout` only) | **kept** with 1 and 5 | as 1, 5 |
| 11 | A non-JSON SSE event fails the call instead of being dropped (`anthropic.ex`: `invalid_response`; `openai.ex`: `put_error`) | no: silently ignored | **kept**, narrowed: a blank `data:` (no content to lose) is still ignored; Anthropic keeps the first error | LT "malformed event JSON before terminal marker fails instead of silently losing content" |
| 12 | Static provider dispatch (`llm.ex`), no `:llm_providers` registry | registry in app env | **kept in `run.ex`** (`@adapters`); the synced facade keeps its registry for saved sessions | every RS case (no registry is set there) |
| 13 | `stream/2` refuses a missing provider, a blank model, a non-positive deadline (`llm.ex`) | no | **kept in `run.ex`** (unchanged `config/1`: provider through `Provider.new/1`, model 1..1024 bytes, `request_timeout_ms` 1..600 000) | `run_test` "invalid run settings and prompt configuration refuse before starting work" |
| 14 | Kind `"openai"` in the effort defaults/presets (`efforts.ex`), app `:swarm_code_daemon` in `request.ex`'s `compile_env` | – | **not needed**: the runtime maps the kind to `"openai_compatible"`; the synced request resolves the deadline at call time | – |
| 15 | `chunks.ex`, `provider.ex`, `provider_caps.ex`, `result.ex`, `sse.ex`, `tool_args.ex` | identical to upstream at the pin (0 CLI lines) | nothing to keep | – |

The patches change the synced stack for saved sessions too (`Domain.Engine` streams
through the same adapters): they now also get the exact deadline, the shared hard cap, the
16 MiB ceiling, exact-key redaction, the quiet redirect logs and the malformed-event
failure. QA should watch a real provider for the last one (a provider that sends a
non-JSON `data:` line mid-stream now fails the turn; blank lines are still ignored).

Watched failing first: on the unpatched synced stack (the three files checked out from
`55dbe5a2`) LT had 11 failures of 23 (`l2-before.log`), covering rows 1, 2, 5, 6, 7, 8, 9
and 11 (the other 12 cases, among them "401 is not retried…", the callback relay and the
owner-cancel case, pass on both and are regression guards); with the patches 23/23
(`l2-after.log`). The frozen file had 22 cases; the 23rd is the cross-origin redirect log.

## L3: the fixes through the live runtime (`run_synced_llm_test.exs`, 9 cases)

All drive `Daemon.Runtime.Run` against `SwarmCode.Test.LoopbackHTTP` (127.0.0.1 only), with
`:llm_retry_sleep` stubbed so backoff does not slow the suite:

| Fix | Case |
| --- | --- |
| BUGS-28 | a request retried after a 500 resends exactly the body it sent (byte-equal) |
| BUGS-28 | a rejection a sibling already learned (the handler records "no effort" in `ProviderCaps` before answering the 400) still gets this request's one retry, without `reasoning_effort` and otherwise equal |
| BUGS-29 | a `write_file` call cut off at `finish_reason: "length"` is reported to the model ("cut off at the output limit … split the content"), no file is written, the run completes |
| BUGS-49 | headers, one keep-alive, then silence: the run fails "gave up after" between 400 and 900 ms with `request_timeout_ms: 400`, and the socket is closed |
| BUGS-49 | 20 deltas 100 ms apart (2 s) against a 500 ms no-progress bound complete in full (the old `timeout + 1 s` operation timer would have cut it) |
| BUGS-50 | a size-1 Finch pool (`:llm_finch`, `:llm_pool_timeout` 50 ms): the second run's checkout times out, is retried as `network`, and both runs complete |
| BUGS-51 | model `m-one` refuses effort `high` by value: one retry with the default (`medium`) and the retry reason "effort high not supported by m-one; used default (medium)"; its next run starts at `medium`; model `m-two` still sends `high` |
| BUGS-52 | `o-fixture` refuses `max_tokens`, then `temperature`: retried with `max_completion_tokens` (same value), then without `temperature`; the model's next run sends exactly `max_completion_tokens` |
| BUGS-77 | `reasoning_content` goes back on the assistant message inside the tool loop; a server that refuses it is asked once without it, and only that model is remembered |

Watched failing first, on the frozen runtime at `55dbe5a2` (`l3-before.log`): 7 of 9 failed
(BUGS-29, 49 producing, 50, 51, 52, 77, and 28-sibling). The 28-sibling failure there came
from capabilities the frozen 51 case left in the frozen table, so it was re-run alone
against the frozen runtime with the frozen `ProviderCaps` (`l3-28b-frozen.log`): the run
failed with the 400, which is BUGS-28. The two that passed on the frozen runtime are
regression guards: the exact resend after a 500 (the frozen copy did that too) and the
stalled stream (the frozen absolute deadline also ended it). With L1/L2: 9/9.

## For the integrator

AGENTS.md (the integrator's file), two edits:

1. The provenance paragraph (line 197): "the live-runtime copies `lib/swarm_code/{llm,tools}`"
   becomes "the live-runtime copies `lib/swarm_code/tools`, `providers/provider.ex`", and add
   after the repin sentence: "A frozen copy that nothing calls any more is deleted and its
   entry dropped with the sync tooling's writer
   (`SwarmCode.Governance.ProvenanceSync.Ledger.load/1` + `write/2` from `mix run --no-start`),
   never by hand; `verify` and `sync --check` must pass after."
2. Replace the "13 frozen `dmn/llm/**` entries" bullet (line 354) with:
   "- The live runtime (`Daemon.Runtime.Run`, unsaved sessions) streams through the synced
   `SwarmCode.Domain.LLM` adapters (cli020 fix L, A5), chosen by the live kind in `Run`
   (`openai` → `OpenAI`, `anthropic` → `Anthropic`; no `:llm_providers` registry needed);
   `SwarmCode.Providers.Provider` stays its database-free configuration and becomes a synced
   provider row in `Run`. The frozen `lib/swarm_code/llm/**` copies are gone. Their CLI
   behaviours are recorded patches on `domain/llm/{http,anthropic,openai}.ex`, kept on every
   sync: the owned transport (the no-progress deadline and the hard cap are exact on a silent
   socket), `HTTP.with_call_clock/1` (one hard cap per provider call), the
   `:llm_max_response_bytes` ceiling (16 MiB) while reading, `HTTP.redact_key/2` (the request's
   key at any length, before the snippet is cut), no redirect URL or host in the logs, and a
   non-JSON SSE event fails the call (`notes/fix-L.md`)."

Merge notes: `provenance/extracted-files.json` changes here (16 entries dropped; `run.ex`,
`providers/provider.ex` repinned; the three `domain/llm` files and the mapped
`domain/llm/sse_test.exs` re-recorded by `sync`). If another lane's merge conflicts in it,
re-run `mix swarm_code.provenance.sync --ref 7b8f379f5ed5976a191c08708af824d10b919633`, the
repin of the union of frozen paths, and the drop script if the dropped entries come back.
No other lane's row was touched; `dmn/daemon/service/live_backend.ex` (S) still matches
`%SwarmCode.Providers.Provider{}` and needs no change.

Stale words outside the row (not changed): `apps/swarm_code_cli/lib/swarm_code_cli/ui/
data_source/dto/run_summary.ex:52` mentions `SwarmCode.LLM.Error` in a comment (the module
is `SwarmCode.Domain.LLM.Error`; there never was a frozen one).

## Assumptions

- Verified (read the code): only `Run`, `Daemon.Application`, `Runtime.Configuration`,
  `Providers.Provider` and tests called the frozen `SwarmCode.LLM*` modules; the release and
  the live launcher register `:llm_providers` themselves, the test config does not.
- Verified: `Domain.Runtime` (started by `Daemon.Application`) runs the synced
  `ProviderCaps`, `Cache`, `PubSub` and the LLM Finch pool, so the synced stack's rate-limit
  capture and caps work in the live runtime and in tests.
- Verified: the "13 frozen LLM entries" are A's rows 2-14 (`llm.ex`, 11 `llm/**`,
  `providers/provider.ex`); the 4 frozen LLM tests are separate entries (rows 24-27).
- Verified: the synced `redact/2` 8-byte floor is a deliberate desktop rule used by MCP and
  the settings service (which redact short secrets themselves), so it was not changed.
- Guessed (not measurable here): 16 MiB is enough for any real streamed answer (128 K tokens
  of SSE is a few MB); it is the frozen copy's value.
- Guessed: no real provider sends a non-blank, non-JSON `data:` line inside a healthy
  stream; if one does, the turn now fails with "invalid JSON in SSE event" (row 11).
- Guessed (not measured): whether the BEAM monotonic clock stops while macOS sleeps (the
  brief's "suspend-aware"). The transport uses `System.monotonic_time/1` exactly as the
  frozen copy did, so the behaviour is unchanged either way.

## Gates (all ran, worktree `fix-L`)

- `mise exec -- mix format` (clean), `mix compile --warnings-as-errors` (no warnings).
- Focused, after the last code change: `domain/llm`, `llm`, `run_synced_llm_test` 63/0
  (`focused-3.log`); before it: the daemon live path (`domain/llm`, `llm`, `application`,
  `daemon/runtime`, `live_backend`, `tools`) 207/0 (`focused-2.log`), and the CLI live path
  (`c74_acceptance`, `plain/live_session`, `release_umask`, `ui/data_source/
  library_service`, `runtime_service`) 17/0 (`focused-cli-1.log`).
- `mix swarm_code.provenance.sync --ref 7b8f379f…` (16 patched files: the 3 new
  `domain/llm` patches and the mapped `domain/llm/sse_test.exs` patch, plus 12 recorded before this lane),
  `repin` of `run.ex` and `providers/provider.ex`, `provenance.verify` ("provenance
  verified"), `sync --check` ("every synced file derives from the pinned commit").
- Full `env -u MIX_QUIET mise exec -- mix precommit` under suite slot `RUNNING L
  2026-10-08T10:13:59` (the only line then; released at the end): EXIT=0. core 208/0,
  daemon 1419/0, CLI 10 properties + 3050 tests/0, provenance verified, sync check, drift
  none (`precommit-1.log`). No load flake to record. The log's `redefining module …
  Migrations…` lines are runtime migrator noise that other lanes' precommit logs carry too
  (`cli020/A/precommit.log` 2088, `cli020/fin/precommit-1.log` 3480), not compile warnings.
