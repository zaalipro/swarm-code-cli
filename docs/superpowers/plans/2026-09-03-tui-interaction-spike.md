# Fake-Backed Renderer-Neutral TUI Interaction Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a fake/demo-only, renderer-neutral terminal interaction lab that proves SwarmCode's asynchronous workspace UX, permanent plain/degraded surfaces, exact cell output, terminal restoration, and the four-target ExRatatui 0.13.0 go/no-go decision without opening IPC, FoundationGate, Repo, or user data.

**Architecture:** Pure `SwarmCodeCLI.UI` types, editor, reducer, and projector own all presentation state; a bounded client-side `DataSource.Fake` attaches to a separately owned deterministic `Fake.Source`, and `SessionRuntime` applies every semantic action before coalescing paints. ExRatatui is an isolated renderer adapter only: it receives immutable `Scene` values, returns renderer-neutral input/cell frames, and is replaceable without changing state or commands. A single supervised terminal owner controls the local adapter lifecycle, while plain output consumes normalized deliveries rather than serialized screens.

**Tech Stack:** Erlang/OTP 28.4.2, Elixir 1.18.4-otp-28, ExRatatui exactly 0.13.0 with Ratatui 0.30/Crossterm 0.29 and `unicode-width` 0.2.2, ExUnit, StreamData exactly 1.4.0, deterministic JSON cell goldens, Python 3 standard-library PTY acceptance driver, and target-native Mix releases with bundled ERTS.

**Spec:** `docs/superpowers/specs/2026-09-03-tui-interaction-contract.md`

## Global Constraints

- Work only in `/Users/zaali/dev/swarm-code-cli-worktrees/tui-interaction-spike` on `feature/tui-interaction-spike`; do not edit `/Users/zaali/dev/swarm-code`.
- Execute tasks strictly in order with one implementer at a time. Give every task an independent spec-compliance review and code-quality review before starting the next task.
- This milestone is visibly and textually labeled `FAKE DEMO — NO USER DATA`. It is not Phase 2, daemon readiness, persistence, IPC correctness, cross-repository parity, an installer, or a usable SwarmCode release.
- Packaging evidence uses target-native `mix release` with bundled ERTS. Burrito and any self-extracting production wrapper are outside this plan and forbidden as renderer-feasibility evidence.
- `swarm_code_cli` may depend on stable `swarm_code_core` protocol types, but never on `swarm_code_daemon`. No CLI module may start or call FoundationGate, Repo, migrations, scheduler, MCP, database-path resolution, Unix-socket IPC, Git, provider, workflow, or research execution.
- The fake source is deterministic and separately owned so a client can detach and reconnect while its three scripted run states continue. It never writes a database, project, configuration, credential, draft, or user-state file.
- Renderer structs, ExRatatui events, NIF resources, Rustler types, and renderer framework state are confined to `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/` and matching tests/support. They never enter Scene, Action, reducer state, DataSource DTOs, core protocol values, JSON fixtures, or plain output.
- Pin `{:ex_ratatui, "== 0.13.0"}`. The expected Hex package checksum is `5b9a488a8b895b06cef782ba47effd3a7e03a675d0f44d70277349ad70326671`, and the expected outer checksum is `0448833a5de5aed13fb480f57278deefe1ca3ff62af0d32e64515f4af674c030`.
- Attest the executable Hex package as primary. Record annotated tag object `e47964edac37e776ee8c43bd53241083b0aa8813` and source target `aa68bfc36016d90d6b1317f1f5edc8c4a6f9d045`, while documenting that the tag still contains v0.12 checksums and cannot supply the v0.13 precompiled path. Assert the package's unexpected 5,011,440-byte `native/ex_ratatui/erl_crash.dump` enters neither repository source archives nor assembled releases.
- Treat the renderer audit as a constraint, not a defect to hide: ExRatatui 0.13.0 TextInput/Textarea edit Unicode scalars and fragment combining marks, ZWJ emoji, and flags; the neutral grapheme editor is authoritative and the adapter renders it with Paragraph/rich spans only. The published aarch64 Linux GNU NIF imports GLIBC_2.39 `pidfd_spawnp`/`pidfd_getpid`, so Ubuntu 22.04 builds must force a target-native source NIF against glibc 2.35 or reject ExRatatui. On Darwin, ExRatatui's normal SIGTERM restoration can leave `PENDIN` changed, so the outer owner must restore the exact pre-init `stty -g` state after the native restore and the four-target lifecycle gate must prove it.
- ExRatatui/Crossterm materializes an entire bracketed paste as a Rust `String` and then a BEAM binary before adapter validation. The reducer-facing 262,144-byte limit remains defense in depth, but it does not satisfy bounded-while-reading. Exact-0.13.0 evidence must prove a preallocation bound in the selected artifact or mark the dimension failed; absent that proof, the decision rejects in-process ExRatatui rather than claiming the post-allocation check is sufficient.
- ExRatatui CellSession omits physical cursor position and underline color. The theme never uses colored underline. Cell goldens record the neutral semantic cursor, while a separate fixed-enum cursor-sequence test and real PTY capture prove physical cursor placement; inability to prove both is rejection.
- The renderer-neutral width implementation is a licensed Elixir port of the exact `unicode-width` 0.2.2 algorithm/tables used by ExRatatui 0.13.0. Pin crate checksum `b4ac048d71ede7ee76d585517add45da530660ef4390e49b098733c6e897f254`, upstream commit `9d98411769fe13c7c18cab0b3fbbab29ba8350ea`, and Unicode 17.0.0; preserve MIT/Apache-2.0 notices.
- IDs are binaries. Decoded or runtime input never creates atoms. Unknown renderer codes/modifiers and unknown fake operation strings are rejected through closed compile-time tables.
- Scene text and plain content contain only `SafeText`. External content is bounded before expansion, invalid UTF-8 is made visible, and terminal controls/bidi/standalone deceptive zero-width characters are exposed inertly. The renderer never sets a terminal title from project or conversation content.
- The pure reducer performs no clock, UUID, process, terminal, filesystem, Git, network, Repo, or daemon work. Fixed clock/UUID values enter through initialization or explicit actions.
- Semantic deliveries are applied in order and never paint-coalesced away. Only redraws are coalesced. Page windows, overscan, queues, mailboxes, paste, escaped output, undo history, and layout caches are bounded by count and bytes without silently dropping canonical fake content.
- The permanent options are `--plain`, automatic plain for non-TTY/`TERM=dumb`, `--no-alt-screen`, `--ascii`, `--no-color`, `NO_COLOR`, and `--reduced-motion`. ASCII changes trusted chrome only; it never transliterates external Unicode.
- Mouse is disabled by default. Every mouse action, if enabled for the gate, has the same keyboard and switcher/action-menu route. OSC 8 and OSC 52 are not emitted in this spike.
- Tests use task-owned temporary roots, `start_supervised!/1`, monitors, messages, deterministic barriers, and virtual-clock steps. Do not use `Process.sleep/1`, liveness polling, the real development database, or the user's terminal/session state outside the PTY harness.
- Authoritative commands use `mise exec --`. Each task starts RED, finishes with its focused suite, and commits. The milestone ends with two clean-noise `mise exec -- mix precommit` runs.
- Renderer promotion requires passing native results on macOS 14 arm64, macOS 14 x86_64, Ubuntu 22.04 arm64, and Ubuntu 22.04 x86_64. Rosetta and QEMU are diagnostic only; one failed target rejects adoption, and missing evidence cannot be recorded as a pass.
- No browser smoke test applies to this terminal-only plan. If a later web surface needs acceptance, use ego-lite in a dedicated space and close only that space without clearing sessions, cookies, local storage, or browser data.

---

## Locked File and Responsibility Map

```text
mix.exs
  Test-environment precommit selection and the fake-only Mix release.

apps/swarm_code_cli/mix.exs
  Exact renderer/test dependencies, application module, and test support path.

apps/swarm_code_cli/lib/swarm_code_cli/application.ex
  Idle-by-default application boot and explicit fake-demo boot only.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{size,input,action,effect,renderer}.ex
  Closed renderer-neutral contracts; no framework structs or arbitrary payload maps.

apps/swarm_code_cli/lib/swarm_code_cli/ui/scene*.ex
  Stable Scene, Region, Dialog, Cursor, block union, and ActionTable values.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{safe_text,width,capabilities,theme}.ex
  Inert text, exact cell measurement, terminal feature policy, and Carbon mappings.

apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source*.ex
  Client boundary, closed Watch/Request/Delivery types, DTOs, DataBridge, and conformance checks.

apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/fake*.ex
  Client adapter plus separately owned deterministic three-run source and explicit barriers.

apps/swarm_code_cli/lib/swarm_code_cli/ui/editor*.ex
  Grapheme zipper, selection, undo/redo, scroll, and bounded paste/edit operations.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{draft,state,reducer,scroll}.ex
  Process-local drafts and pure presentation state transitions.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{layout,projector,fixtures}.ex
  Breakpoint classification, exact rectangles, Scene projection, and fixed representative scenes.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{keymap,switcher,activity,question}.ex
  Input priority, discoverability layers, Activity ordering, and revisioned question behavior.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{session_runtime,effect_runner,terminal_owner,launcher_control,ui_supervisor}.ex
  Ordered runtime, effect settlement, one terminal owner, signals, and owned shutdown.

apps/swarm_code_cli/lib/swarm_code_cli/plain/{options,presenter,command}.ex
  Permanent append-only accessible surface and deterministic line commands.

apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/
  The only ExRatatui/Rustler boundary: event normalization, widget mapping, cell capture, local host.

apps/swarm_code_cli/lib/swarm_code_cli/demo/
  Explicit fake-only composition root and finite/native acceptance scripts.

apps/swarm_code_cli/test/fixtures/
  Adversarial text, upstream width vectors, fixed fake script, and 69 exact cell frames.

third_party/unicode-width-0.2.2/
  Exact licensed source inputs and attestation for the renderer-neutral width port.

scripts/acceptance/tui_*.{py,sh,exs}
  PTY, performance/soak, native dependency inspection, release smoke, and evidence validation.

.github/workflows/tui-renderer-native.yml
  Four native target jobs and a non-promoting evidence aggregator.

docs/evidence/tui-renderer/ and docs/decisions/tui-renderer.md
  Immutable target observations and the objective adopt/reject/incomplete result.
```

The renderer-neutral implementation is production-shaped, but `Demo` and `DataSource.Fake` remain explicitly fake. No later task may bridge them to `swarm_code_daemon` as part of this plan.

---

### Task 0: Scaffold, Commit, and Push the Native Infrastructure Preflight

**Files:**
- Create: `scripts/acceptance/tui_infrastructure_preflight.sh`
- Create: `scripts/acceptance/tui_preflight_dispatch.sh`
- Create: `scripts/acceptance/tui_infrastructure_validate.exs`
- Create: `scripts/acceptance/tui_manual_evidence_verify.sh`
- Create: `.github/workflows/tui-infrastructure-preflight.yml`
- Create: `governance/tui-evidence-allowed-signers`
- Create: `docs/evidence/tui-renderer/infrastructure.schema.json`
- Create: `docs/evidence/tui-renderer/manual-observation.schema.json`
- Create: `apps/swarm_code_cli/test/fixtures/evidence/infrastructure-valid.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/infrastructure_schema_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/preflight_dispatch_test.exs`

**Interfaces:**

```text
tui_infrastructure_preflight.sh --target TARGET --expected-sha SHA --output FILE
tui_preflight_dispatch.sh --ref REF --expected-sha SHA --deadline-seconds 900 --output-dir DIR
tui_infrastructure_validate.exs INFRASTRUCTURE.json MANUAL_OPERATORS.json
tui_manual_evidence_verify.sh RECORD.json RECORD.json.sig ALLOWED_SIGNERS
```

- Workflow has four exact native labels and required `workflow_dispatch` input `expected_sha`. Each job first asserts `GITHUB_SHA == expected_sha`, then proves OS/architecture is native, supported baseline, tools/PTYS/resources/offline-test capacity. It uploads a bounded record even on failure. Dispatch calls `gh api --paginate repos/{owner}/{repo}/actions/runners`, bounds combined JSON to 1,048,576 bytes, and requires one `status: online` native runner containing every label in each exact set. If API authorization fails, a label set is absent, or every matching runner is offline, it writes schema-valid incomplete evidence without dispatch.
- After dispatch, the script finds only a workflow_dispatch run with exact head SHA and input, polls the Actions run API with five-second owned intervals against one monotonic/absolute 900-second deadline, and bounds every response/log. On expiry it calls `gh run cancel RUN_ID`, observes cancelled/completed for at most 60 additional seconds, records unresolved cancellation if necessary, and exits. It never uses open-ended `gh run watch`; final incomplete/failed evidence retains run URL/ID.
- Schemas distinguish automated PTY capacity from GUI/manual emulator capacity. Allowed-signers contains public SSH keys only and may initially be empty; missing public operators produces incomplete, never a request for or storage of private keys.
- Manual record schema includes target/commit/operator fingerprint/emulator/version/context/color/Unicode/motion/alt mode/commands/timestamps/stty/output hashes/facts and signed namespace `swarm-code-tui-evidence`.

- [ ] **Step 1: Write RED schema/script tests**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/infrastructure_schema_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/preflight_dispatch_test.exs
```

Expected: FAIL because scripts/schemas/workflow do not exist.

- [ ] **Step 2: Implement and locally validate scaffolding**

Reject unknown targets, mismatched expected SHA, emulation, absent PTY, undersized disk/RAM/job duration, missing inspection tools, and malformed signing records with static diagnostics. Dispatch tests inject a fake `gh` executable covering missing authorization/labels/offline runner, exact dispatch, mismatched run, deadline cancellation, cancellation timeout, and bounded-output overflow. Mark every shell script mode `0755`.

- [ ] **Step 3: Run GREEN, commit, and push the exact workflow commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/infrastructure_schema_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/preflight_dispatch_test.exs
chmod 0755 scripts/acceptance/tui_infrastructure_preflight.sh scripts/acceptance/tui_preflight_dispatch.sh scripts/acceptance/tui_manual_evidence_verify.sh
git add scripts/acceptance/tui_infrastructure_preflight.sh scripts/acceptance/tui_preflight_dispatch.sh scripts/acceptance/tui_infrastructure_validate.exs scripts/acceptance/tui_manual_evidence_verify.sh .github/workflows/tui-infrastructure-preflight.yml governance/tui-evidence-allowed-signers docs/evidence/tui-renderer/*.schema.json apps/swarm_code_cli/test
git commit -m "ci: scaffold native TUI preflight"
git push -u origin feature/tui-interaction-spike
```

Expected: the remote feature branch contains the workflow at the exact pushed commit before any dispatch.

---

### Task 1: Run the Exact Preflight and Commit Truthful Capacity Evidence

**Hard infrastructure gate:** Renderer-specific Tasks 16-27 require four native build/PTY runner passes and named public-key operators for every emulator lane. Neutral/fake-backed Tasks 2-15 may proceed when this evidence is incomplete; milestone status then remains `INCOMPLETE — renderer not selected`.

**Files:**
- Create from downloaded workflow records: `docs/evidence/tui-renderer/infrastructure.json`
- Create from public operator registration: `docs/evidence/tui-renderer/manual-operators.json`

**Interfaces:**
- Consumes the exact workflow/schemas at Task 0's pushed commit.
- Produces one aggregate with `complete | incomplete`, never inferred pass.

- [ ] **Step 1: Dispatch against the exact remote commit**

```bash
expected_sha=$(git rev-parse HEAD)
test -z "$(git status --short)"
test "$(git rev-parse origin/feature/tui-interaction-spike)" = "$expected_sha"
download_dir=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-preflight.XXXXXX")
scripts/acceptance/tui_preflight_dispatch.sh --ref feature/tui-interaction-spike --expected-sha "$expected_sha" --deadline-seconds 900 --output-dir "$download_dir"
```

Expected: downloaded records all name `expected_sha`; a missing runner gives a truthful incomplete/failure record.

- [ ] **Step 2: Aggregate runner facts and public operator inventory**

Copy only bounded secret-free records. `manual-operators.json` references allowed public-key fingerprints and lane assignments; it never contains or requires private keys. If a lane/operator is unavailable, list it in `missing_lanes`.

- [ ] **Step 3: Validate and commit evidence**

```bash
mise exec -- elixir scripts/acceptance/tui_infrastructure_validate.exs docs/evidence/tui-renderer/infrastructure.json docs/evidence/tui-renderer/manual-operators.json
git add docs/evidence/tui-renderer/infrastructure.json docs/evidence/tui-renderer/manual-operators.json
git commit -m "docs: record TUI infrastructure capacity"
```

Expected: validator exits zero for schema/integrity even when status is explicitly incomplete. Only `complete` unlocks renderer tasks; neutral tasks remain executable either way.

---
### Task 2: Make the Root Precommit Command Use the Test Environment

**Files:**
- Modify: `mix.exs`

**Interfaces:**
- Produces: `SwarmCodeCLI.MixProject.cli/0 :: keyword()` returning exactly `[preferred_envs: [precommit: :test]]`.
- Preserves: current `precommit` alias order and the existing 274-test foundation baseline.

- [ ] **Step 1: Capture the current RED result**

Run:

```bash
mise exec -- mix precommit
```

Expected: FAIL because `mix test` is reached in the `dev` environment. Record the exact message in the task report.

- [ ] **Step 2: Add the root CLI environment callback**

Add beside `project/0`:

```elixir
def cli do
  [preferred_envs: [precommit: :test]]
end
```

Do not set `MIX_ENV` inside the alias and do not reorder the alias.

- [ ] **Step 3: Run GREEN twice**

```bash
mise exec -- mix precommit
mise exec -- mix precommit
```

Expected both times: PASS in `MIX_ENV=test`, 79 core tests and 195 daemon tests, provenance verified, with no TLS/logger noise.

- [ ] **Step 4: Commit**

```bash
git add mix.exs
git commit -m "build: run precommit in test environment"
```

---

### Task 3: Define Compile-Green SafeText, Size, and Capability Primitives

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/size.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities/probe.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/primitives_test.exs`

**Interfaces:**

```elixir
Size.new(pos_integer(), pos_integer()) :: {:ok, Size.t()} | {:error, :invalid_size}
SafeText.chrome(:fake_banner | :empty | :main | :help | :detach | :plain) :: SafeText.t()
SafeText.value(SafeText.t()) :: binary()
Capabilities.explicit(Size.t(), keyword()) :: Capabilities.t()
```

- `SafeText` is opaque and cannot be constructed from an arbitrary binary. This task exposes only six fixed compile-time chrome clauses needed by the minimal Scene test; external text and the complete chrome catalogue arrive in Task 7.
- `Capabilities` already has its final field shape: size; color mode; ASCII/reduced-motion/TTY/controlling-TTY booleans; `stdin_tty?`; `stdout_tty?`; feature states `:supported | :best_effort | :unavailable` for enhanced keys, focus, paste, IME composition, mouse, clipboard, and alternate screen; plus `paste_preallocation_bound?`. `explicit/2` validates closed values without reading the process environment.
- These primitives contain no renderer/framework/daemon reference and make later remote types and struct matches compile cleanly.

- [ ] **Step 1: Write the primitive RED tests**

```elixir
test "minimal trusted text cannot be confused with a raw binary" do
  safe = SafeText.chrome(:fake_banner)
  assert SafeText.value(safe) == "FAKE DEMO — NO USER DATA"
  refute safe == "FAKE DEMO — NO USER DATA"
  assert_raise FunctionClauseError, fn -> SafeText.chrome("untrusted") end
end

test "capability shape distinguishes input, output, and controlling TTY" do
  size = %Size{columns: 120, rows: 40}
  caps = Capabilities.explicit(size, stdin_tty?: true, stdout_tty?: true, controlling_tty?: true)
  assert caps.stdin_tty? and caps.stdout_tty? and caps.controlling_tty?
  assert caps.ime_composition == :unavailable
  assert caps.paste_preallocation_bound? == false
end
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/primitives_test.exs
```

Expected: FAIL because the four primitive modules do not exist.

- [ ] **Step 3: Implement only the fixed constructors and final struct shapes**

Do not add an arbitrary trusted-text constructor, environment lookup, terminal probing, external sanitizer, or renderer call. Implement `Inspect` for SafeText without exposing an external value in future crash reports.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/primitives_test.exs
git add apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test/swarm_code_cli/ui/primitives_test.exs
git commit -m "feat: define safe terminal primitives"
```

---

### Task 4: Define Neutral Input, Action, Effect, and DataSource Contracts

**Files:**
- Modify: `apps/swarm_code_cli/mix.exs`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/size.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/input.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/action.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/effect.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/clipboard_payload.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/layer_spec.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/destination.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scroll_operation.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/draft_key.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/operation.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/watch.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/request.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/delivery.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/admission_error.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/neutral_contracts_test.exs`

**Interfaces:**

```elixir
@type SwarmCodeCLI.UI.Input.t() ::
        {:key, :press | :repeat | :release, Input.key_code(), [Input.modifier()]}
        | {:text_fragment, :press | :repeat | :release, binary(), [Input.modifier()]}
        | {:paste, binary()}
        | :composition_started
        | {:composition_updated, binary()}
        | :composition_ended
        | {:resize, Size.t()}
        | :focus_gained
        | :focus_lost
        | {:mouse, Input.mouse_kind(), Input.mouse_button() | nil,
           non_neg_integer(), non_neg_integer(), [Input.modifier()]}

@type SwarmCodeCLI.UI.Action.t() ::
        :boot
        | {:resize, Size.t()}
        | {:terminal_capabilities, non_neg_integer(), Capabilities.t()}
        | {:terminal_lifecycle, :suspend_requested | :suspended | :resumed | :closing,
           non_neg_integer(), :keyboard | :launcher | :runtime}
        | {:terminal_failed, non_neg_integer(), Action.terminal_error_code()}
        | {:draw_result, binary(), non_neg_integer(), :ok | {:error, Action.terminal_error_code()}}
        | {:focus_cycle, :next | :previous}
        | {:focus_region, binary()}
        | {:move, :next | :previous | :first | :last}
        | {:expand, binary(), boolean()}
        | {:activate, binary(), non_neg_integer(), binary()}
        | {:scroll, binary(), ScrollOperation.t()}
        | {:editor, DraftKey.t(), Editor.Operation.t()}
        | {:navigate, Destination.t()}
        | {:open_layer, LayerSpec.t()}
        | :close_top_layer
        | {:data, DataSource.Delivery.t()}
        | {:timer_fired, binary()}
        | {:quit_requested, :detach | :daemon_shutdown}

@type SwarmCodeCLI.UI.Effect.t() ::
        {:watch, DataSource.Watch.t()}
        | {:unwatch, binary()}
        | {:query, DataSource.Request.t()}
        | {:command, DataSource.Request.t()}
        | {:cancel_request, binary()}
        | {:start_timer, binary(), non_neg_integer(), Action.t()}
        | {:cancel_timer, binary()}
        | {:terminal_control, :suspend | :resume | :shutdown}
        | {:announce, SafeText.t()}
        | {:bell, :needs_you}
        | {:clipboard_write, ClipboardPayload.t()}
        | {:detach, non_neg_integer()}
```

- Key codes are the closed special-key atoms plus `{:function, 1..12}`. Textual keys are valid UTF-8 fragments, never runtime atoms. Modifiers, mouse kinds/buttons, lifecycle states, error codes, request kinds, and effect variants use closed compile-time values.
- Terminal generation/capability actions let resize/resume update reducer state without a renderer type. Draw results carry a runtime-issued opaque draw token and the exact Scene revision attempted. `terminal_control` is interpreted only by SessionRuntime/LauncherControl; Reducer never sends an OS signal.
- `DataSource` callbacks are exactly `start_link/watch/unwatch/query/command/cancel/close`. `Watch`, `Request`, `Delivery`, and `AdmissionError` have their final closed structural fields now; typed DTO bodies arrive later.
- Add `{:stream_data, "== 1.4.0", only: :test, runtime: false}` once and add `test/support` through `elixirc_paths/1`.

- [ ] **Step 1: Write RED closed-union tests**

```elixir
test "terminal lifecycle and draw settlement remain renderer neutral" do
  caps = Capabilities.explicit(%Size{columns: 120, rows: 40}, stdin_tty?: true, stdout_tty?: true, controlling_tty?: true)
  assert {:terminal_capabilities, 4, ^caps} = Action.validate!({:terminal_capabilities, 4, caps})
  assert {:draw_result, "draw-8", 17, :ok} = Action.validate!({:draw_result, "draw-8", 17, :ok})
  assert {:terminal_control, :suspend} = Effect.validate!({:terminal_control, :suspend})
end

test "random input strings do not grow the atom table" do
  before_count = :erlang.system_info(:atom_count)
  Enum.each(StreamData.binary(length: 1..64) |> Enum.take(1_000), &Input.from_external_code/1)
  assert :erlang.system_info(:atom_count) == before_count
end
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/neutral_contracts_test.exs
```

Expected: FAIL because the closed neutral contracts do not exist.

- [ ] **Step 3: Implement exhaustive validators and behavior types**

Use `@enforce_keys` on structs and static error constructors. Unknown strings return typed errors or `:ignore`; do not use `String.to_atom/1`, `binary_to_atom/1`, anonymous-function effects, PIDs/ports/references inside actions, or arbitrary request/body maps.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/neutral_contracts_test.exs --seed 0
mise exec -- mix test apps/swarm_code_cli/test
git add apps/swarm_code_cli
git commit -m "feat: define neutral UI event contracts"
```

---

### Task 5: Define the Scene Union, Renderer Behavior, and Architecture Guards

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/options.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/error.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/rect.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/region.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/color.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/style.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/span.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/dialog.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/cursor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/announcement.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/text.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/rich_text.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/markdown.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/code.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/virtual_list.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/run_card.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/agent_list.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/consensus_ledger.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/research_document.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/progress.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/tabs.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/key_values.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/composer.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/notice.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/action_deck.ex`
- Create: `apps/swarm_code_cli/test/support/contract_fixtures.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/scene_contracts_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs`

**Interfaces:**

```elixir
Renderer.init(Renderer.Options.t()) ::
  {:ok, term(), Capabilities.t()} | {:error, Renderer.Error.t()}
Renderer.normalize_event(term(), term()) ::
  {:ok, Input.t(), term()} | {:ignore, term()} | {:error, Renderer.Error.t(), term()}
Renderer.draw(Scene.t(), term()) ::
  {:ok, term()} | {:error, Renderer.Error.t(), term()}
Renderer.shutdown(term()) :: :ok

Scene.validate(Scene.t()) :: :ok | {:error, Renderer.Error.t()}
```

- `Scene.Block.t/0` is the exhaustive initial union of Text, RichText, Markdown, Code, VirtualList, RunCard, AgentList, ConsensusLedger, ResearchDocument, Progress, Tabs, KeyValues, Composer, Notice, and ActionDeck. Every text position is `SafeText`; action references are opaque binaries.
- `Scene.validate/1` rejects raw text binaries, functions, PIDs, ports, references, unknown block/style atoms, negative/out-of-bounds rectangles, duplicate region/action IDs, invalid cursor, and any region outside Scene size.
- The architecture test scans `apps/swarm_code_cli/lib`. The only implementation-name/type exemption is the exact directory `/ui/renderer/ex_ratatui_013/`; the adapter itself will live at `/ui/renderer/ex_ratatui_013/adapter.ex`, not the sibling root file. It rejects ExRatatui/Ratatui/Rustler/ResourceArc aliases, structs, remote calls, and names elsewhere, plus any CLI dependency on `swarm_code_daemon`, FoundationGate, Ecto Repo, database paths, or daemon IPC.

- [ ] **Step 1: Write Scene and boundary RED tests**

```elixir
test "a minimal SafeText Scene validates and raw binary text does not" do
  scene = ContractFixtures.minimal_scene(SafeText.chrome(:fake_banner))
  assert :ok = Scene.validate(scene)
  assert {:error, %Renderer.Error{code: :invalid_scene}} =
           Scene.validate(ContractFixtures.with_raw_text(scene, "unsafe"))
end
```

Implement the architecture scan with `Path.expand("../../../lib", __DIR__)`, exempt only paths containing `/ui/renderer/ex_ratatui_013/`, and scan AST plus source strings so aliases/structs/remote calls are caught without rejecting neutral words in comments.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/scene_contracts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs
```

Expected: FAIL because Scene and Renderer behavior modules do not exist.

- [ ] **Step 3: Implement the closed Scene modules and exact behavior callbacks**

Use one module per file. Renderer error constructors contain only static messages. `Projector` will later return `{Scene.t(), %{required(binary()) => Action.t()}}`; the semantic table never enters Scene.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/scene_contracts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs
git add apps/swarm_code_cli
git commit -m "feat: define renderer-neutral Scene boundary"
```

---

### Task 6: Port and Attest Exact Unicode wcwidth 0.2.2

**Files:**
- Modify: `NOTICE`
- Create: `third_party/unicode-width-0.2.2/UPSTREAM.json`
- Create: `third_party/unicode-width-0.2.2/COPYRIGHT`
- Create: `third_party/unicode-width-0.2.2/LICENSE-MIT`
- Create: `third_party/unicode-width-0.2.2/LICENSE-APACHE`
- Create: `third_party/unicode-width-0.2.2/src/lib.rs`
- Create: `third_party/unicode-width-0.2.2/src/tables.rs`
- Create: `third_party/unicode-width-0.2.2/tests/emoji-test.txt`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/width.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/width/table.ex`
- Create: `scripts/dev/sync_unicode_width.exs`
- Create: `apps/swarm_code_cli/test/fixtures/unicode_width/vectors.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/width_test.exs`

**Interfaces:**

```elixir
Width.cells(binary(), :narrow | :wide) :: non_neg_integer()
Width.graphemes(binary()) :: [binary()]
Width.take_cells(binary(), non_neg_integer(), :narrow | :wide) :: {binary(), binary(), non_neg_integer()}
Width.wrap(binary(), pos_integer(), :narrow | :wide) :: [binary()]
```

- Port exact crate 0.2.2, checksum `b4ac048d71ede7ee76d585517add45da530660ef4390e49b098733c6e897f254`, commit `9d98411769fe13c7c18cab0b3fbbab29ba8350ea`, Unicode 17.0.0. `Width.Table` faithfully represents narrow/CJK `WidthInfo`, emoji presentation/modifier/flag/keycap/tag/ZWJ state, combining characters, variation selectors, and ligatures.
- `sync_unicode_width.exs --accept SOURCE_CRATE` verifies checksum before safe extraction, rejects absolute/parent/symlink/device archive entries, copies exact licensed inputs, generates Table/vectors deterministically, and writes same-directory atomic replacements. `--check` is network-free and verifies all source/output hashes in `UPSTREAM.json`.
- Width iteration never splits an extended grapheme. The committed upstream-derived vector identifies expected widths; hand literals cross-check but do not redefine upstream truth.

- [ ] **Step 1: Write the width RED tests**

```elixir
test "width agrees with committed upstream-derived vectors" do
  Enum.each(WidthFixtures.vectors(), fn %{"text" => text, "narrow" => narrow, "wide" => wide} ->
    assert Width.cells(text, :narrow) == narrow
    assert Width.cells(text, :wide) == wide
  end)
  assert WidthFixtures.expected!("ქართული") == 7
  assert Width.cells("ქართული", :narrow) == 7
end
```

Also cover composed/decomposed accents, Georgian, Arabic/Hebrew, CJK, ambiguous symbols, modifiers, flags, family/occupation ZWJ, VS15/VS16, and one cell below/at/above every `take_cells` boundary.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/width_test.exs
```

Expected: FAIL because Width and attested tables do not exist.

- [ ] **Step 3: Acquire verified sources and generate the port**

```bash
curl -A 'SwarmCodeCLI-width-sync/1' -fsSLo "$TMPDIR/unicode-width-0.2.2.crate" https://static.crates.io/crates/unicode-width/unicode-width-0.2.2.crate
printf '%s  %s\n' b4ac048d71ede7ee76d585517add45da530660ef4390e49b098733c6e897f254 "$TMPDIR/unicode-width-0.2.2.crate" | shasum -a 256 -c -
mise exec -- elixir scripts/dev/sync_unicode_width.exs --accept "$TMPDIR/unicode-width-0.2.2.crate"
```

Expected: source identities/licenses and deterministic generated files match the exact attestation.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- elixir scripts/dev/sync_unicode_width.exs --check
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/width_test.exs --seed 0
git add NOTICE third_party apps/swarm_code_cli/lib/swarm_code_cli/ui/width* apps/swarm_code_cli/test/fixtures/unicode_width apps/swarm_code_cli/test/swarm_code_cli/ui/width_test.exs scripts/dev/sync_unicode_width.exs
git commit -m "feat: port exact Unicode terminal width"
```

---

### Task 7: Complete SafeText, Capability Detection, and Carbon Theme

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text/limits.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities/probe.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/theme.ex`
- Create: `apps/swarm_code_cli/test/fixtures/safe_text/adversarial.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs`

**Interfaces:**

```elixir
SafeText.external(binary(), SafeText.Limits.t()) :: {:ok, SafeText.t()} | {:error, :input_too_large | :escaped_output_too_large}
SafeText.external_chunks(Enumerable.t(), SafeText.Limits.t()) :: Enumerable.t()
SafeText.concat([SafeText.t()]) :: SafeText.t()
SafeText.number(non_neg_integer()) :: SafeText.t()
Capabilities.from_probe(Capabilities.Probe.t()) :: Capabilities.t()
Theme.style(Scene.style_role(), Capabilities.t()) :: Scene.Style.t()
```

- `SafeText.Limits.content/0` is 65,536 input/262,144 escaped bytes; `composer_viewport/0` is 8,192/65,536; both use eight-cell tabs. Check input size before decoding, process one scalar/invalid byte into bounded iodata, and reject before adding an over-limit visible token.
- Preserve LF; expand tabs; expose C0/C1/CR/BS/DEL/ESC/CSI/OSC/DCS/APC/PM, bidi controls, and standalone deceptive zero-width codepoints with fixed names. Replace invalid UTF-8 visibly. Retain validated combining/emoji ZWJ/variation-selector graphemes.
- Probe separately records stdin TTY, stdout TTY, and usable controlling `/dev/tty`. Full-screen eligibility requires all three. Piped stdin, redirected output, missing controlling TTY, TERM dumb, or explicit plain fails closed before native init. Color precedence is explicit no-color/NO_COLOR → monochrome → truecolor → 256 → 16. Features remain supported/best-effort/unavailable; native paste preallocation and ExRatatui IME start false/unavailable.
- Carbon palette remains the exact values in the interaction contract. Monochrome focus uses reverse/border/word cues. No style uses colored underline because CellSession cannot report underline color.

- [ ] **Step 1: Write sanitizer/capability/theme RED tests**

```elixir
test "external controls are inert and bounded" do
  assert {:ok, safe} = SafeText.external("ok\e]0;owned\a\rFAIL\b\u202Etxt\u202C\u200B", Limits.content())
  assert SafeText.value(safe) == "ok⟦ESC⟧]0;owned⟦BEL⟧⟦CR⟧FAIL⟦BS⟧⟦RLO U+202E⟧txt⟦PDF U+202C⟧⟦ZWSP U+200B⟧"
end

test "full screen requires input output and controlling TTY" do
  for probe <- CapabilityFixtures.any_missing_tty() do
    refute Capabilities.from_probe(probe).full_screen?
  end
end
```

Property tests generate arbitrary binaries up to 4,096 bytes and assert no executable control survives except LF and no output exceeds its configured bound.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs
```

Expected: FAIL because external sanitization, probe policy, and theme are incomplete.

- [ ] **Step 3: Implement bounded sanitizer, closed probes, and exhaustive theme**

Pure capability code consumes `%Capabilities.Probe{}` only; a later owner gathers OS observations. Keep all trusted labels as exhaustive `SafeText.chrome/1` clauses and never expose an arbitrary trusted constructor.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs --seed 0
git add apps/swarm_code_cli
git commit -m "feat: secure terminal text and capabilities"
```

---

### Task 8: Define Typed UI DTOs and the Deterministic Fake Source

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/watch.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/request.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/delivery.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/admission_error.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/shell_snapshot.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/workspace_snapshot.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/transcript_window.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/run_detail_snapshot.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/activity_snapshot.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/pending_interaction.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/run_summary.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/transcript_item.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/activity_item.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/connection.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/question.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/dto/outcome.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/delta.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/fake/source.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/fake/script.ex`
- Create: `apps/swarm_code_cli/test/fixtures/fake/three_run_script.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_source_test.exs`

**Interfaces:**

```elixir
Fake.Source.start_link(script: Fake.Script.t(), source_epoch: binary()) :: GenServer.on_start()
Fake.Source.attach(server(), binary(), pid()) :: :ok | {:error, :duplicate_client}
Fake.Source.detach(server(), binary()) :: :ok
Fake.Source.watch(server(), binary(), Watch.t()) :: :ok | {:error, AdmissionError.t()}
Fake.Source.request(server(), binary(), Request.t()) :: :ok | {:error, AdmissionError.t()}
Fake.Source.advance(server(), binary()) :: :ok | {:error, :unknown_barrier}
Fake.Source.snapshot(server()) :: Fake.Script.snapshot()
```

- DTOs are page-limited typed structs. `Watch` has binary reference, closed slot, `SwarmCode.Protocol.Scope`, generation, page size 1-200, and byte limit at most 1,048,576. `Request` has binary request ID, closed kind, scope, generation, origin, absolute deadline, and expected response type. `Delivery.body` is only the closed DTO/delta/outcome union.
- Fake Source is the separately owned fake-daemon analogue. It owns A1/A2/B1 canonical scripted facts and continues when a client detaches. The fixture is bounded through `SwarmCode.Protocol.JsonLimits.decode/2`, then closed strings are converted only by clauses. Fixed clock is `2026-09-03T12:00:00Z`; fixed UUIDs and binary barrier IDs are committed.
- `advance/2` mutates source facts in node → assistant text → reasoning → run order and acknowledges only after subscriber messages are enqueued. It never sleeps, opens a user path, or stores draft/UI state. Its redacted `format_status/1` exposes counts/status IDs only.

- [ ] **Step 1: Write source-state RED tests**

Assert initial three runs, exact fixed identities, barrier ordering, revision-7 Q1, a gap step, accepted answer then resolved/running state, B1 progress, source continuity after attach/detach, bounded page snapshots, invalid fixture rejection, and no runtime atom growth.

```elixir
assert :ok = Fake.Source.advance(source, "a1-a2-b1-step-1")
assert_receive {:fake_source, ^client_id, [%Delta{kind: :node_upsert}, %Delta{kind: :stream_append, channel: :text}, %Delta{kind: :stream_append, channel: :reasoning}, %Delta{kind: :run_update}]}
assert Fake.Source.snapshot(source).interactions["q1"].expected_revision == 7
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_source_test.exs
```

Expected: FAIL because DTOs and Fake Source do not exist.

- [ ] **Step 3: Implement source-first canonical state**

Apply a barrier to canonical source state before deriving each client's typed page/delta. Bound every generated list/string and refuse malformed commands with static `AdmissionError`; never expose Ecto structs, arbitrary maps, secrets, complete process state, or raw JSON.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_source_test.exs --seed 0
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_source_test.exs --seed 4901
git add apps/swarm_code_cli
git commit -m "feat: script typed fake UI facts"
```

---

### Task 9: Implement the Fake DataSource Client Synchronization Contract

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/data_bridge.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/fake.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/conformance_test.exs`

**Interfaces:**

```elixir
DataSource.start_link(owner: pid(), options: keyword()) :: GenServer.on_start()
DataSource.watch(server(), Watch.t()) :: :ok | {:error, AdmissionError.t()}
DataSource.unwatch(server(), binary()) :: :ok
DataSource.query(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
DataSource.command(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
DataSource.cancel(server(), binary()) :: :ok
DataSource.close(server()) :: :ok

DataBridge.normalize({:swarm_code_ui_data, binary(), Delivery.t()}, binary() | nil) ::
  {:ok, {:data, Delivery.t()}} | {:ignore, :stale_epoch} | {:error, :invalid_delivery}
```

- Each Fake adapter owns only its source monitor, watches, pre-ready buffers, requests, deadlines, and owner monitor. Pre-ready bounds are 128 events/1,048,576 encoded bytes per watch. Unwatch/close settles all local resources and sends exactly one closed delivery; source run facts survive.
- `watch_ready` installs a page snapshot and `through_sequence` before deltas become visible. Contiguous sequences pass. Duplicate/stale epoch/watch/scope/generation/revision/request deliveries are rejected. A visible scripted gap or `snapshot_required` waits for the reducer's one typed resync request; pre-ready overflow triggers the same resync path internally because no delta has been exposed.

- [ ] **Step 1: Write synchronization RED tests**

Cover ready-before-delta, exact through sequence, bounded buffering, contiguous order, duplicate/stale rejection, gap and explicit resync, epoch replacement, cancellation, owner death, close, and new-client ready snapshot from the continuing source.

```elixir
assert :ok = Fake.Source.advance(source, "workspace-a-gap")
assert_receive {:swarm_code_ui_data, ^epoch, %Delivery{kind: :delta, sequence: 8}}
assert :ok = DataSource.query(client, FakeFixtures.resync_request("watch-a"))
assert_receive {:swarm_code_ui_data, ^epoch, %Delivery{kind: :resyncing}}
assert_receive {:swarm_code_ui_data, ^epoch, %Delivery{kind: :watch_ready, body: %WorkspaceSnapshot{through_sequence: 9}}}
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/conformance_test.exs
```

Expected: FAIL because Fake DataSource client synchronization does not exist.

- [ ] **Step 3: Implement bounded client synchronization**

Monitor owner/source, validate every typed correlation field before delivery, and settle synchronous admission calls without doing long source work inside the adapter callback. Emit ready/resync/closed messages in one documented order and keep no canonical source copy.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/conformance_test.exs --seed 0
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/conformance_test.exs --seed 4901
git add apps/swarm_code_cli
git commit -m "feat: synchronize fake UI watches"
```

---

### Task 10: Build the Grapheme Editor and Process-Local Draft Store

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/buffer.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/operation.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/selection.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/visible_slice.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/draft.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/draft/attachment_ref.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/draft/target.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/draft_key.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/drafts.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/editor_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/drafts_test.exs`

**Interfaces:**

```elixir
Editor.new(max_bytes: pos_integer(), undo_bytes: pos_integer(), undo_count: pos_integer()) :: Editor.t()
Editor.apply(Editor.t(), Editor.Operation.t()) :: {:ok, Editor.t()} | {:error, :text_too_large}
Editor.text(Editor.t()) :: binary()
Editor.cursor(Editor.t()) :: non_neg_integer()
Editor.selection(Editor.t()) :: nil | {non_neg_integer(), non_neg_integer()}
Editor.visible_slice(Editor.t(), pos_integer(), pos_integer()) :: Editor.VisibleSlice.t()

DraftKey.t() :: {binary(), :main | {:thread, binary()} | {:edit, binary()}}
Draft.new(DraftKey.t(), Editor.t()) :: Draft.t()
Drafts.fetch(Drafts.t(), DraftKey.t()) :: Draft.t()
Drafts.put(Drafts.t(), Draft.t()) :: Drafts.t()
Drafts.clear_origin(Drafts.t(), DraftKey.t(), binary()) :: Drafts.t()
```

- `Editor.Buffer` is a two-sided grapheme zipper. Insert/paste splits once, prepends/reverses bounded chunks, and does not append repeatedly to a growing binary. Cursor and selection are grapheme indices; vertical movement retains preferred display cell using `Width`.
- Operations are insert/resegment text fragment, one bounded paste, composition start/update/end, delete backward/forward, left/right/up/down/home/end movement, selection extension, select all, undo, redo, and explicit newline. Paste never produces an activate/send action. Composition text remains editor-local until committed and Enter cannot activate send while composition state is active.
- Default editor text bound is 262,144 bytes. Undo is bounded to 100 records and 1,048,576 bytes; eviction drops only derived undo history, never current text.
- `Editor.visible_slice/3` returns a grapheme-aligned viewport around the cursor bounded to 8,192 source bytes plus logical row/cell metadata. Projector passes only this slice to `SafeText.external/2`, so every admitted 262,144-byte draft remains editable even when control escaping would make the whole value exceed a single Scene bound.
- `Draft` carries exact editor state, vertical/horizontal editor scroll, Reply/Steer/Revise/command/goal/research chip state, attachment metadata references only, validation state, and height clamped to 1-8 rows.
- A clear operation requires both the exact draft key and originating request ID. It cannot clear a currently newer submission or any other conversation draft.

- [ ] **Step 1: Write Unicode editing and draft-isolation RED tests**

Exercise composed/decomposed accents, Georgian, Arabic/Hebrew, CJK, ambiguous width, skin tones, flags, family/occupation ZWJ sequences, VS15/VS16, multiline vertical movement, selection replacement, 100 repeated paste events, undo eviction, navigation fetch/restore, and per-origin clearing.

```elixir
test "paste is one grapheme-safe edit and cannot submit" do
  editor = Editor.new(max_bytes: 262_144, undo_bytes: 1_048_576, undo_count: 100)
  assert {:ok, editor} = Editor.apply(editor, {:paste, "ქართული\n👩🏽‍🚒"})
  assert Editor.text(editor) == "ქართული\n👩🏽‍🚒"
  assert Editor.cursor(editor) == 9
  assert Editor.cursor(editor) == length(Width.graphemes(Editor.text(editor)))
  assert Editor.selection(editor) == nil
end

test "accepted request clears only its exact originating draft" do
  drafts = DraftFixtures.two_conversations_with_requests()
  cleared = Drafts.clear_origin(drafts, {"conversation-a", :main}, "request-a")
  assert Editor.text(Drafts.fetch(cleared, {"conversation-a", :main}).editor) == ""
  assert Editor.text(Drafts.fetch(cleared, {"conversation-b", :main}).editor) == "B draft"
end
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/editor_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/drafts_test.exs
```

Expected: FAIL because the pure editor and drafts do not exist.

- [ ] **Step 3: Implement the minimal pure editor and draft store**

Store undo records as inverse operations with exact byte accounting. Recompute rendered row/cell positions through `Width` only at explicit movement/projection boundaries. Attachment values contain stable ID, display-safe name, media type, byte size, dimensions, status, and opaque reference; they never contain file bytes or base64.

- [ ] **Step 4: Run GREEN and properties**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/editor_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/drafts_test.exs --seed 0
```

Expected: PASS, including the property that applying any bounded edit sequence keeps cursor/selection within the grapheme count and reconstructs exact selected text.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/editor apps/swarm_code_cli/lib/swarm_code_cli/ui/editor.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/draft* apps/swarm_code_cli/test
git commit -m "feat: preserve grapheme editor drafts"
```

---

### Task 11: Implement the Pure Reducer, Generations, and Logical Scroll Anchors

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/state.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/init.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/watch_state.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/read_model.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/chunk_deque.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scroll.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/ordered_id_set.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/destination.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_watch_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_navigation_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_scroll_test.exs`

**Interfaces:**

```elixir
Reducer.init(Init.t()) :: {State.t(), [Effect.t()]}
Reducer.update(State.t(), Action.t()) :: {State.t(), [Effect.t()]}

Scroll.t() :: %Scroll{
  anchor: {binary(), non_neg_integer(), :top | :cursor} | nil,
  follow?: boolean(),
  unseen: OrderedIdSet.t(),
  before_cursor: binary() | nil,
  after_cursor: binary() | nil
}
```

- `State` owns terminal generation/lifecycle, size/capabilities, source epoch, four closed watch slots, destination/back history, visible and hidden focus, selections, expansions, tabs/filters, drafts, independent Main/Inspector scroll maps, logical layer stack, bounded read model, outstanding requests, dirty revision, and current action/request UUID sequence supplied by `Init`.
- `ChunkDeque` stores stream chunks in prepend-only chunk collections by entity/channel/attempt ID. Reset replaces a failed attempt; projection materializes only the visible item. It enforces the DTO field bound while reading and requests resync/detail instead of dropping bytes.
- Matching requires source epoch, watch reference, scope kind/ID/generation, revision, contiguous sequence, and request reference as applicable. Duplicate/stale events produce byte-for-byte identical state and no effects.
- A first sequence gap marks the slot stale/resyncing and emits one `%Request{kind: {:resync_watch, watch_ref}}`; later gap events while resyncing emit nothing. A replacement ready snapshot installs facts while retaining drafts, focus, selection, modal, layout preference, and logical anchors.
- Navigation increments/freeze-invalidates the old slot generation before emitting `unwatch`; the replacement watch carries the new generation. View queries are canceled; admitted command requests remain correlated offscreen.
- User scrolling detaches immediately; repeated changes to one stable item count once; `:last`/`:follow` rejoins and clears unseen. Main and Inspector are independent; prepending history and resizing preserve stable item/intra-line anchors.
- `OrderedIdSet` stores insertion order plus a membership index, admits at most 512 IDs for the current bounded window, and never presents map-enumeration order. Duplicate insertion preserves position. Overflow marks the watch snapshot-required and requests resync rather than silently evicting an unseen canonical item.

- [ ] **Step 1: Write stale/gap/navigation/scroll RED tests**

Use the exact reducer list in spec section 17.2 through “prepended page and resize anchor preservation.” Also assert a higher terminal generation replaces size/capabilities and reprojects without changing draft/focus/scroll, while stale generations and stale draw results change nothing. Include this ordering assertion:

```elixir
{next, effects} = Reducer.update(state, {:navigate, %Destination{kind: :conversation, id: "conversation-b"}})
assert next.watches.workspace.generation == state.watches.workspace.generation + 1
assert next.watches.workspace.status == :frozen
assert [
         {:cancel_request, "view-query-a"},
         {:unwatch, "watch-a"},
         {:watch, %Watch{scope: %Scope{id: "conversation-b", generation: new_generation}}}
       ] = effects
assert new_generation == next.watches.workspace.generation
```

For a resync, snapshot `Draft`, focus, selection, `Scroll` for Main/Inspector, and layer stack before the gap and assert exact equality after replacement ready.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_watch_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_navigation_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_scroll_test.exs
```

Expected: FAIL because reducer state does not exist.

- [ ] **Step 3: Implement pure correlated transitions**

Pattern-match closed actions and DTO structs. Never call `System.monotonic_time/0`, `DateTime.utc_now/0`, UUID generators, `send/2`, timers, filesystem, network, or process functions. Increment `State.revision` only for matching semantic changes. Keep read-model maps page-limited and validate stable IDs before insert/remove.

- [ ] **Step 4: Run GREEN under fixed seeds**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_watch_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_navigation_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_scroll_test.exs --seed 0
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_watch_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_navigation_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_scroll_test.exs --seed 7331
```

Expected: PASS with effect ordering and unchanged-state assertions exact.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test
git commit -m "feat: reduce correlated async UI state"
```

---

### Task 12: Project Responsive Scenes and the Four Representative Surfaces

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/layout.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/shell.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/workspace.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/composer.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/status.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/fixtures.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/layout_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/projector_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/representative_scenes_test.exs`

**Interfaces:**

```elixir
Layout.classify(Size.t()) :: :xl | :wide | :medium | :narrow | :small | :too_small
Layout.regions(State.t()) :: [Scene.Region.t()]
Projector.project(State.t()) :: {Scene.t(), %{required(binary()) => Action.t()}}

Fixtures.representative(:chat | :swarm | :consensus | :research, Size.t(), Capabilities.t()) :: State.t()
```

- Classification is exact: XL `>=170x34`; Wide `>=150x30`; Medium `>=100x24`; Narrow `>=72x20`; Small `>=50x16`; compressed Small `>=50x14`; Too small otherwise. A width-qualified layout missing height falls to the highest lower class whose minima it satisfies.
- At Wide/XL, Navigator defaults to 26 cells clamped 24-32, Inspector defaults to 42 clamped 38-56, and Main remains at least 50. Medium docks Main plus exactly one persisted drawer. Narrow uses Main and full-height overlays. Small uses one-row title, Main, at most two-row needs-you strip, compact composer, and status. Compressed Small retains resize/help/detach/plain and hides destructive/send actions. Too small exposes only current/required size and Resize/Help/Detach/Plain.
- Main composer height is 1-8; needs-you is at most two; run logs are at most 45 percent of viewport unless maximized. No region overlaps, leaves the screen, or creates whole-screen horizontal scroll.
- Projector owns visible/enabled actions, fixed labels, focus indicator, cursor, state vocabulary, action IDs, and responsive collapse. It intersects every action with DTO `allowed_actions`; it never invents domain permission.
- Temporarily disabled actions show the DTO's sanitized safe reason. A stale/resyncing slot keeps its content visible and projects a scoped recovery Notice with Retry and Diagnostics rather than a blocking spinner. The status region shows only the most relevant three-to-five bindings; `?` opens the complete current region/action map.
- Title/composer always name the single fake mode explicitly. Research depth is rendered as `Research: Ultra (4x10)`, never as the ambiguous standalone word `Ultra`. Hidden regions keep selection/anchor facts without animation or repeated layout work.
- The four fixed surfaces are streaming chat/composer, swarm/agent pane, consensus docket/ticker/ledger, and research report/sources. They are representative visual evidence only; static consensus/workflow/research blocks do not claim domain functionality.

- [ ] **Step 1: Write breakpoint and projection RED tests**

Generate one cell above/below every width and height boundary and assert exact class, visible roles, focus relocation/restoration, minimum Main width, no overlap, and no destructive/send action in compressed/too-small output.

```elixir
assert Layout.classify(%Size{columns: 170, rows: 34}) == :xl
assert Layout.classify(%Size{columns: 169, rows: 34}) == :wide
assert Layout.classify(%Size{columns: 150, rows: 29}) == :medium
assert Layout.classify(%Size{columns: 50, rows: 14}) == :small
assert Layout.classify(%Size{columns: 49, rows: 14}) == :too_small
assert Layout.classify(%Size{columns: 50, rows: 13}) == :too_small
```

For every projected Scene, assert `Scene.validate/1 == :ok`, all text positions hold `SafeText`, action IDs are opaque binaries, and action-table values never appear in `inspect(scene)`.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/layout_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/projector_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/representative_scenes_test.exs
```

Expected: FAIL because layout and projection do not exist.

- [ ] **Step 3: Implement deterministic rectangles and semantic blocks**

Resolve all rectangles in the projector. Virtual lists include total count, first logical index, visible item structs, opaque before/after cursors, and a fixed overscan of two items above/two below; they never receive the complete 10,000-item fixture. Use fixed trusted copy `FAKE DEMO — NO USER DATA` in title and plain status.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/layout_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/projector_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/representative_scenes_test.exs --seed 0
```

Expected: PASS for all boundary properties and four surfaces.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test
git commit -m "feat: project responsive fake workspace scenes"
```

---

### Task 13: Add the Keymap, Switcher, Activity Center, and Safe Question Modal

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/keymap.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/layer_spec.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/switcher.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/activity.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/question.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/keymap_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/layers_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/activity_question_test.exs`

**Interfaces:**

```elixir
Keymap.resolve(Input.t(), State.t(), action_table()) :: :ignore | {:ok, Action.t()}
Switcher.open(State.t(), opener :: binary()) :: LayerSpec.t()
Activity.sort([ActivityItem.t()]) :: [ActivityItem.t()]
Question.answer_request(State.t(), PendingInteraction.t(), binary(), binary()) :: Request.t()
```

- Resolution consumes at most one action in priority order: dialog; overlay/switcher; composer; focused content; global. Escape closes exactly one layer and cannot activate the newly exposed layer in the same input.
- Global and content keys match spec section 12. A first `g` opens a bounded jump layer through `{:open_layer, %LayerSpec{kind: :jump}}`; `c/w/r/s/u/,` inside it navigate and close exactly that layer. This avoids renderer-owned chord state.
- `Ctrl+K` opens the switcher; every fake-visible action has a switcher/action-menu route. `Tab`/`Shift+Tab` cycle visible regions. `Ctrl+O` always inserts newline. Enhanced `Shift+Enter` inserts newline only when capabilities say it is distinguishable. `Alt+Enter` and `/queue` resolve to the same queue-intent activation. Paste resolves only to one editor paste action. Enter cannot send while a palette, question, confirmation, paste handling, or injected IME composition state is active.
- Activity order is Needs you, running/paused, recent failures, recent completions, with stable timestamp/ID tie breaks. Opening Q1 stores destination/focus/row/selection/anchors as opener context.
- Needs-you bell is opt-in and fires once per newly visible unresolved interaction. Completion/failure remains durable in Activity and never steals focus or forces navigation.
- A question modal traps focus, uses fixed option labels plus sanitized external bodies, initially focuses the safest enabled option, and Escape does not answer/skip. Answer option 2 emits exactly one revision-7 command request containing A2 run/node/interaction IDs and fixed request UUID. Accepted then resolved marks the modal settled/read-only; a later close restores the Activity row. Revision conflict refreshes and never claims local success.
- A destructive confirmation always starts on Cancel. Bare Enter cannot select the destructive action until explicit movement changes focus.

- [ ] **Step 1: Write priority/focus/question RED tests**

Cover all key tables relevant to the fake surface plus mouse parity, modal focus trap, single Escape, safest default, opener restoration, settled-by-other-client behavior, no double activation, paste-not-submit, and queue equivalence.

```elixir
test "answering Q1 carries exact compare-and-set identity once" do
  state = QuestionFixtures.q1_open(option: 2, request_id: "00000000-0000-4000-8000-000000000042")
  assert {:ok, {:activate, action_id, revision, request_id}} =
           Keymap.resolve(Input.key(:enter), state, Projector.project(state) |> elem(1))
  {next, [{:command, request}]} = Reducer.update(state, {:activate, action_id, revision, request_id})
  assert request.kind == {:answer_question, "run-a2", "node-a2", "q1", 7, ["option-2"]}
  assert next.outstanding[request_id].origin == {:interaction, "q1", 7}
end
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/keymap_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/layers_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/activity_question_test.exs
```

Expected: FAIL because key routing and layers do not exist.

- [ ] **Step 3: Implement semantic routing and modal projection**

Key matching uses closed literal code/modifier lists. `activate` validates Scene revision and current ActionTable membership; stale, absent, or disabled action IDs are ignored. Never parse an action ID to reconstruct a command. Keep the background inert whenever a layer is present and project at most one visual overlay, using breadcrumbs for logical drill-down.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/keymap_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/layers_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/activity_question_test.exs --seed 0
```

Expected: PASS with exactly one action/effect per input.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test
git commit -m "feat: add keyboard-first activity interactions"
```

---

### Task 14: Own Runtime Effects and Prove the Deterministic Three-Run Scenario

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/session_runtime.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/effect_runner.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/timer_supervisor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene_slot.ex`
- Create: `apps/swarm_code_cli/test/support/renderer_fake.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/session_runtime_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/three_run_scenario_test.exs`

**Interfaces:**

```elixir
SessionRuntime.start_link(init: Init.t(), data_source: pid(), renderer: pid(), frame_ms: pos_integer()) :: GenServer.on_start()
SessionRuntime.input(server(), Input.t()) :: :ok
SessionRuntime.snapshot(server()) :: State.t()
SessionRuntime.close(server(), :detach) :: :ok

EffectRunner.run(Effect.t(), context()) :: :ok
```

- `SessionRuntime` serializes terminal input, DataBridge actions, terminal generation/capability/lifecycle actions, draw settlements, request settlements, and timer actions. It applies every matching semantic event immediately, updates the Scene/ActionTable, and has at most one current-frame draw timer. Additional semantic updates mark the frame dirty but remain individually present in state.
- `SceneSlot` is a protected, runtime-owned ETS table with one latest already-sanitized Scene keyed by revision and a fixed byte ceiling. SessionRuntime writes it and sends the renderer only `{:draw, revision}`. TerminalOwner reads that exact revision and returns a compact acknowledgment/error, then drops the local Scene value. Whole Scene/draft/transcript values never become a terminal process's retained state or last mailbox message, preventing crash reports from printing visible content. Destroy the table when SessionRuntime stops.
- `SessionRuntime`, `DataSource.Fake`, and `Fake.Source` implement redacted `format_status/1` output containing counts/IDs/status words only; no draft, SafeText value, transcript, reasoning, question body, or Scene appears in Logger crash reports.
- `EffectRunner` dispatches only the closed Effect union. It owns timers under `TimerSupervisor`, forwards typed watch/query/command/cancel to the fake adapter, and reports one settlement action. Clipboard remains disabled in this spike unless an explicit bounded test capability is injected.
- Draw failure becomes a typed safe error and starts orderly terminal/client closure. Client detach first projects a fixed final `DETACHED — RUNS CONTINUE` Scene, writes it to SceneSlot, requests its draw, and waits for that matching acknowledgment within the owned deadline; it then cancels UI timers/requests/watches and closes the client DataSource whether the paint succeeded or failed. It emits no run/agent/domain Stop command.
- Test renderer accepts only draw tokens/revisions, reads the matching SceneSlot entry, and sends deterministic acknowledgements/errors. It contains no ExRatatui type and never retains the Scene in state/messages.

- [ ] **Step 1: Write runtime RED tests**

Assert 100 ordered semantic deltas are all applied while at most one pending paint timer exists, an update arriving after timer creation is included in the next actual draw, an update arriving during an in-flight draw schedules the next draw after its acknowledgment, stale/mismatched draw results do nothing, resize/capability generation changes reproject, final detach paint is attempted once, hidden/reduced-motion states own no animation timer, renderer error settles closure, and all timers/requests/watches disappear under monitored shutdown.

Write the entire spec section 15 script as one deterministic test, including:

```elixir
assert Editor.text(draft_a.editor) == "Review authentication\nand its tests"
assert main_scroll.anchor == {"message-a-2", 3, :top}
assert main_scroll.follow? == false
assert inspector_scroll.follow? == false
assert counts == %{running: 2, waiting: 1}
assert q1.expected_revision == 7
```

The test must advance named fake barriers, not time. It creates A and B drafts, navigates A→B→Activity→A, delivers one deliberately late A response, answers Q1 option 2, resizes `160x50 → 80x24 → 50x14 → 160x50`, rejoins Main with End, detaches, then starts a new client adapter against the continuing source. Assert exact cursor, nonempty selection, chips, attachment metadata, heights, independent anchors, deduplicated unseen IDs, A1/A2/B1 states, and no domain Stop request.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/session_runtime_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/three_run_scenario_test.exs
```

Expected: FAIL because runtime ownership does not exist.

- [ ] **Step 3: Implement ordered runtime and effect settlement**

Keep current Scene revision/ActionTable and one draw state `:idle | {:timer, timer_id} | {:in_flight, draw_token, attempted_revision}`. The timer identity is independent of Scene revision; when it fires, it reads and draws the latest current revision. If state advances during an in-flight draw, the matching result immediately schedules one new frame. Stale timer IDs and mismatched draw tokens/results do nothing without clearing the valid pending state. On close, increment watch generations, perform the bounded final-paint handshake, cancel timers/requests, unwatch, close the adapter, request renderer shutdown, and acknowledge only after monitored children settle.

- [ ] **Step 4: Run GREEN repeatedly**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/session_runtime_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/three_run_scenario_test.exs --seed 0
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/session_runtime_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/three_run_scenario_test.exs --seed 8172
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/session_runtime_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/three_run_scenario_test.exs --seed 99103
```

Expected: PASS without sleeps, stale changes, lost chunks, or surviving client-owned process/timer/monitor.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test
git commit -m "feat: prove async fake TUI continuity"
```

---

### Task 15: Add the Permanent Plain, ASCII, No-Color, and Reduced-Motion Surface

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/plain/options.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/plain/environment.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/plain/presenter.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/plain/command.ex`
- Create: `apps/swarm_code_cli/test/fixtures/plain/three_run_output.txt`
- Create: `apps/swarm_code_cli/test/fixtures/plain/question_commands.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/plain/options_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/plain/presenter_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/plain/command_test.exs`

**Interfaces:**

```elixir
Plain.Options.select([binary()], Plain.Environment.t()) :: {:ok, Plain.Options.t()} | {:error, :invalid_option}
Plain.Presenter.new(Plain.Options.t()) :: Plain.Presenter.t()
Plain.Presenter.present(Plain.Presenter.t(), binary(), Delivery.t()) :: {Plain.Presenter.t(), [output_record()]}
Plain.Command.parse(SafeText.t(), Plain.Presenter.t(), binary()) :: {:ok, Action.t()} | {:error, SafeText.t()}

output_record() :: {:stdout, iodata()} | {:stderr, iodata()}
```

- Selection is explicit `--plain`, or automatic when stdin is non-TTY, stdout is non-TTY, no controlling TTY is usable, or TERM equals `dumb` case-insensitively. Plain may consume deterministic commands from piped stdin; full-screen raw polling never starts with a piped input. `--no-alt-screen` remains an interactive renderer option and does not imply plain when all three TTY checks pass. `--ascii`, `--no-color`, present `NO_COLOR`, and `--reduced-motion` are retained in options for both presenters.
- Plain output is chronological and append-only, deduplicated by `{source_epoch, scope kind/id/generation, sequence}`. It uses fixed headings, exact state words, sanitized content, and explicit prompts. It emits no cursor rewriting, alternate-screen bytes, terminal hyperlinks, animation, bell, or terminal controls other than LF record separators.
- Plain commands cover every action exposed by the fake slice: navigate conversations/Activity, inspect run, answer Q1 by number/name, Back, allowed Skip, send, queue, follow, and detach. The same typed answer request and queue intent used by TUI are produced; there is no second domain-command vocabulary.
- ASCII substitutes trusted box/glyph chrome only. No-color/reduced-motion output remains semantically identical. The full-screen TUI is not called screen-reader accessible; plain is the VoiceOver/Orca acceptance surface.

- [ ] **Step 1: Write selection/output/command RED tests**

```elixir
test "non-TTY and TERM dumb always select plain" do
  piped = %Environment{stdin_tty?: false, stdout_tty?: true, controlling_tty?: true, term: "xterm", no_color?: false}
  dumb = %Environment{stdin_tty?: true, stdout_tty?: true, controlling_tty?: true, term: "dumb", no_color?: false}
  assert {:ok, %{presenter: :plain}} = Options.select([], piped)
  assert {:ok, %{presenter: :plain}} = Options.select([], dumb)
end

test "plain three-run output is append-only, deduplicated, and control-free" do
  epoch = PlainFixtures.source_epoch()
  {presenter, records} = PlainFixtures.present_three_run_script()
  output = records |> Enum.filter(&match?({:stdout, _}, &1)) |> Enum.map_join(fn {:stdout, io} -> IO.iodata_to_binary(io) end)
  assert output == File.read!(PlainFixtures.golden_path())
  assert PlainFixtures.only_lf_controls?(output)
  assert presenter.last_sequences[{epoch, :conversation, "conversation-a", 1}] == 9
end
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/plain/options_test.exs apps/swarm_code_cli/test/swarm_code_cli/plain/presenter_test.exs apps/swarm_code_cli/test/swarm_code_cli/plain/command_test.exs
```

Expected: FAIL because the permanent plain surface does not exist.

- [ ] **Step 3: Implement one sanitized line protocol over typed deliveries**

Pass every external fragment through `SafeText`; fixed prompt syntax comes from `SafeText.chrome/1`. Scan both stdout and stderr records before returning them. Unknown commands return a static safe correction on stderr and preserve the active prompt/draft.

- [ ] **Step 4: Run GREEN in every degraded combination**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/plain --seed 0
NO_COLOR=1 mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/plain --seed 0
```

Expected: PASS for Unicode/ASCII, color/no-color, motion/reduced-motion, explicit/automatic plain.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/plain apps/swarm_code_cli/test
git commit -m "feat: add permanent accessible plain presentation"
```

---

### Task 16: Pin ExRatatui 0.13.0 and Prove the Isolated Adapter

**Hard gate:** Stop renderer work if a valid bounded input causes a reproducible BEAM crash, abort, non-cancellable NIF hang, input loss, or adapter-boundary leak. Preserve evidence and proceed only to the objective reject decision; do not patch neutral state around a renderer defect.

**Files:**
- Modify: `apps/swarm_code_cli/mix.exs`
- Modify: `mix.lock`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/cell.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/cell_frame.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/adapter.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/state.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/input.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/scene_compiler.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/cell_capture.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/cursor_sequence.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/package_identity.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/main_screen_mode.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_input_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_boundary_test.exs`

**Interfaces:**

```elixir
ExRatatui013.Adapter.init(%Renderer.Options{backend: {:cells, pos_integer(), pos_integer()}}) ::
  {:ok, ExRatatui013.State.t(), Capabilities.t()} | {:error, Renderer.Error.t()}

ExRatatui013.Adapter.init(%Renderer.Options{backend: :local}) ::
  {:ok, ExRatatui013.State.t(), Capabilities.t()} | {:error, Renderer.Error.t()}

ExRatatui013.Adapter.normalize_event(term(), ExRatatui013.State.t()) ::
  {:ok, Input.t(), ExRatatui013.State.t()} | {:ignore, ExRatatui013.State.t()} | {:error, Renderer.Error.t(), ExRatatui013.State.t()}

ExRatatui013.Adapter.draw(Scene.t(), ExRatatui013.State.t()) ::
  {:ok, ExRatatui013.State.t()} | {:error, Renderer.Error.t(), ExRatatui013.State.t()}

ExRatatui013.Adapter.shutdown(ExRatatui013.State.t()) :: :ok

ExRatatui013.Adapter.read_input(ExRatatui013.State.t(), 0..20) ::
  {:ok, Input.t(), ExRatatui013.State.t()} | {:idle, ExRatatui013.State.t()} | {:ignore, ExRatatui013.State.t()} | {:error, Renderer.Error.t(), ExRatatui013.State.t()}

ExRatatui013.Adapter.current_size(ExRatatui013.State.t()) ::
  {:ok, Size.t()} | {:error, Renderer.Error.t()}

ExRatatui013.Adapter.capture(Scene.t(), ExRatatui013.State.t()) ::
  {:ok, Renderer.CellFrame.t(), ExRatatui013.State.t()} | {:error, Renderer.Error.t(), ExRatatui013.State.t()}

%Renderer.Cell{
  row: non_neg_integer(), col: non_neg_integer(), grapheme: binary(),
  foreground: Scene.Color.t(), background: Scene.Color.t(),
  modifiers: [Scene.modifier()], continuation?: boolean()
}
```

- Add exact deps:

```elixir
{:ex_ratatui, "== 0.13.0"},
{:rustler, "== 0.38.0", runtime: false}
```

- Preserve the StreamData 1.4.0 test pin added in Task 4; do not add it a second time.
- `ExRatatui013.Adapter` declares `@behaviour SwarmCodeCLI.UI.Renderer` and implements all four callbacks exactly. Owner-private `read_input/2` accepts only 0-20 ms and polls at most 64 immediately ready events before yielding; `current_size/1` is the only other extension and returns a neutral positive Size.
- Verify the exact lock entry checksums from Global Constraints and version `0.13.0` in tests.
- Lock and assert `rustler_precompiled` 0.9.0, Rustler 0.38.0, and telemetry 1.4.2. `PackageIdentity.verify!/0` checks compile-time application version, Hex lock checksums, tag/source metadata, and expected OTP NIF ABI 2.17. It does not compare release-archive hashes to extracted NIFs. The build-time release identity manifest and runtime extracted-NIF check are separate later tasks.
- The headless adapter uses `ExRatatui.CellSession.new/2`, `draw/2`, `take_cells/1`, `resize/3`, and idempotent `close/1`; it does not use CellSession byte-stream input as a proxy for local Crossterm. The pinned local adapter uses `ExRatatui.Native.init_terminal/2`, `ExRatatui.draw/2`, explicit `ExRatatui.poll_event/1`, `ExRatatui.Native.restore_terminal/1`, and `ExRatatui.LocalInput.detach/0`/`reattach/1` inside this exact boundary rather than ExRatatui App/Server, whose poll-error handling and termination restoration are insufficient for this gate. All ExRatatui structs/resources remain in adapter state or locals.
- `SceneCompiler.compile/2` maps the closed Scene exhaustively using only ExRatatui 0.13.0 `Block`, `Clear`, `Paragraph`, rich `Text/Line/Span`, `Tabs`, optional `Scrollbar`, and optional SwarmCode-ticked `Throbber`. It renders virtual lists/run cards/agents/consensus/research/progress as bounded Paragraph/span groups in already resolved rectangles. It does not use ExRatatui TextInput, Textarea, Markdown, CodeBlock, Image, Viewport3D, Focus, Command, subscriptions, SSH/distribution, List/Table, custom widgets, or WidgetList. Composer text, selection, and caret are Paragraph spans from the neutral editor.
- Neutral Markdown blocks carry sanitized semantic lines/spans produced by Projector; the compiler renders those spans as Paragraphs and never hands raw Markdown to native parsing. Neutral Code blocks carry sanitized visible lines, language as inert body text, and horizontal offset; the compiler uses monospace-style Paragraph spans with no native syntax highlighting. The static spike keeps exact content and escaping while richer neutral parsing/highlighting remains a later bounded surface.
- Before constructing any widget, `SceneCompiler` validates schema version, Scene/backend size equality, every rectangle, visible-item/height bounds, palette role, cursor bounds, and SafeText provenance. It catches bridge encoding exceptions and returns a static typed error without logging content. It never calls ExRatatui layout NIFs because Projector already resolved cell rectangles.
- Input normalization maps fixed ExRatatui string codes/modifiers to neutral atoms, printable scalar keys to `{:text_fragment, kind, fragment, modifiers}`, paste to one reducer-facing payload bounded at 262,144 bytes, resize to positive `Size`, focus events, and mouse only when enabled. Exact 0.13.0 emits no composition lifecycle input, so adapter capabilities mark it unavailable and normalizer tests never fabricate support. Unknown/null values return `:ignore`/typed error and never atomize. `poll_event/2` treats every ExRatatui `{:error, reason}` as terminal failure; it never ignores and rearms after a poll error. CellSession raw-byte parsing is not used as local-input evidence because it omits mouse/focus and scalarizes bracketed paste; those structs are injected directly in headless normalizer tests, while real local Crossterm input is tested through PTY.
- `CellCapture` maps the ExRatatui snapshot immediately into `CellFrame`; it derives wide-cell continuation markers with `Width`, includes Scene cursor/focus/action metadata, and releases every ExRatatui struct before returning. This compensates for `CellSession.Cell` not explicitly marking a wide trailing cell while testing the exact visual result.
- `CursorSequence.encode/1` accepts only a validated neutral cursor and returns fixed CSI hide or one-based row/column position-plus-show iodata. It is emitted only after a successful local draw. No arbitrary string enters control output. The theme sets no underline color because CellSession cannot expose it.
- `MainScreenMode.after_init/1` implements the exact-pinned `--no-alt-screen` feasibility path: after Native init and before any Scene draw it emits a fixed LeaveAlternateScreen sequence, marks the adapter main-screen-only, and performs every later draw/cursor operation on that screen. PTY tests seed scrollback before init and prove it remains, prove no later EnterAlternateScreen sequence occurs, and prove shutdown does not erase output. If this backend behavior is not stable on any target, the ExRatatui no-alt dimension fails and the renderer is rejected; the permanent neutral option remains and must be implemented by the selected fallback before release.
- ExRatatui adapter state derives a redacted Inspect representation that omits terminal references, input handles, widgets, and native resources; terminal errors are mapped to static codes before logging and never interpolate ExRatatui error terms that may contain Scene data.

- [ ] **Step 1: Write dependency, adapter, input, and boundary RED tests**

Assert exact package/lock checksums, source/tag identity, acknowledge the fetched dependency's 5,011,440-byte `native/ex_ratatui/erl_crash.dump` while proving it is not Git-tracked/vendor-copied, all four representative scenes draw through CellSession, all event variants normalize, 10,000 injected normalized key events have no loss/duplicate, 100 constructed bracketed-paste events each arrive once, resize preserves neutral editor state, every physical cursor control sequence is fixed/coordinate-bounded, and idempotent shutdown releases the CellSession. The assembled-release crash-dump exclusion belongs to the release task. Record the post-decode paste cap as defense in depth; do not mark the native preallocation-bound dimension passed here.

Re-run the architecture scanner after dependency addition and recursively inspect returned `CellFrame`, reducer state, Scene, effects, DTOs, and plain presenter for any struct module prefixed `Elixir.ExRatatui` or `Elixir.Rustler`.

- [ ] **Step 2: Run RED before dependency addition**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_input_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_boundary_test.exs
```

Expected: FAIL because the exact dependency and adapter do not exist.

- [ ] **Step 3: Add the exact dependency and smallest exhaustive adapter**

```bash
mise exec -- mix deps.get
```

Verify `mix.lock` manually and by test. Draw only the projector-resolved visible window. If a live `:user_drv_reader` exists and `LocalInput.detach/0` returns `:not_detached`, shut down the initialized terminal, restore the baseline, and fail closed to plain rather than running two input readers. Do not call `ExRatatui.set_terminal_title/1`, image protocols, clipboard helpers, distributed transport, SSH transport, Session raw parsing, ExRatatui App/Server runtime, ExRatatui reducer state, or renderer-owned textarea/text-input state.

- [ ] **Step 4: Run GREEN and architecture guard**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs --seed 0
```

Expected: PASS; only adapter paths mention renderer implementation types.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli mix.lock
git commit -m "feat: isolate exact ExRatatui adapter"
```

---

### Task 17: Commit the Complete Exact Cell, Style, Cursor, Focus, and Action Goldens

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/golden.ex`
- Create: `apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.goldens.ex`
- Create: `apps/swarm_code_cli/test/fixtures/goldens/ex_ratatui_013/manifest.json`
- Create: `apps/swarm_code_cli/test/fixtures/goldens/ex_ratatui_013/*.json` (exact 69 files under the naming scheme below)
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_matrix_test.exs`

**Interfaces:**

```elixir
Renderer.Golden.capture(binary(), Scene.t(), Renderer.CellFrame.t()) :: map()
Renderer.Golden.encode(map()) :: iodata()
Renderer.Golden.verify_all(Path.t()) :: :ok | {:error, [binary()]}
Mix.Tasks.SwarmCode.Tui.Goldens.run(["--check" | "--accept"])
```

- File names are `{scene}--{columns}x{rows}--{color}[--ascii].json`. The manifest lists and SHA-256 hashes exactly:
  - `chat`, `swarm`, `consensus`, `research` × `80x24`, `120x40`, `160x50` × `truecolor`, `ansi256`, `ansi16`, `monochrome`: 48;
  - `workspace` × `170x34`, `50x16`, `50x14` × four color modes: 12;
  - `too-small--49x13--monochrome--ascii`: 1;
  - four representative scenes × `80x24--monochrome--ascii`: 4;
  - `question` and `destructive-confirmation` × `120x40` × truecolor/monochrome: 4.
- Total is exactly 69. All IDs, virtual time, elapsed labels, prices, stream chunks, selection, and cursor are fixed.
- Each canonical JSON record includes schema version, fixture ID, size/class, focused region/item, sorted action IDs, cursor row/column/visibility, and row-major cells. Every cell records grapheme, foreground, background, sorted modifiers, and wide continuation. Run-length encoding may compress identical adjacent cells, but `verify_all/1` must expand to exactly `columns * rows` cells before comparison.
- Cursor fields in these JSON records are the renderer-neutral semantic cursor because CellSession exposes no physical cursor. The same test invokes `ExRatatui013.CursorSequence.encode/1` and stores its fixed expected bytes in the cursor record; Task 19 must observe those exact bytes on a real PTY after the frame. The matrix fails if semantic, encoded, and PTY-observed positions differ. Colored underline is not used because CellSession omits underline color.
- `--check` never writes. `--accept` refuses unless `UPDATE_GOLDENS=1`; it writes same-directory temporary files then atomically renames and rewrites the manifest last. No test silently refreshes expected output.

- [ ] **Step 1: Write a RED matrix test with no goldens present**

```elixir
test "the renderer spike has the exact 69-frame evidence set" do
  manifest = GoldenFixtures.read_manifest!()
  assert manifest["schema_version"] == 1
  assert length(manifest["frames"]) == 69
  assert :ok = Golden.verify_all(GoldenFixtures.root())
end
```

Also mutate one cell style, continuation, cursor, focus ID, and action ID in task-owned fixture copies and assert each produces a field-specific diff.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_matrix_test.exs
```

Expected: FAIL because the manifest and 69 frames do not exist.

- [ ] **Step 3: Implement deterministic capture and explicitly accept first goldens**

```bash
UPDATE_GOLDENS=1 mise exec -- mix swarm_code.tui.goldens --accept
mise exec -- mix swarm_code.tui.goldens --check
```

Inspect representative truecolor, monochrome, ASCII, `50x14`, and question frames as expanded rows. Confirm no overlap, clipped action, missing focus, raw control, or untrusted approval label before treating the generated files as expected behavior.

- [ ] **Step 4: Run GREEN**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_matrix_test.exs --seed 0
```

Expected: PASS and zero writes from the test process.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib apps/swarm_code_cli/test/fixtures/goldens apps/swarm_code_cli/test/swarm_code_cli/ui/renderer
git commit -m "test: lock exact TUI cell goldens"
```

---

### Task 18: Implement the Single TerminalOwner and Revision-Safe Local Draw Loop

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/terminal_owner.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/ui_supervisor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/host.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/selector.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs`

**Interfaces:**

```elixir
TerminalOwner.start_link(runtime: pid(), scene_slot: :ets.tid(), adapter: module(), options: Renderer.Options.t()) :: GenServer.on_start()
TerminalOwner.draw(server(), draw_token :: binary(), scene_revision :: non_neg_integer()) :: :ok
TerminalOwner.suspend(server(), command_sequence :: non_neg_integer()) :: :ok
TerminalOwner.resume(server(), command_sequence :: non_neg_integer()) :: :ok
TerminalOwner.shutdown(server(), deadline_ms :: non_neg_integer()) :: :ok | {:error, :deadline_exceeded}
```

- TerminalOwner is the only BEAM process that calls adapter init/read/current-size/draw/shutdown and writes fixed renderer control sequences. Suspend performs shutdown/restore and retains only neutral suspended metadata; resume calls init again. It stores live adapter resource state but never Scene, ActionTable, draft, DTO, or transcript. It accepts only draw token/revision and reads the exact protected SceneSlot entry transiently.
- The allowed-path `selector.ex` defines generic `SwarmCodeCLI.UI.Renderer.Selector.primary/0`; only that file returns `ExRatatui013.Adapter`. Demo/Application call the generic selector and therefore contain no renderer implementation alias/type/string outside the architecture exemption.
- Use a proper GenServer with `Process.flag(:trap_exit, true)`. Record the supervisor parent PID and explicitly handle its `{:EXIT, parent, reason}` by stopping input polls, invoking adapter shutdown, restoring internal baseline, acknowledging LauncherControl, and then exiting. Do not rely on a whole-loop `try/after`. Child spec uses a 5,000 ms shutdown; if orderly restoration exceeds it, the permanent fake release terminates the client VM so the external launcher—not a restarted terminal child—performs final restoration.
- UISupervisor is `:one_for_all` with zero restart intensity for unexpected TerminalOwner death in the fake release. TerminalOwner is not restarted into an unknown terminal state. Normal resume is an explicit in-process state transition that reinitializes the same owner PID and increments terminal generation.
- Before every local draw, call adapter `current_size/1`. If it differs from the Scene size, do not draw; send neutral `{:resize, size}` and `{:terminal_capabilities, next_generation, capabilities}` actions to SessionRuntime, then await a matching newer Scene revision. Draw success/error is returned as `{:draw_result, draw_token, scene_revision, result}`. Stale slots/tokens never clear current draw state.
- Input polling uses cancellable 0-20 ms calls and drains at most 64 ready events before checking owner messages. Every renderer poll error is terminal. Init/resume sends capability/lifecycle actions; suspend stops polling, restores terminal/input, sends `:suspended`, and waits for launcher protocol; resume redetects size/capabilities, increments generation, sends `:resumed`, and requests the latest full Scene.
- Internal baseline restoration is best effort plus exact checked `stty -g`; the external launcher remains the final safety boundary. Any internal mismatch, including Darwin PENDIN, is a failed lifecycle fact even when the launcher repairs it.

- [ ] **Step 1: Write TerminalOwner RED tests**

Use a fake adapter and protected SceneSlot. Assert only revision tokens enter the mailbox, exact size match draws once, resize race does not paint stale cells, draw errors surface, 64-event fairness, capability generation on resume, explicit parent-exit restoration, no automatic restart, and redacted `format_status/1`.

```elixir
assert :ok = TerminalOwner.draw(owner, "draw-12", 12)
assert_receive {:draw_result, "draw-12", 12, :ok}
FakeAdapter.resize(owner_adapter, %Size{columns: 81, rows: 24})
assert :ok = TerminalOwner.draw(owner, "draw-13", 13)
assert_receive {:terminal_input, {:resize, %Size{columns: 81, rows: 24}}}
refute_receive {:fake_adapter_drew, 13}
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs
```

Expected: FAIL because TerminalOwner does not exist.

- [ ] **Step 3: Implement the owner and supervisor failure policy**

Use explicit state-machine fields for `:initializing | :running | :suspending | :suspended | :resuming | :closing`, terminal generation, current poll timer, adapter state, supervisor parent, and launcher-control PID. Cancel/flush each timer before transition. Never interpolate native error terms or Scene values into logs.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs --seed 0
git add apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs
git commit -m "feat: own revision-safe terminal drawing"
```

---

### Task 19: Add the External Signal/Restoration Launcher and Real PTY Lifecycle

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/ui_supervisor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/launcher_control.ex`
- Create: `scripts/acceptance/tui_external_launcher.sh`
- Create: `scripts/acceptance/tui_pty_driver.py`
- Create: `scripts/acceptance/tui_pty.sh`
- Create: `apps/swarm_code_cli/test/support/pty_harness.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/launcher_control_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs`

**Interfaces:**

```text
launcher -> child control record: v1 NONCE SEQUENCE detach|shutdown|suspend|resume LF
child -> launcher acknowledgment: v1 NONCE SEQUENCE ready|restored|failed LF
child -> launcher request: v1 NONCE SEQUENCE request_suspend LF
```

```elixir
LauncherControl.start_link(owner: pid(), control_fifo: Path.t(), ack_fifo: Path.t(), nonce: binary(), launcher_pid: pos_integer()) :: GenServer.on_start()
LauncherControl.ack(server(), non_neg_integer(), :ready | :restored | :failed) :: :ok
LauncherControl.request_suspend(server()) :: :ok
```

- The POSIX outer launcher creates one `0700` `mktemp -d` directory and two mode-`0600` FIFOs before child boot, opens both ends to avoid open-order deadlock, generates a 128-bit lowercase-hex nonce, exports only FIFO paths/nonce/launcher PID, and waits for the child's `ready` record before raw mode. Records are at most 128 bytes, newline terminated, strictly increasing, exact-token parsed, and nonce checked. The directory/FIFOs are removed in the EXIT trap.
- The child registers only supported `System.trap_signal(:sigusr2, id, fun)`; the callback sends a message and returns immediately. The launcher owns external HUP/INT/TERM/TSTP/CONT traps. Do not call unsupported `System.trap_signal` for SIGINT or SIGCONT, do not replace the VM SIGTERM handler, and do not install a child TSTP trap.
- UISupervisor starts LauncherControl and confirms its FIFO reader/USR2 trap ready before TerminalOwner enters raw mode; it then registers the TerminalOwner PID with LauncherControl. A signal arriving during boot is queued as one closed command and cannot bypass restoration.
- For HUP/INT/TERM, launcher writes `detach` or `shutdown`, signals child SIGUSR2, and starts one owned escalation watchdog: wait 5 seconds for matching restored ack, then TERM; wait 2 seconds, then KILL. On ack, cancel and reap the watchdog, wait for the exact child, preserve its exit code, and run final restore. A direct signal/abrupt exit of the BEAM is detected by `wait`; the launcher restores without requiring child callbacks.
- Ctrl+Z becomes neutral suspend input. Child sends `request_suspend` to launcher and SIGUSR1. For launcher TSTP or that request, launcher sends the ordinary `suspend` control record—not TSTP—to the child, waits up to 2 seconds for `restored`, sends SIGSTOP to the child, resets its own TSTP disposition and stops itself once. On CONT/foreground, launcher reinstalls the trap, sends SIGCONT to child, sends `resume`, and waits for `ready`. No TSTP is forwarded into a trapped child, so recursion is impossible.
- Launcher captures validated exact `stty -g` before child start. Its EXIT handler, regardless of child status/escalation, writes fixed disable-mouse/focus/paste, leave-alt, and show-cursor sequences directly to `/dev/tty`, then applies the exact baseline and writes a sentinel. If launcher and child are both SIGKILLed, restoration is not claimed; document `reset; stty sane`.
- `tui_pty_driver.py` uses `pty.openpty`, forks, calls `setsid`, applies `TIOCSCTTY` to the slave, duplicates slave to fd 0/1/2, creates a dedicated process group/foreground pgrp, then execs the launcher. Parent retains master and slave FDs, uses selectors/readiness records rather than sleeps, sends signals to the exact launcher or child requested by the case, and compares `stty -g` on the retained slave before/after. This makes `/dev/tty` and job control real.
- PTY modes are normal, compiler/draw/poll error, parent supervisor shutdown, child abrupt exit, launcher INT/TERM/HUP, Ctrl+Z, launcher TSTP/CONT, alt-screen, and no-alt-screen. No-alt seeds main-screen scrollback, verifies the fixed immediate LeaveAlternateScreen before first draw, rejects any later EnterAlternateScreen, and verifies preserved scrollback/final output. Failure records the ExRatatui no-alt dimension rejected while the permanent neutral option remains.

- [ ] **Step 1: Write launcher protocol and PTY RED tests**

Assert nonce/sequence/bounds, stale/replayed record rejection, one acknowledgment, exact escalation order, no recursive suspend, signal exit-code preservation, controlling TTY, cursor/physical position bytes, exact stty/PENDIN equality before internal and after external restore, final sentinel, and zero surviving watchdog/FIFO/process.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/launcher_control_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs
```

Expected: FAIL because launcher control and PTY harness do not exist.

- [ ] **Step 3: Implement one non-recursive launcher state machine**

Shell states are `booting/running/waiting_restore/stopped/resuming/exited`; all traps dispatch through one transition function. Validate PID/nonce/sequence before `kill` or FIFO use. Launcher diagnostics go to a separate bounded file/stderr, never TUI stdout. TerminalOwner explicitly closes before acknowledgment; external EXIT cleanup is unconditional.

- [ ] **Step 4: Run focused GREEN lifecycle cases**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/launcher_control_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs --seed 0
scripts/acceptance/tui_pty.sh --cycles 5 --modes normal,draw-error,poll-error,parent-shutdown,sigint,sigterm,sighup,ctrl-z,sigtstp-sigcont,no-alt-screen
```

Expected: PASS 50 cases with exact stty, restored screen/cursor, signal forwarding/escalation, no recursion, and no live child. Full 1,000-cycle native evidence is later.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli scripts/acceptance/tui_external_launcher.sh scripts/acceptance/tui_pty_driver.py scripts/acceptance/tui_pty.sh
git commit -m "feat: guard terminal lifecycle externally"
```

---

### Task 20: Run Native Fuzz and Sanitizer Cases Only in Disposable Watchdog Processes

**Files:**
- Modify: `apps/swarm_code_cli/test/test_helper.exs`
- Create: `apps/swarm_code_cli/test/fixtures/renderer/fuzz_corpus.json`
- Create: `apps/swarm_code_cli/test/fixtures/renderer/unicode_input.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/fuzz_orchestrator_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/unicode_input_test.exs`
- Create: `scripts/acceptance/tui_fuzz_worker.exs`
- Create: `scripts/acceptance/tui_fuzz_watchdog.py`
- Create: `scripts/acceptance/tui_renderer_sanitizers.sh`
- Create: `rust-toolchain-tui-sanitizer.toml`

**Interfaces:**

```text
tui_fuzz_watchdog.py --corpus FILE --result-dir DIR --timeout-ms 5000 --rss-mib 512
tui_fuzz_worker.exs CASE_ID CORPUS RESULT_FILE
```

- No fatal NIF fuzz case runs in the ExUnit/precommit BEAM. ExUnit tests validate corpus schema and spawn the watchdog; each shard launches a fresh OS process, atomically writes case ID/input hash before loading the NIF, enforces wall timeout and RSS/address-space limits, and records exit/signal/stderr hash afterward. Segfault, abort, timeout, RSS breach, missing result, or sanitizer finding becomes structured rejection evidence while the parent survives.
- Corpus covers malformed/zero/huge rectangles, constraints, block variants, action IDs, invalid bytes, incomplete terminal sequences, event/resize storms, Unicode scalars, and bounded paste. Invalid Scene is rejected before NIF. Valid bounded input may return success/static error only.
- Paste cases distinguish adapter post-decode cap from native preallocation bound. Real PTY shards drive fragmented, 262,144-byte, one-byte-over, and escalating multi-megabyte bracketed paste under the watchdog. Since exact 0.13.0 exposes no preallocation limit, record this dimension failed unless contrary exact-artifact measurement proves bounded allocation before delivery.
- Unicode normalizer/editor cases cover accents, Georgian, RTL, CJK, ambiguous symbols, modifiers, flags, ZWJ, VS15/16, Option/Alt, Shift+Tab, press/repeat/release, focus, enhanced fallback, mouse-off/on, 10,000 key events, and 100 constructed paste events. Injected neutral composition tests pass editor/keymap; ExRatatui IME capability remains unavailable.
- `rust-toolchain-tui-sanitizer.toml` pins nightly-2026-08-13, minimal profile, rust-src/clippy. Sanitizer runner source-builds exact Hex native code with Rustler 0.38.0 under ASan/LeakSanitizer and invokes the same disposable workers.

- [ ] **Step 1: Write RED orchestrator tests**

Use a harmless sentinel worker that exits normally and fixtures that deliberately exit by signal, exceed RSS, hang, and omit result. Assert parent ExUnit survives and every case ID has one terminal status. Do not invoke the real NIF until the watchdog tests pass.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/fuzz_orchestrator_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/unicode_input_test.exs
```

Expected: FAIL because corpus/workers/watchdog do not exist.

- [ ] **Step 3: Implement disposable orchestration and source sanitizer**

Python uses `subprocess`, selectors, `resource.setrlimit`, monotonic deadlines, exact child PIDs/process groups, TERM grace then KILL/reap. Bound captured output and hash overflow instead of accumulating it. Never retry a crashing case in the same BEAM.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/fuzz_orchestrator_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/unicode_input_test.exs --seed 0
scripts/acceptance/tui_fuzz_watchdog.py --corpus apps/swarm_code_cli/test/fixtures/renderer/fuzz_corpus.json --result-dir "$TMPDIR/tui-fuzz" --timeout-ms 5000 --rss-mib 512
scripts/acceptance/tui_renderer_sanitizers.sh
git add apps/swarm_code_cli scripts/acceptance rust-toolchain-tui-sanitizer.toml
git commit -m "test: isolate native renderer fuzzing"
```

Expected: orchestrator passes; any real NIF case failure is preserved as renderer-rejection evidence rather than crashing the parent.

---

### Task 21: Measure Rendering, Windowing, and Resources With Explicit Long-Test Tags

**Files:**
- Modify: `apps/swarm_code_cli/test/test_helper.exs`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/probe.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/performance_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/resource_test.exs`
- Create: `scripts/acceptance/tui_soak.exs`
- Create: `scripts/acceptance/tui_resource_watchdog.py`

**Interfaces:**

```elixir
Renderer.Probe.frame_samples(Scene.t(), pos_integer(), keyword()) :: [non_neg_integer()]
Renderer.Probe.input_samples(pid(), [Input.t()], keyword()) :: [non_neg_integer()]
Renderer.Probe.beam_snapshot(pid()) :: %{heap_bytes: non_neg_integer(), mailbox: non_neg_integer(), monitors: non_neg_integer(), timers: non_neg_integer(), processes: non_neg_integer()}
```

- `test_helper.exs` calls `ExUnit.configure(exclude: [renderer_gate: true])`. Long tests use `@tag :renderer_gate` and run only with `mix test --include renderer_gate exact_file`; `RENDERER_GATE` is not treated as magic configuration. Ordinary precommit runs their small unit helpers but not 30-minute work.
- Thresholds are 120x40 frame p95 ≤16 ms, input-to-painted p95 ≤50 ms with three streams, idle CPU ≤2 percent one core, active motion 15-30 FPS maximum, no unconditional reduced-motion redraw, and responsive bounded storms. Record raw samples/hardware before percentiles.
- A 10,000-message source projects visible window plus two-item overscan only. Cache is byte/count bounded; eviction exactly recomputes; final fake content hashes match.
- ExRatatui 0.13.0 exposes no native ResourceArc live counter. Do not invent `native_sessions`. `tui_resource_watchdog.py` instead runs repeated fresh client processes and records child RSS high-water/settled RSS, open FD count, exit status, plus BEAM heap/mailbox/ETS/timer/monitor/process counts from bounded result records. The 30-minute soak compares post-warmup/post-GC checkpoints and 1,000 create/draw/close fresh-process cycles. This is honest external leak evidence, not proof of individual ResourceArc destruction.

- [ ] **Step 1: Write RED tag/window/resource tests**

Assert ordinary test selection excludes tagged cases, `--include renderer_gate` executes them, hardware metadata is mandatory, 10,000 source rows encode only visible+overscan, and external sentinel workers expose RSS/FD results.

- [ ] **Step 2: Run RED explicitly including long-tag code paths**

```bash
mise exec -- mix test --include renderer_gate apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/performance_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/resource_test.exs
```

Expected: FAIL because probes/watchdog do not exist; test count must be nonzero.

- [ ] **Step 3: Implement measured probes and watchdog**

Use monotonic time only outside Reducer, GC before checkpoints, bounded result files, exact OS child/process-group ownership, and hardware metadata from the preflight record.

- [ ] **Step 4: Run local GREEN and commit**

```bash
mise exec -- mix test --include renderer_gate apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/performance_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/resource_test.exs --seed 0
mise exec -- mix test apps/swarm_code_cli/test --seed 0
git add apps/swarm_code_cli scripts/acceptance/tui_soak.exs scripts/acceptance/tui_resource_watchdog.py
git commit -m "test: measure TUI rendering resources"
```

Expected: local metrics are diagnostic; target acceptance comes from native evidence.

---

### Task 22: Build the Fake-Only Release and Separate Runtime Identity Hashes

**Files:**
- Modify: `mix.exs`
- Modify: `apps/swarm_code_cli/mix.exs`
- Modify: `config/runtime.exs`
- Modify: `rel/env.sh.eex`
- Create: `rel/vm.args.eex`
- Create: `rel/overlays/bin/swarm-code-demo`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/application.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/demo/supervisor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/demo/main.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/demo/finite_script.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/release_identity.ex`
- Create: `apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.release_manifest.ex`
- Create: `apps/swarm_code_cli/test/fixtures/release/identity-precompiled.json`
- Create: `apps/swarm_code_cli/test/fixtures/release/identity-source-built.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/demo/application_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/demo/finite_script_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/release_config_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/identity_test.exs`

**Interfaces:**

```elixir
Mix.Tasks.SwarmCode.Tui.ReleaseManifest.run([release_root(), output_path()]) :: :ok
ExRatatui013.ReleaseIdentity.verify_loaded_nif(identity_manifest()) :: :ok | {:error, Renderer.Error.t()}
```

- Application is idle by default; exact `SWARM_CODE_BOOT=fake_demo` starts fake composition. Unknown strings fail static. The release `:swarm_code_tui_spike` seeds core/CLI only, excludes daemon, includes ERTS, sets distribution none, and inventories required renderer/OTP transitive apps without starting SSH/distribution listeners.
- Overlay command is the audited non-exec external launcher from Task 19. It accepts only permanent presentation flags, complete script, and fixed lifecycle fault modes; it forwards signals, waits, restores, and preserves child exit.
- Build task generates `priv/renderer_identity.json` before assembly. Fields separately identify: Hex inner/outer checksum; tag object/source commit; target/NIF ABI; `build_kind` precompiled or source; precompiled archive URL/SHA-256 or null; extracted loaded `.so/.dylib` relative path/SHA-256; Cargo.lock SHA-256; source crate/source-build output hashes or null; OTP/Elixir/Rust versions. Never compare archive hash to extracted library hash.
- Runtime resolves only `ExRatatui.Native.load_from/0` inside the exact adapter, hashes that extracted file, and matches the embedded manifest before native init. Linux source builds bake their new extracted hash. The build task also emits `release-dependencies.json` listing every assembled application, version, beam/native file hash, architecture, and link metadata.
- Tests acknowledge the dependency-source `erl_crash.dump` but reject it from Git-tracked files, source archives, dependency manifest, and assembled release. Release manifest also rejects non-selected NIF siblings, compiler/Cargo/Mix, daemon/Exqlite, and runtime downloaders.

- [ ] **Step 1: Write RED release and identity tests**

Inspect root release config, both identity fixtures, tampered archive-vs-extracted hashes, source-build fields, assembled dependency manifest schema, fake finite execution, and crash-dump exclusion.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/demo/application_test.exs apps/swarm_code_cli/test/swarm_code_cli/demo/finite_script_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/release_config_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/identity_test.exs
```

Expected: FAIL because release/demo/identity manifest do not exist.

- [ ] **Step 3: Build and verify locally without touching user state**

```bash
root=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-home.XXXXXX")
mkdir -p "$root/home"
HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" EX_RATATUI_BUILD="${SWARM_LINUX_BUILD_FROM_SOURCE:-0}" MIX_ENV=prod mise exec -- mix release swarm_code_tui_spike --overwrite
mise exec -- mix swarm_code.tui.release_manifest _build/prod/rel/swarm_code_tui_spike _build/prod/rel/swarm_code_tui_spike/release-dependencies.json
env -i HOME="$root/home" XDG_CONFIG_HOME="$root/config" XDG_DATA_HOME="$root/data" XDG_STATE_HOME="$root/state" XDG_CACHE_HOME="$root/cache" TERM=dumb PATH=/usr/bin:/bin _build/prod/rel/swarm_code_tui_spike/bin/swarm-code-demo --plain --script complete
if find "$root" -type f -print -quit | grep -q .; then echo "fake demo wrote user/XDG state" >&2; false; fi
```

Expected: finite fake output, no user/XDG file, exact identity/dependency manifests, no daemon/crash dump/runtime downloader.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/demo apps/swarm_code_cli/test/swarm_code_cli/release --seed 0
git add mix.exs apps/swarm_code_cli config rel
git commit -m "build: assemble fake TUI identity release"
```

---

### Task 23: Acquire and Lock Reproducible Renderer License/SBOM Inputs

**Files:**
- Modify: `NOTICE`
- Create: `scripts/ci/tui_dependency_acquire.exs`
- Create: `scripts/ci/tui_dependency_audit.exs`
- Create: `governance/tui-license-policy.json`
- Create: `governance/tui-license-inputs.json`
- Create: `third_party/tui-license-texts/`
- Create: `docs/evidence/tui-renderer/sbom.spdx.json`
- Create: `docs/evidence/tui-renderer/third-party-notices.txt`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/license_evidence_test.exs`

**Interfaces:**

```text
tui_dependency_acquire.exs --accept CACHE_DIR
tui_dependency_audit.exs --check
```

- Acquisition reads exact mix.lock plus ExRatatui Hex package Cargo.lock. For every registry crate it downloads the immutable `.crate`, verifies Cargo.lock checksum before safe extraction, then obtains normalized Cargo metadata/license expression and all LICENSE/COPYING/NOTICE files. Hex sources are accepted only after lock checksum verification. Vendored/path crates are hashed from the verified Hex package. No license is inferred from Cargo.lock alone.
- `--accept` requires a temporary cache, closed SPDX-choice policy, and explicit human adjudication for dual/custom terms. It commits bounded unique license texts plus `tui-license-inputs.json` mapping every dependency/version/source/checksum to license expression, chosen obligations, copyright/notice hashes, and acquisition URL. It includes ExRatatui/Mauricio Cassola, Po Chen syntax, and vendored render3d/ratatui-3d.
- `--check` is offline: verify committed hashes, reconstruct SPDX/notices deterministically, compare to outputs, and compare dependency identity to mix.lock/Cargo.lock/release-dependencies manifest. Unknown/missing/ambiguous license fails.

- [ ] **Step 1: Write license-evidence RED tests**

Use fixture crates with good/bad checksum, path traversal, absent license, dual license, and notice. Assert no generated pass without verified source/license text.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/license_evidence_test.exs
```

Expected: FAIL because verified acquisition/audit do not exist.

- [ ] **Step 3: Acquire, adjudicate, and reproduce**

```bash
cache=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-license.XXXXXX")
MIX_ENV=prod mise exec -- mix release swarm_code_tui_spike --overwrite
mise exec -- mix swarm_code.tui.release_manifest _build/prod/rel/swarm_code_tui_spike _build/prod/rel/swarm_code_tui_spike/release-dependencies.json
mise exec -- elixir scripts/ci/tui_dependency_acquire.exs --accept "$cache"
mise exec -- elixir scripts/ci/tui_dependency_audit.exs --check
```

Expected: deterministic SPDX/notices and no unchecked dependency.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/license_evidence_test.exs
git add NOTICE scripts/ci governance third_party/tui-license-texts docs/evidence/tui-renderer/sbom.spdx.json docs/evidence/tui-renderer/third-party-notices.txt apps/swarm_code_cli/test/swarm_code_cli/release/license_evidence_test.exs
git commit -m "docs: lock renderer dependency obligations"
```

---

### Task 24: Scaffold and Push Automated Four-Target Evidence Tooling

**Files:**
- Create: `apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.evidence.ex`
- Create: `scripts/acceptance/tui_native_inspect.sh`
- Create: `scripts/acceptance/tui_release_smoke.sh`
- Create: `scripts/acceptance/tui_target_gate.sh`
- Create: `scripts/acceptance/tui_native_dispatch.sh`
- Create: `scripts/acceptance/tui_evidence_validate.exs`
- Create: `.github/workflows/tui-renderer-native.yml`
- Create: `apps/swarm_code_cli/test/fixtures/evidence/valid-target.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/native_dispatch_test.exs`

**Interfaces:**

```elixir
Mix.Tasks.SwarmCode.Tui.Evidence.run([target(), output_path()] | ["--check" | "--decision", evidence_directory()]) :: :ok
```

- Workflow accepts required expected SHA and uses only complete-preflight native runner labels. Jobs run contracts, 69 goldens, scenario, disposable fuzz/sanitizer, 1,000 PTY cycles, 30-minute tagged soak, no-alt, offline clean-host release, and native inspection. Linux source-builds on exact 22.04 native architecture.
- Inspection separates asset archive/extracted/source-build hashes, validates embedded identity/dependency manifests, and rejects wrong architecture/RPATH/shared libs, GLIBC >2.35/pidfd symbols, crash dump, runtime toolchain/downloader, and daemon/Exqlite.
- Dispatch script validates complete infrastructure evidence, online runner labels, exact remote SHA, and one workflow run. It uses an absolute 10,800-second deadline, bounded five-second polling, cancel plus 60-second bounded cancellation observation, and records unresolved cancellation. No open-ended watch.
- Evidence schema includes all identities/licenses, native paste/IME/no-alt/cursor/stty facts, raw command hashes, metrics/PTYS, permanent-asset references, and pass/fail.

- [ ] **Step 1: Write RED tooling/dispatch tests**

Use valid/tampered manifests and fake `gh` responses for unavailable runner, mismatched SHA, timeout/cancel, archive-vs-NIF confusion, GLIBC 2.39, crash dump, emulation, missing raw asset, and three-of-four.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/native_dispatch_test.exs
```

Expected: FAIL because tooling/workflow do not exist.

- [ ] **Step 3: Implement, run GREEN, commit, and push workflow commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/native_dispatch_test.exs
chmod 0755 scripts/acceptance/tui_native_inspect.sh scripts/acceptance/tui_release_smoke.sh scripts/acceptance/tui_target_gate.sh scripts/acceptance/tui_native_dispatch.sh
git add apps/swarm_code_cli scripts/acceptance .github/workflows/tui-renderer-native.yml
git commit -m "ci: scaffold native renderer evidence"
git push origin feature/tui-interaction-spike
```

Expected: remote branch contains exact workflow/tools commit before dispatch.

---

### Task 25: Run Automated Native Gates and Commit Permanent Draft References

**Files:**
- Create after automated runs: `docs/evidence/tui-renderer/automated/macos-arm64.json`
- Create after automated runs: `docs/evidence/tui-renderer/automated/macos-x86_64.json`
- Create after automated runs: `docs/evidence/tui-renderer/automated/ubuntu-22.04-arm64.json`
- Create after automated runs: `docs/evidence/tui-renderer/automated/ubuntu-22.04-x86_64.json`

**Interfaces:**
- Consumes Task 24's exact pushed commit/workflow.
- Produces four truthful automated records plus draft evidence-only release asset references.

- NIF ABI 2.17 archive hashes are macOS arm64 `454b5e7d4f2002837e55d00e8fc8b9eea43fca165b9d6b82ab75d0bd358fc7a4`, macOS x86_64 `5600864b8083a1f61c57831a28ea0dd342ac89abed8c71d51d058c6a672daa2d`, Linux x86_64 GNU `95a23a060aadc58adea3fefd724dc7bb8ad4aead3152fac0ee62f130fe510320`, and rejected Linux arm64 GNU `1eb8f5b52d774c71590451ada25fef6423ff2e0419e09736676ca97df05d5f0c`. Observed macOS-arm64 extracted dylib is separately `ba42cc015e001296dd5beb78fb5262ff3b7866b7bc350cca08eb98ba1cfb8d9d`; other extracted/source hashes come from assembled bytes.
- Raw release/log/PTY/sanitizer/metric/manifests go to draft evidence-only prerelease `tui-spike-evidence-<full-sha>` with attestations. Automated JSON stores draft asset ID/digest; final permanent URL is added only after Task 26 seals/publishes immutably. Expiring workflow artifacts alone never satisfy evidence.

- [ ] **Step 1: Verify clean exact remote state and dispatch bounded run**

```bash
expected_sha=$(git rev-parse HEAD)
test -z "$(git status --short)"
test "$(git rev-parse origin/feature/tui-interaction-spike)" = "$expected_sha"
scripts/acceptance/tui_native_dispatch.sh --ref feature/tui-interaction-spike --expected-sha "$expected_sha" --deadline-seconds 10800
```

Expected: four result records or truthful failed/incomplete records; dispatcher cancels by deadline.

- [ ] **Step 2: Validate raw draft assets and records**

```bash
mise exec -- mix swarm_code.tui.evidence --check docs/evidence/tui-renderer/automated
```

Expected: schema/digests/attestation valid even if a renderer gate failed. Missing permanent publication is explicitly draft, not pass.

- [ ] **Step 3: Commit automated records**

```bash
git add docs/evidence/tui-renderer/automated
git commit -m "docs: record automated renderer evidence"
```

---
### Task 26: Collect Signed Manual Emulator/tmux/SSH Observations and Seal Evidence

**Files:**
- Create: `scripts/acceptance/tui_terminal_matrix.sh`
- Create: `scripts/acceptance/tui_manual_record.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs`
- Create: `docs/evidence/tui-renderer/manual/README.md`
- Create after observation: `docs/evidence/tui-renderer/manual/*.json`
- Create after observation: `docs/evidence/tui-renderer/manual/*.json.sig`
- Create after immutable publication: `docs/evidence/tui-renderer/macos-arm64.json`
- Create after immutable publication: `docs/evidence/tui-renderer/macos-x86_64.json`
- Create after immutable publication: `docs/evidence/tui-renderer/ubuntu-22.04-arm64.json`
- Create after immutable publication: `docs/evidence/tui-renderer/ubuntu-22.04-x86_64.json`

**Interfaces:**

```text
tui_terminal_matrix.sh --target TARGET --emulator NAME --context local|tmux|ssh --output DIR
tui_manual_record.exs --record RECORD
```

- Run only on GUI/session/operator lanes recorded complete in Task 1. Each required emulator/context executes sustained Unicode editing/paste, resize/focus, optional mouse plus keyboard parity, truecolor/256/16/mono, Unicode/ASCII, reduced motion, alt/no-alt, suspend/continue, normal/error/signal exit, exact stty, cursor, and scrollback observations.
- Raw bounded output/screenshot hashes and commands go to the evidence-only draft release. `tui_manual_record.exs` produces unsigned canonical JSON only. The registered operator signs it outside the agent workflow with their own non-exported key using `ssh-keygen -Y sign -n swarm-code-tui-evidence`; this plan never asks for, opens, or stores an operator private key. Validator checks allowed public signer, namespace, target/commit/emulator, raw asset digest, and UTC observation window. A signature is evidence provenance, not permission to mark a failed fact pass.
- After every automated and manual asset validates, publish the draft evidence-only prerelease immutably, verify assets/attestations from their permanent URLs, then update aggregate target JSON. Missing emulator, GUI, tmux/SSH, signature, or raw permanent asset leaves target incomplete.

- [ ] **Step 1: Write manual-record RED schema/verification cases**

Use temporary SSH keys to test valid signature, wrong namespace/key/commit, tampered JSON, missing emulator lane, failed fact, and expired-only asset.

- [ ] **Step 2: Run RED then implement record/sign/verify**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs
```

Expected: FAIL until the manual record tool and fixture test file `apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs` exist.

- [ ] **Step 3: Run every assigned lane and seal immutable evidence**

```bash
mise exec -- elixir scripts/acceptance/tui_infrastructure_validate.exs docs/evidence/tui-renderer/infrastructure.json docs/evidence/tui-renderer/manual-operators.json
for record in docs/evidence/tui-renderer/manual/*.json; do scripts/acceptance/tui_manual_evidence_verify.sh "$record" "$record.sig" governance/tui-evidence-allowed-signers; done
mise exec -- mix swarm_code.tui.evidence --check docs/evidence/tui-renderer
```

Expected: complete signed matrix or truthful incomplete/fail; never inferred pass.

- [ ] **Step 4: Commit signed records and permanent references**

```bash
git add scripts/acceptance/tui_terminal_matrix.sh scripts/acceptance/tui_manual_record.exs apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs docs/evidence/tui-renderer
git commit -m "test: seal terminal emulator evidence"
```

---
### Task 27: Record the Objective ExRatatui Go/No-Go Decision and Finish the Spike

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/decision.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/decision_test.exs`
- Create: `docs/decisions/tui-renderer.md`
- Modify: `README.md`

**Interfaces:**

```elixir
Renderer.Decision.evaluate([evidence_record()]) ::
  {:adopt, :ex_ratatui_013}
  | {:reject, :term_ui, [binary()]}
  | {:reject, :ratatui_sidecar, [binary()]}
  | {:incomplete, [binary()]}
```

- Adopt only when all four native evidence records pass every required gate.
- A failed native policy, packaging, Unicode/input, lifecycle, performance, exact-cell/cursor, preallocation paste-bound, IME contract, or BEAM-safety dimension rejects ExRatatui. Exact 0.13.0 currently has no native paste preallocation limit or IME lifecycle event; unless contrary exact-artifact evidence proves them or the governing contract is separately revised before execution, the objective result is rejection, not an undocumented waiver. Default fallback is TermUI after its own Unicode-width/paste/focus gate.
- Ratatui sidecar is selected only when in-process NIF isolation is the sole failed dimension and every Ratatui rendering/input/lifecycle-except-isolation/packaging-independent gate passed. A sidecar is not selected to excuse another failure.
- One failed target is rejection. A target not run, an emulated-only observation, mixed commits, absent raw hashes, or pending evidence is incomplete and cannot promote a renderer.
- `docs/decisions/tui-renderer.md` records exact source commit, target table, command/evidence hashes, measured metrics, failures, chosen result, fallback consequence, and the fake/demo claim boundary. It never calls the spike full parity, Phase 2, installable, or ready for canonical data.
- README documents only how a contributor runs the fake demo and plain mode, labels them fake/no-user-data, states no FoundationGate/Repo/IPC is involved, and links the decision/evidence/spec. It does not add one-command installation wording.

- [ ] **Step 1: Write the RED decision table**

```elixir
test "three passes and one target failure reject rather than partially adopt" do
  evidence = DecisionFixtures.three_pass_one_fail(:unicode_input)
  assert {:reject, :term_ui, [reason]} = Decision.evaluate(evidence)
  assert reason =~ "ubuntu-22.04-arm64"
end

test "only isolated in-process NIF safety failure selects a sidecar" do
  assert {:reject, :ratatui_sidecar, _} =
           Decision.evaluate(DecisionFixtures.only_nif_isolation_failed())
  assert {:reject, :term_ui, _} =
           Decision.evaluate(DecisionFixtures.nif_and_paste_failed())
end
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/decision_test.exs
```

Expected: FAIL because objective decision logic does not exist.

- [ ] **Step 3: Implement the closed decision matrix and write the evidence-backed ADR**

Generate the result from committed evidence; do not hand-select it:

```bash
mise exec -- mix swarm_code.tui.evidence --decision docs/evidence/tui-renderer
```

Copy that exact result and reasons into the ADR. If it is incomplete, title the status `INCOMPLETE — renderer not selected` and stop renderer promotion. If rejected, retain neutral code and state the required next fallback spike. If adopted, state only `ExRatatui 0.13.0 adopted for the fake interaction spike`.

- [ ] **Step 4: Run all focused acceptance plus two clean precommits**

```bash
mise exec -- mix test apps/swarm_code_cli/test --seed 0
mise exec -- mix swarm_code.tui.goldens --check
mise exec -- mix swarm_code.tui.evidence --check docs/evidence/tui-renderer
mise exec -- mix precommit
mise exec -- mix precommit
MIX_ENV=prod mise exec -- mix compile --warnings-as-errors
```

Expected: all commands PASS with clean output. If evidence is a truthful renderer rejection, `--check` passes schema/integrity and the decision command returns the documented rejected result; it does not masquerade as adoption.

- [ ] **Step 5: Re-run claim-boundary and repository checks**

```bash
if git grep -n -E 'Phase 2 complete|full parity|production ready|installable now|canonical database ready' -- README.md docs/decisions apps/swarm_code_cli; then false; fi
if git grep -n -E 'FoundationGate|Ecto\.Repo|swarm_code_daemon|DATABASE_PATH' -- apps/swarm_code_cli/lib; then false; fi
git status --short
```

Expected: no overclaim/banned runtime reference and no uncommitted generated output.

- [ ] **Step 6: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/decision.ex apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/decision_test.exs docs/decisions/tui-renderer.md README.md
git commit -m "docs: record TUI renderer spike decision"
```

---

## Final Objective Acceptance

The plan is complete only when all of these statements have direct evidence:

1. Neutral Scene/Input/Action/Reducer/Effect/DataSource contracts compile without renderer or daemon implementation leakage.
2. SafeText and the Unicode-width 0.2.2 port pass the full adversarial/Unicode corpus and never emit executable external terminal controls.
3. Snapshot-before-delta, bounded pre-ready buffering, contiguous sequences, gap/snapshot-required resync, stale rejection, and detach/reconnect pass without sleeps.
4. The deterministic three-run script preserves both drafts, cursor, selection, focus, modal, layout preferences, Main/Inspector anchors, deduplicated unseen IDs, and event order while resolving Q1 exactly once at revision 7.
5. Responsive projection passes every boundary around `170x34`, `150x30`, `100x24`, `72x20`, `50x16`, `50x14`, and `49x13`, with keyboard-reachable safe actions and no overlap/whole-screen horizontal scroll.
6. Plain mode is permanent, automatic for non-TTY/TERM dumb, append-only/control-free, interactive for the fake flow, and compatible with ASCII/no-color/NO_COLOR/reduced motion. No-alt-screen remains distinct.
7. Exactly 69 committed frames compare every cell/style/continuation plus cursor/focus/action IDs.
8. ExRatatui references and NIF resources remain inside its exact adapter; the editor/reducer never uses renderer textarea state.
9. Normal/error/INT/TERM/TSTP-CONT PTY restoration passes 1,000 target cycles and documents SIGKILL recovery honestly.
10. Safety/fuzz/sanitizer, input, Unicode, performance, soak, windowing, target-native release, offline boot, link/RPATH/glibc, and terminal coverage results exist for all four native targets.
11. The decision is mechanically adopt/reject/incomplete from evidence, with three-of-four never accepted.
12. The final README/ADR repeatedly and accurately say fake demo, no user data, no FoundationGate/Repo/IPC, no full parity, and no production/installability claim.

After this spike, a separate plan may implement the chosen renderer fallback if rejected. A real IPC workspace remains blocked on all daemon prerequisites in interaction-contract section 20 and must receive its own design/plan.
