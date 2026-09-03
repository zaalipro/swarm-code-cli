# Fake-Backed Renderer-Neutral TUI Interaction Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a fake/demo-only, renderer-neutral terminal interaction lab that proves SwarmCode's asynchronous workspace UX, permanent plain/degraded surfaces, exact cell output, terminal restoration, and the four-target ExRatatui 0.13.0 go/no-go decision without opening IPC, FoundationGate, Repo, or user data.

**Architecture:** Pure `SwarmCodeCLI.UI` types, editor, reducer, and projector own all presentation state; a bounded client-side `DataSource.Fake` attaches to a separately owned deterministic `Fake.Source`, and `SessionRuntime` uses two-phase source/terminal registration before applying every semantic action and coalescing paints. ExRatatui is an isolated renderer adapter only: it receives immutable `Scene` values, returns renderer-neutral input/cell frames, and is replaceable without changing state or commands. A single supervised terminal owner controls the local adapter lifecycle, while an independently owned serialized plain line session consumes normalized deliveries rather than serialized screens.

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
- East Asian Ambiguous width has one renderer-neutral capability, defaults to `:narrow`, and is overridden only by `--ambiguous-width=narrow|wide`; editor, projection, Scene, adapter, capture, and PTY evidence must use the same value.
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

apps/swarm_code_cli/lib/swarm_code_cli/ui/{draft,field_editors,state,reducer,scroll,page_state,mutation_state}.ex
  Process-local drafts/transient fields, virtual-list lifecycle, and pure presentation state transitions.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{layout,projector,fixtures}.ex
  Breakpoint classification, exact rectangles, Scene projection, and fixed representative scenes.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{keymap,switcher,activity,question}.ex
  Input priority, discoverability layers, Activity ordering, and revisioned question behavior.

apps/swarm_code_cli/lib/swarm_code_cli/ui/{session_runtime,effect_runner,terminal_owner,launcher_control,ui_supervisor}.ex
  Ordered runtime, effect settlement, one terminal owner, signals, and owned shutdown.

apps/swarm_code_cli/lib/swarm_code_cli/plain/{options,environment,presenter,command,session}.ex
  Permanent owned serialized line surface and deterministic commands.

apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/
  The only ExRatatui/Rustler boundary: event normalization, widget mapping, cell capture, local host.

apps/swarm_code_cli/lib/swarm_code_cli/demo/
  Explicit fake-only composition root and finite/native acceptance scripts.

apps/swarm_code_cli/test/fixtures/
  Adversarial text, upstream width vectors, fixed fake script, and 87 exact cell frames.

third_party/unicode-width-0.2.2/
  Exact licensed source inputs and attestation for the renderer-neutral width port.

scripts/acceptance/tui_*.{py,sh,exs}
  PTY, performance/soak, native dependency inspection, release smoke, and evidence validation.

.github/workflows/tui-native-bootstrap.yml
  Audited default-branch dispatcher that checks out an exact feature SHA for closed preflight/native phases.

docs/evidence/tui-renderer/ and docs/decisions/tui-renderer.md
  Immutable target observations and the objective adopt/reject/incomplete result.
```

The renderer-neutral implementation is production-shaped, but `Demo` and `DataSource.Fake` remain explicitly fake. No later task may bridge them to `swarm_code_daemon` as part of this plan.

---

### Task 0: Scaffold and Land the Default-Branch Native Bootstrap

**Files:**
- Create: `scripts/acceptance/tui_infrastructure_preflight.sh`
- Create: `scripts/acceptance/tui_preflight_dispatch.sh`
- Create: `scripts/acceptance/tui_repository_policy_preflight.sh`
- Create: `scripts/acceptance/tui_infrastructure_validate.exs`
- Create: `scripts/acceptance/tui_manual_evidence_verify.sh`
- Create: `.github/workflows/tui-native-bootstrap.yml`
- Create: `governance/tui-evidence-allowed-signers`
- Create: `docs/evidence/tui-renderer/infrastructure.schema.json`
- Create: `docs/evidence/tui-renderer/manual-observation.schema.json`
- Create: `apps/swarm_code_cli/test/fixtures/evidence/infrastructure-valid.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/infrastructure_schema_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/preflight_dispatch_test.exs`

**Interfaces:**

```text
tui_infrastructure_preflight.sh --target TARGET --expected-sha SHA --output FILE
tui_preflight_dispatch.sh --workflow-ref main --bootstrap-sha MAIN_SHA --expected-sha FEATURE_SHA --deadline-seconds 900 --output-dir DIR
tui_repository_policy_preflight.sh --repository zaalipro/swarm-code-cli --output FILE
tui_infrastructure_validate.exs REPOSITORY_POLICY.json INFRASTRUCTURE.json MANUAL_OPERATORS.json
tui_manual_evidence_verify.sh RECORD.json RECORD.json.sig ALLOWED_SIGNERS
```

- The one default-branch workflow has `permissions: {contents: read}`, a bounded `request_id`, required `expected_sha`, and a closed choice input `phase: preflight | native_evidence`. Its run name contains phase, expected SHA, and request ID. Each of four target jobs uses the exact native label set, pins `actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683` and `actions/upload-artifact@65c4c4a1ddee5b72f698fdd19549f0f0fb45cf08`, and checks out with `ref: ${{ inputs.expected_sha }}`. Immediately afterward it asserts `git rev-parse HEAD == expected_sha`. It never asserts `GITHUB_SHA == expected_sha`, because the dispatch run itself is sourced from `main`.
- A literal shell `case` maps `preflight` only to `tui_infrastructure_preflight.sh` and `native_evidence` only to `tui_target_gate.sh`; unknown/missing values fail. No workflow input becomes a command, path, label, or shell fragment. Jobs upload a bounded record even on gate failure.
- Dispatch queries and bounds the Actions runner API to 1,048,576 bytes, requires one online native runner containing every label in each exact set, verifies the accepted default-branch workflow blob, dispatches `tui-native-bootstrap.yml` with `--ref main`, and correlates the unique run name, event, workflow path, `head_sha == bootstrap_sha`, and artifact-recorded checked-out feature SHA. It polls at five-second owned intervals against one monotonic 900-second deadline. On expiry it cancels the exact run and observes cancellation for at most 60 more seconds. It never uses `gh run watch`.
- Schemas distinguish automated PTY capacity from GUI/manual emulator capacity. Allowed-signers contains public SSH keys only and may initially be empty. Manual records include target/source commit/harness commit/script digest/operator fingerprint/emulator/version/context/color/Unicode/motion/alt mode/commands/timestamps/stty/output hashes/facts and signed namespace `swarm-code-tui-evidence`.

- [ ] **Step 1: Write RED schema, closed-phase, exact-checkout, dispatch, and repository-policy tests**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/infrastructure_schema_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/preflight_dispatch_test.exs
```

Expected: FAIL because scripts, schemas, and the default-branch bootstrap do not exist. Fake `gh` cases cover missing authorization/labels, offline runners, a workflow absent from `main`, wrong workflow blob/head SHA/run name, exact dispatch, deadline cancellation, cancellation timeout, bounded-output overflow, immutable policy disabled→empty-body PUT→enabled, and policy denial.

- [ ] **Step 2: Implement and locally validate the auditable bootstrap**

Reject unknown targets/phases, mismatched expected SHA, emulation, absent PTY, undersized disk/RAM/job duration, missing inspection tools, and malformed signing records with static diagnostics. Mark every shell script mode `0755`. The workflow itself contains no repository write, PR, release, or arbitrary-script permission.

- [ ] **Step 3: Run GREEN, commit, and push the exact feature scaffolding**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/infrastructure_schema_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/preflight_dispatch_test.exs
chmod 0755 scripts/acceptance/tui_infrastructure_preflight.sh scripts/acceptance/tui_preflight_dispatch.sh scripts/acceptance/tui_repository_policy_preflight.sh scripts/acceptance/tui_manual_evidence_verify.sh

git add scripts/acceptance/tui_infrastructure_preflight.sh scripts/acceptance/tui_preflight_dispatch.sh scripts/acceptance/tui_repository_policy_preflight.sh scripts/acceptance/tui_infrastructure_validate.exs scripts/acceptance/tui_manual_evidence_verify.sh .github/workflows/tui-native-bootstrap.yml governance/tui-evidence-allowed-signers docs/evidence/tui-renderer/*.schema.json apps/swarm_code_cli/test
git commit -m "ci: scaffold auditable native TUI bootstrap"
git push -u origin feature/tui-interaction-spike
feature_sha=$(git rev-parse HEAD)
workflow_blob=$(git rev-parse "$feature_sha:.github/workflows/tui-native-bootstrap.yml")
test "$(git rev-parse origin/feature/tui-interaction-spike)" = "$feature_sha"
```

Expected: the feature commit is pushed, but no dispatch occurs yet.

- [ ] **Step 4: Land only the audited workflow blob on `main` and verify it**

```bash
git fetch origin main
feature_sha=$(git rev-parse HEAD)
workflow_blob=$(git rev-parse "$feature_sha:.github/workflows/tui-native-bootstrap.yml")
bootstrap_dir=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-bootstrap.XXXXXX")
git worktree add -b bootstrap/tui-native-gates "$bootstrap_dir" origin/main
mkdir -p "$bootstrap_dir/.github/workflows"
git show "$feature_sha:.github/workflows/tui-native-bootstrap.yml" > "$bootstrap_dir/.github/workflows/tui-native-bootstrap.yml"
git -C "$bootstrap_dir" add .github/workflows/tui-native-bootstrap.yml
git -C "$bootstrap_dir" commit -m "ci: add native TUI bootstrap"
git -C "$bootstrap_dir" push -u origin bootstrap/tui-native-gates
pr_url=$(gh pr create --repo zaalipro/swarm-code-cli --base main --head bootstrap/tui-native-gates --title "ci: add native TUI bootstrap" --body "Adds only the audited closed-phase workflow; it checks out and verifies an explicit feature commit.")
gh pr diff "$pr_url" --name-only | diff -u <(printf '%s\n' .github/workflows/tui-native-bootstrap.yml) -
gh pr merge "$pr_url" --merge --delete-branch
git fetch origin main
bootstrap_sha=$(git rev-parse origin/main)
main_workflow_blob=$(git rev-parse "origin/main:.github/workflows/tui-native-bootstrap.yml")
test "$main_workflow_blob" = "$workflow_blob"
gh workflow view tui-native-bootstrap.yml --repo zaalipro/swarm-code-cli --ref main
git worktree remove "$bootstrap_dir"
```

Expected: an auditable PR lands exactly one workflow on the default branch; `bootstrap_sha` and `main_workflow_blob` identify the verified result. If branch policy, authorization, or review prevents this landing, record infrastructure `incomplete`; Tasks 2-15 may continue, but no workflow dispatch and no renderer-specific Task 16-28 may run.

---

### Task 1: Enable Immutable Evidence Policy and Record Exact Native Capacity

**Hard infrastructure gate:** Renderer-specific Tasks 16-28 require a verified default-branch bootstrap blob, repository immutable releases enabled, four native build/PTY runner passes, and named public-key operators for every emulator lane. Neutral/fake-backed Tasks 2-15 may proceed when this evidence is incomplete; milestone status then remains `INCOMPLETE — renderer not selected`.

**Files:**
- Create from the repository API: `docs/evidence/tui-renderer/repository-policy.json`
- Create from downloaded workflow records: `docs/evidence/tui-renderer/infrastructure.json`
- Create from public operator registration: `docs/evidence/tui-renderer/manual-operators.json`

**Interfaces:**
- Consumes the exact feature commit and verified `main` workflow blob from Task 0.
- Produces one policy/native/operator aggregate with `complete | incomplete`, never inferred pass.

- [ ] **Step 1: Query, enable when authorized, and re-query immutable releases**

```bash
scripts/acceptance/tui_repository_policy_preflight.sh --repository zaalipro/swarm-code-cli --output docs/evidence/tui-renderer/repository-policy.json
```

The script first runs `gh api -H 'X-GitHub-Api-Version: 2026-03-10' repos/zaalipro/swarm-code-cli/immutable-releases`. When `.enabled` is false and repository administration permits it, the documented enablement call is exactly `gh api --method PUT -H 'X-GitHub-Api-Version: 2026-03-10' repos/zaalipro/swarm-code-cli/immutable-releases` with no request fields and no body; it then repeats GET and requires `.enabled == true`. A denied/unsupported PUT or false re-query writes bounded `incomplete` policy evidence rather than claiming durability.

- [ ] **Step 2: Dispatch the default-branch bootstrap against the exact feature commit**

```bash
git fetch origin main feature/tui-interaction-spike
expected_sha=$(git rev-parse HEAD)
test -z "$(git status --short)"
test "$(git rev-parse origin/feature/tui-interaction-spike)" = "$expected_sha"
bootstrap_sha=$(git rev-parse origin/main)
bootstrap_blob=$(git rev-parse "origin/main:.github/workflows/tui-native-bootstrap.yml")
test "$bootstrap_blob" = "$(git rev-parse HEAD:.github/workflows/tui-native-bootstrap.yml)"
download_dir=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-preflight.XXXXXX")
scripts/acceptance/tui_preflight_dispatch.sh --workflow-ref main --bootstrap-sha "$bootstrap_sha" --expected-sha "$expected_sha" --deadline-seconds 900 --output-dir "$download_dir"
```

Expected: the workflow run is sourced from the verified `main` commit, while every job checks out and records `expected_sha`. A missing/denied policy, workflow landing, runner, or target writes truthful incomplete evidence and does not dispatch an unverified workflow.

- [ ] **Step 3: Aggregate runner facts and public operator inventory**

Copy only bounded secret-free records and the repository-policy response. `infrastructure.json` records the verified bootstrap main commit and workflow blob plus each job's checked-out feature SHA. `manual-operators.json` references allowed public-key fingerprints and lane assignments; it never contains or requires private keys. If a lane/operator is unavailable, list it in `missing_lanes`.

- [ ] **Step 4: Validate and commit evidence**

```bash
mise exec -- elixir scripts/acceptance/tui_infrastructure_validate.exs docs/evidence/tui-renderer/repository-policy.json docs/evidence/tui-renderer/infrastructure.json docs/evidence/tui-renderer/manual-operators.json
git add docs/evidence/tui-renderer/repository-policy.json docs/evidence/tui-renderer/infrastructure.json docs/evidence/tui-renderer/manual-operators.json
git commit -m "docs: record TUI infrastructure capacity"
```

Expected: validator exits zero for schema/integrity even when status is explicitly incomplete. Only a complete immutable-policy/bootstrap/runner/operator result unlocks renderer tasks; neutral tasks remain executable either way.

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
- `Capabilities` already has its final field shape: size; color mode; `ambiguous_width: :narrow | :wide` with deterministic default `:narrow`; ASCII/reduced-motion/TTY/controlling-TTY booleans; `stdin_tty?`; `stdout_tty?`; feature states `:supported | :best_effort | :unavailable` for enhanced keys, focus, paste, IME composition, mouse, clipboard, and alternate screen; plus `paste_preallocation_bound?`. `explicit/2` validates closed values without reading the process environment.
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
  assert caps.ambiguous_width == :narrow
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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/field_key.ex`
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
        | :back
        | {:focus_cycle, :next | :previous}
        | {:focus_region, binary()}
        | {:move, :next | :previous | :first | :last}
        | {:expand, binary(), boolean()}
        | {:activate, binary(), non_neg_integer(), binary()}
        | {:scroll, binary(), ScrollOperation.t()}
        | {:editor, DraftKey.t(), Editor.Operation.t()}
        | {:field_editor, FieldKey.t(), Editor.Operation.t()}
        | {:layout_adjust, :navigator | :inspector,
           :reset | {:preset, :compact | :balanced | :wide} | {:nudge, -8 | -2 | 2 | 8}}
        | {:composer_height, :reset | {:nudge, -1 | 1}}
        | {:presenter_handoff_requested, :plain}
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
        | {:presenter_handoff, :plain}
        | {:detach, non_neg_integer()}
```

- Key codes are the closed special-key atoms plus `{:function, 1..12}`. Textual keys are valid UTF-8 fragments, never runtime atoms. Modifiers, mouse kinds/buttons, lifecycle states, error codes, request kinds, and effect variants use closed compile-time values.
- Terminal generation/capability actions let resize/resume update reducer state without a renderer type. Draw results carry a runtime-issued opaque draw token and the exact Scene revision attempted. `terminal_control` is interpreted only by SessionRuntime/LauncherControl; Reducer never sends an OS signal.
- `FieldKey` is the exact closed union `{:layer_query, layer_id, :switcher | :jump | :action_menu} | {:region_filter, region_id} | {:question_other, interaction_id, revision}`. It cannot alias a `DraftKey`.
- `DataSource` callbacks are exactly `start_link(options)`, `bind_owner(server, owner_handle, binding_ref)`, `watch`, `unwatch`, `query`, `command`, `cancel`, and `close`. Before the one successful reference-correlated owner bind, admission fails closed and no delivery is emitted. `Watch`, `Request`, `Delivery`, and `AdmissionError` have their final closed structural fields now; typed DTO bodies arrive later.
- Only key `:press` can activate/mutate/submit/queue/detach. `:repeat` is admitted only for editor insertion/deletion/movement/selection, logical row movement, and scroll; `:release` is inert. Resize help is a fixed layer action because a client cannot resize its emulator. Presenter handoff means orderly restore and a fixed `Rerun with --plain` exit instruction, not an in-process renderer swap.
- Add `{:stream_data, "== 1.4.0", only: :test, runtime: false}` once and add `test/support` through `elixirc_paths/1`.

- [ ] **Step 1: Write RED closed-union tests**

```elixir
test "terminal lifecycle and draw settlement remain renderer neutral" do
  caps = Capabilities.explicit(%Size{columns: 120, rows: 40}, stdin_tty?: true, stdout_tty?: true, controlling_tty?: true)
  assert {:terminal_capabilities, 4, ^caps} = Action.validate!({:terminal_capabilities, 4, caps})
  assert {:draw_result, "draw-8", 17, :ok} = Action.validate!({:draw_result, "draw-8", 17, :ok})
  assert {:terminal_control, :suspend} = Effect.validate!({:terminal_control, :suspend})
  assert :back = Action.validate!(:back)
  assert {:layout_adjust, :navigator, {:nudge, -2}} =
           Action.validate!({:layout_adjust, :navigator, {:nudge, -2}})
  assert {:presenter_handoff, :plain} = Effect.validate!({:presenter_handoff, :plain})
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

- `Scene.Block.t/0` is the exhaustive initial union of Text, RichText, Markdown, Code, VirtualList, RunCard, AgentList, ConsensusLedger, ResearchDocument, Progress, Tabs, KeyValues, Composer, Notice, and ActionDeck. Every text position is `SafeText`; action references are opaque binaries. Scene carries the exact `ambiguous_width` capability, and Dialog carries focused-control ID plus independent bounded body-scroll/visible-range metadata for sticky-title/footer projection.
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
Width.elide(binary(), non_neg_integer(), :end | :middle, :narrow | :wide) :: binary()
```

- Port exact crate 0.2.2, checksum `b4ac048d71ede7ee76d585517add45da530660ef4390e49b098733c6e897f254`, commit `9d98411769fe13c7c18cab0b3fbbab29ba8350ea`, Unicode 17.0.0. `Width.Table` faithfully represents narrow/CJK `WidthInfo`, emoji presentation/modifier/flag/keycap/tag/ZWJ state, combining characters, variation selectors, and ligatures.
- `sync_unicode_width.exs --accept SOURCE_CRATE` verifies checksum before safe extraction, rejects absolute/parent/symlink/device archive entries, copies exact licensed inputs, generates Table/vectors deterministically, and writes same-directory atomic replacements. `--check` is network-free and verifies all source/output hashes in `UPSTREAM.json`.
- Width iteration and end/middle elision never split an extended grapheme. The committed upstream-derived vector identifies expected widths; hand literals cross-check but do not redefine upstream truth. Every caller passes the one `Capabilities.ambiguous_width` value; there is no hidden default below the capability constructor.

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
- Probe separately records stdin TTY, stdout TTY, and usable controlling `/dev/tty`. Full-screen eligibility requires all three. Piped stdin, redirected output, missing controlling TTY, TERM dumb, or explicit plain fails closed before native init. Color precedence is explicit no-color/NO_COLOR → monochrome → truecolor → 256 → 16. `--ambiguous-width=narrow|wide` overrides the deterministic narrow default; unknown values fail before native init. Features remain supported/best-effort/unavailable; native paste preallocation and ExRatatui IME start false/unavailable.
- `Theme.style/2` exhaustively implements every Carbon dark role and every truecolor/256/16/monochrome value in contract section 14.2, including surfaces/text/focus/selection/disabled/stale, semantic tones, six run kinds, and five numbered agent lanes. `Theme.status/1` separately maps every closed status to its exact display label and tone; paused/interrupted/approval/superseded are never collapsed. Monochrome focus/selection/disabled/stale always adds the required word/marker/border/reverse cue and never relies on dim. No style uses colored underline because CellSession cannot report underline color.

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

test "every Carbon role is exact in every color mode" do
  for role <- Theme.roles(), color <- [:truecolor, :ansi256, :ansi16, :monochrome] do
    assert Theme.style(role, CapabilityFixtures.with_color(color)) ==
             ThemeFixtures.expected_style(role, color)
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

- DTOs are page-limited typed structs. `Watch` has binary reference, closed slot, `SwarmCode.Protocol.Scope`, generation, page size 1-200, and byte limit at most 1,048,576. `Request` has binary request ID, closed kind, scope, generation, origin, absolute deadline, and expected response type. `Delivery.body` is only the closed DTO/delta/outcome union. Transcript/Activity windows carry `idle | loading_before | loading_after | error | closed | resyncing`, opaque cursors and correlated request/error metadata.
- Fake Source is the separately owned fake-daemon analogue. It owns A1/A2/B1 canonical scripted facts and continues when a client detaches. The fixture is bounded through `SwarmCode.Protocol.JsonLimits.decode/2`, then closed strings are converted only by clauses. Fixed clock is `2026-09-03T12:00:00Z`; fixed UUIDs and binary barrier IDs are committed.
- `advance/2` mutates source facts in node → assistant text → reasoning → run order and acknowledges only after subscriber messages are enqueued. It never sleeps, opens a user path, or stores draft/UI state. Its redacted `format_status/1` exposes counts/status IDs only. Page replies distinguish off-window from confirmed removal; superseded turns remain losslessly present with the contract's exact allowed-action restrictions.
- Besides the three-run script, fixtures expose the complete closed status catalogue and an Activity page with two questions, one approval, distinct urgency/deadlines across conversations, running/paused work, failure, and completion. This is deterministic presentation evidence, not new fake domain behavior.

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
DataSource.start_link(options: keyword()) :: GenServer.on_start()
DataSource.bind_owner(server(), GenServer.server(), binary()) ::
  {:ok, binary()} | {:error, :already_bound | :closed | :binding_failed}
DataSource.watch(server(), Watch.t()) :: :ok | {:error, AdmissionError.t()}
DataSource.unwatch(server(), binary()) :: :ok
DataSource.query(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
DataSource.command(server(), Request.t()) :: :ok | {:error, AdmissionError.t()}
DataSource.cancel(server(), binary()) :: :ok
DataSource.close(server()) :: :ok

DataBridge.normalize({:swarm_code_ui_data, binary(), Delivery.t()}, binary() | nil) ::
  {:ok, {:data, Delivery.t()}} | {:ignore, :stale_epoch} | {:error, :invalid_delivery}
```

- Each Fake adapter starts unbound and owns only its source monitor, watches, pre-ready buffers, requests, deadlines, and eventual owner monitor. Before one exact reference-correlated `bind_owner/3` acknowledgement, all admission fails closed and no delivery is emitted. Duplicate/stale bind, owner death, unwatch, or close settles local resources; source run facts survive. Pre-ready bounds are 128 events/1,048,576 encoded bytes per watch.
- `watch_ready` installs a page snapshot and `through_sequence` before deltas become visible. Contiguous sequences pass. Duplicate/stale epoch/watch/scope/generation/revision/request deliveries are rejected. A visible scripted gap or `snapshot_required` waits for the reducer's one typed resync request; pre-ready overflow triggers the same resync path internally because no delta has been exposed.

- [ ] **Step 1: Write synchronization RED tests**

Cover unbound rejection, exact bind acknowledgement, duplicate/stale bind rejection, ready-before-delta, exact through sequence, bounded buffering, contiguous order, duplicate/stale delivery rejection, gap and explicit resync, epoch replacement, cancellation, owner death, close, and new-client ready snapshot from the continuing source.

```elixir
assert :ok = Fake.Source.advance(source, "workspace-a-gap")
assert_receive {:swarm_code_ui_data, ^epoch, %Delivery{kind: :delta, sequence: 8}}
assert {:error, %AdmissionError{code: :not_bound}} = DataSource.query(client, FakeFixtures.resync_request("watch-a"))
assert {:ok, "bind-a"} = DataSource.bind_owner(client, owner, "bind-a")
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

Monitor the bound owner/source, validate every typed correlation field before delivery, and settle synchronous admission calls without doing long source work inside the adapter callback. Emit ready/resync/closed messages in one documented order and keep no canonical source copy. Close from `:unbound | :bound | :closing` is idempotent.

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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/field_editors.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/editor_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/drafts_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/field_editors_test.exs`

**Interfaces:**

```elixir
Editor.new(max_bytes: pos_integer(), undo_bytes: pos_integer(), undo_count: pos_integer()) :: Editor.t()
Editor.apply(Editor.t(), Editor.Operation.t()) :: {:ok, Editor.t()} | {:error, :text_too_large}
Editor.text(Editor.t()) :: binary()
Editor.cursor(Editor.t()) :: non_neg_integer()
Editor.selection(Editor.t()) :: nil | {non_neg_integer(), non_neg_integer()}
Editor.visible_slice(Editor.t(), pos_integer(), pos_integer(), :narrow | :wide) :: Editor.VisibleSlice.t()

DraftKey.t() :: {binary(), :main | {:thread, binary()} | {:edit, binary()}}
Draft.new(DraftKey.t(), Editor.t()) :: Draft.t()
Drafts.fetch(Drafts.t(), DraftKey.t()) :: Draft.t()
Drafts.put(Drafts.t(), Draft.t()) :: Drafts.t()
Drafts.clear_origin(Drafts.t(), DraftKey.t(), binary()) :: Drafts.t()
FieldEditors.fetch(FieldEditors.t(), FieldKey.t()) :: Editor.t()
FieldEditors.close_owner(FieldEditors.t(), binary()) :: FieldEditors.t()
```

- `Editor.Buffer` is a two-sided grapheme zipper. Insert/paste splits once, prepends/reverses bounded chunks, and does not append repeatedly to a growing binary. Cursor and selection are grapheme indices; vertical movement retains preferred display cell using `Width`.
- Operations are insert/resegment text fragment, one bounded paste, composition start/update/end, delete backward/forward/word, logical left/right/up/down, word movement, line Home/End, buffer Home/End, selection extension, select all, copy, cut, undo, redo, and explicit newline. Shift extends selection. Paste/cut are individual undo groups; contiguous insert/delete groups end on movement, selection, paste, or a runtime-supplied 1,000 ms boundary action, so the pure editor reads no clock. Paste never produces an activate/send action. Composition text remains editor-local until committed and Enter cannot activate send while composition state is active.
- Default editor text bound is 262,144 bytes. Undo is bounded to 100 records and 1,048,576 bytes; eviction drops only derived undo history, never current text.
- `Editor.visible_slice/4` returns a grapheme-aligned viewport around the cursor bounded to 8,192 source bytes plus logical row/cell metadata using the one capability ambiguous-width policy. Projector passes only this slice to `SafeText.external/2`, so every admitted 262,144-byte draft remains editable even when control escaping would make the whole value exceed a single Scene bound.
- `Draft` carries exact editor state, vertical/horizontal editor scroll, Reply/Steer/Revise/command/goal/research chip state, attachment metadata references only, validation state, and height clamped to 1-8 rows.
- A clear operation requires both the exact draft key and originating request ID. It cannot clear a currently newer submission or any other conversation draft.
- `FieldEditors` holds only the closed `FieldKey` values from Task 4, caps each at 16,384 bytes, and clears by owning layer/region. It never aliases or clears `Drafts`. Switcher/filter/Other paste, IME, cursor, selection, and undo are therefore isolated from the hidden composer.
- RTL input remains logical-grapheme ordered. Tests assert the visible caret and selection cell edges under the chosen width policy rather than treating Arabic/Hebrew codepoint indices as visual coordinates. Copy/cut emits clipboard intent only when bounded capability exists; unavailable copy preserves selection/text and projects fixed `COPY UNAVAILABLE` feedback.

- [ ] **Step 1: Write Unicode editing and draft-isolation RED tests**

Exercise composed/decomposed accents, Georgian, Arabic/Hebrew logical editing/visible caret edges, CJK, both ambiguous-width policies, skin tones, flags, family/occupation ZWJ sequences, VS15/VS16, word and line/buffer motion/deletion, Shift selection, copy/cut capability fallback, undo grouping/eviction, multiline vertical movement, selection replacement, 100 repeated paste events, navigation fetch/restore, per-origin clearing, and FieldKey/DraftKey isolation.

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
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/editor_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/drafts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/field_editors_test.exs
```

Expected: FAIL because the pure editor and drafts do not exist.

- [ ] **Step 3: Implement the minimal pure editor and draft store**

Store undo records as inverse operations with exact byte accounting. Recompute rendered row/cell positions through `Width` only at explicit movement/projection boundaries. Attachment values contain stable ID, display-safe name, media type, byte size, dimensions, status, and opaque reference; they never contain file bytes or base64.

- [ ] **Step 4: Run GREEN and properties**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/editor_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/drafts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/field_editors_test.exs --seed 0
```

Expected: PASS, including the property that applying any bounded edit sequence keeps cursor/selection within the grapheme count and reconstructs exact selected text.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/editor apps/swarm_code_cli/lib/swarm_code_cli/ui/editor.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/draft* apps/swarm_code_cli/lib/swarm_code_cli/ui/field_editors.ex apps/swarm_code_cli/test
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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/page_state.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/mutation_state.ex`
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

- `State` owns terminal generation/lifecycle, size/capabilities including ambiguous width, source epoch, four closed watch slots, destination/back/Activity-return history, visible and hidden focus, selections, expansions, tabs/filters and transient FieldKey editors, drafts, clamped Navigator/Inspector widths and composer height, independent Main/Inspector scroll maps, logical layer stack, bounded read model/page state, correlated mutation states, outstanding requests, dirty revision, and current action/request UUID sequence supplied by `Init`.
- `ChunkDeque` stores stream chunks in prepend-only chunk collections by entity/channel/attempt ID. Reset replaces a failed attempt; projection materializes only the visible item. It enforces the DTO field bound while reading and requests resync/detail instead of dropping bytes.
- Matching requires source epoch, watch reference, scope kind/ID/generation, revision, contiguous sequence, and request reference as applicable. Duplicate/stale events produce byte-for-byte identical state and no effects.
- A first sequence gap marks the slot stale/resyncing and emits one `%Request{kind: {:resync_watch, watch_ref}}`; later gap events while resyncing emit nothing. A replacement ready snapshot installs facts while retaining drafts, focus, selection, modal, layout preference, and logical anchors.
- Navigation increments/freeze-invalidates the old slot generation before emitting `unwatch`; the replacement watch carries the new generation. View queries are canceled; admitted command requests remain correlated offscreen.
- User scrolling detaches immediately; repeated changes to one stable item count once; `:last`/`:follow` rejoins and clears unseen. Main and Inspector are independent; prepending history and resizing preserve stable item/intra-line anchors.
- Moving, paging, `G`, or search at an unloaded edge emits exactly one correlated page query and installs a visible loading sentinel; repeat movement does not duplicate it. Failure makes the sentinel retryable. Closed/resyncing retain visible rows. `off_window` retains focus/anchor; confirmed removal repairs to the successor at the same visual bias, then predecessor, then empty-state focus. Supersession remains visible and never enters removal repair.
- Layout actions apply only closed -8/-2/+2/+8 nudges, compact/balanced/wide presets, reset, or composer ±1/reset and clamp on every resize. `:back` restores the complete saved Activity context. A press activation synchronously creates `MutationState.pending` before its command effect; duplicate/repeat activation is inert. Accepted clears only the exact origin, while needs-input/rejected/deadline/interrupted/conflict/outcome-unknown preserve it with the exact settlement.
- `OrderedIdSet` stores insertion order plus a membership index, admits at most 512 IDs for the current bounded window, and never presents map-enumeration order. Duplicate insertion preserves position. Overflow marks the watch snapshot-required and requests resync rather than silently evicting an unseen canonical item.

- [ ] **Step 1: Write stale/gap/navigation/scroll RED tests**

Use the complete reducer list in spec section 17.2, including page-edge loading/error/retry/closed/resync, off-window versus removal repair, FieldKey isolation, layout clamps, Back, key-phase pending/settlement, and focus-graph state. Also assert a higher terminal generation replaces size/capabilities and reprojects without changing draft/focus/scroll, while stale generations and stale draw results change nothing. Include this ordering assertion:

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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/density.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/dialog.ex`
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
- At Wide/XL, Navigator defaults to 26 cells clamped 24-32, Inspector defaults to 42 clamped 38-56, and Main remains at least 50. Medium docks Main plus exactly one persisted drawer. Narrow uses Main and full-height overlays. Small uses one-row title, Main, at most two-row needs-you strip, compact composer, and status. Compressed Small retains `Resize help`/Help/Detach/`Exit; rerun with --plain` and hides destructive/send actions. Too small exposes only current/required size and those same honest controls; it never claims the process can resize the emulator or swap presenter in-process.
- Main composer height is 1-8; needs-you is at most two; run logs are at most 45 percent of viewport unless maximized. No region overlaps, leaves the screen, or creates whole-screen horizontal scroll.
- `Projector.Density` implements the exact per-class budgets/degradation order in contract section 11. Mode, state, Needs-you, target, validation/error, and focus identity never disappear. Secondary model/effort/approval and attachment/queue/live-run chips collapse to labeled counts or Inspector before elision; Small status is one hint plus `?`. Names/models end-elide, paths/project-branch/refs/filenames middle-elide by cells and ambiguous-width policy. Long ASCII/CJK/RTL fixtures prove complete values remain in Inspector.
- Projector owns visible/enabled actions, fixed labels, focus indicator, cursor, exact state catalogue, action IDs, and responsive collapse. It intersects every action with DTO `allowed_actions`; it never invents domain permission. Pending mutations disable duplicate action IDs and project accepted/rejected/deadline/interrupted/conflict/outcome-unknown distinctly.
- Temporarily disabled actions show the DTO's sanitized safe reason. A stale/resyncing slot keeps its content visible and projects a scoped recovery Notice with Retry and Diagnostics rather than a blocking spinner. The status region follows the density budget—three-to-five bindings only at Wide/XL and one plus `?` at Small; `?` opens the complete current region/action map.
- Superseded turns remain losslessly visible/muted with `SUPERSEDED`, no live bar/Needs-you/Reply/Retry, and retained Inspect/Copy/Fork. Their running children show `LAUNCHED BY SUPERSEDED TURN` and keep server-authorized Stop; planner/implementation linkage remains visible through Approve/Revise.
- Title/composer always name the single fake mode explicitly. Research depth is rendered as `Research: Ultra (4x10)`, never as the ambiguous standalone word `Ultra`. Hidden regions keep selection/anchor facts without animation or repeated layout work.
- Dialog projection keeps title/breadcrumb/footer sticky, gives the body an independent logical scroll anchor, minimally auto-reveals the focused wrapped option, and exposes `item x of y` overflow. Resize retains focus/body anchor; at `50x14` an open submit/destructive dialog becomes a read-only Back/Close/Help summary with no hidden action ID.
- Apply the contract's anti-box-soup rule: prose is unboxed, a prompt/run group has one boundary/progress rail, panes use separators/space, overlays have the strongest border, and focus/live are the only orange roles. Kind letters and numbered lanes remain present in monochrome/ASCII.
- The four fixed surfaces are streaming chat/composer, swarm/agent pane, consensus docket/ticker/ledger, and research report/sources. They are representative visual evidence only; static consensus/workflow/research blocks do not claim domain functionality.

- [ ] **Step 1: Write breakpoint and projection RED tests**

Generate one cell above/below every width and height boundary and assert exact class, visible roles, focus relocation/restoration, minimum Main width, no overlap, exact density budget, and no destructive/send action in compressed/too-small output, including a dialog already open before shrinking.

```elixir
assert Layout.classify(%Size{columns: 170, rows: 34}) == :xl
assert Layout.classify(%Size{columns: 169, rows: 34}) == :wide
assert Layout.classify(%Size{columns: 150, rows: 29}) == :medium
assert Layout.classify(%Size{columns: 50, rows: 14}) == :small
assert Layout.classify(%Size{columns: 49, rows: 14}) == :too_small
assert Layout.classify(%Size{columns: 50, rows: 13}) == :too_small
```

For every projected Scene, assert `Scene.validate/1 == :ok`, all text positions hold `SafeText`, action IDs are opaque binaries, and action-table values never appear in `inspect(scene)`.

Add the complete state-catalogue fixture, both Medium drawer choices, long ASCII/CJK/RTL metadata, Needs-you overflow, disabled reason, pending/rejected/conflict notices, and the same ambiguous character/cursor state under narrow and wide policy. Traverse each breakpoint's focus graph: every enabled fake action is reachable, hidden/disabled actions are not activatable, and focused disabled reasons are readable through the action menu.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/layout_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/projector_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/representative_scenes_test.exs
```

Expected: FAIL because layout and projection do not exist.

- [ ] **Step 3: Implement deterministic rectangles and semantic blocks**

Resolve all rectangles in the projector. Virtual lists include total count, first logical index, visible item structs, opaque before/after cursors, fixed page-state sentinel, and an overscan of two items above/two below; they never receive the complete 10,000-item fixture. Use full trusted copy `FAKE DEMO — NO USER DATA` where the budget allows and fixed `FAKE — NO USER DATA` at narrower classes; both are explicit claim-boundary chrome.

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
Switcher.rank(Editor.t(), [Switcher.Entry.t()]) :: [Switcher.Entry.t()]
Activity.sort([ActivityItem.t()]) :: [ActivityItem.t()]
Question.answer_request(State.t(), PendingInteraction.t(), binary(), binary()) :: Request.t()
```

- Resolution consumes at most one action in priority order: dialog; overlay/switcher/filter/Other FieldKey; composer; focused content; global. Escape closes exactly one layer and cannot activate the newly exposed layer in the same input. `:back` moves one logical drill-down or restores an Activity return context.
- Global and content keys match spec section 12. A first `g` opens a bounded jump layer through `{:open_layer, %LayerSpec{kind: :jump}}`; `c/w/r/s/u/,` inside it navigate and close exactly that layer. This avoids renderer-owned chord state.
- `Ctrl+K` opens the switcher; every fake-visible action has a switcher/action-menu route. Closed prefixes are no-prefix all, `>` commands, `@` conversations, `#` runs/interactions, and `/` current-region items. Rank exact prefix, token prefix, then substring, with fixed kind/stable-label/ID ties. Empty query shows a fixed recent/default set; no match shows inert `NO RESULTS`. Async reranking preserves stable selected ID, else same-index successor, predecessor, then field. Escape/close clears only that layer's transient editor. Paste/IME/text always edit the active FieldKey and never the hidden composer.
- `Tab`/`Shift+Tab` cycle the explicit focus graph. `Ctrl+O` always inserts newline. Enhanced `Shift+Enter` inserts newline only when capabilities say it is distinguishable. `Alt+Enter` and `/queue` resolve to the same queue-intent activation. Paste resolves only to one editor paste action. Enter cannot send while a palette, question, confirmation, paste handling, or injected IME composition state is active.
- Only `:press` activates, submits, answers, approves, denies, stops, confirms, queues, or invokes a shortcut. `:repeat` is limited to editor/movement/selection/scroll operations; `:release` is inert. A valid activation installs pending state before emitting exactly one command and removes/disabled its action ID until one correlated outcome settles it.
- Activity order is Needs-you by earliest deadline/oldest creation, then running/paused, recent failures, recent completions, with stable timestamp/ID tie breaks. The fixture has two questions and one approval across conversations plus overflow. Opening any item stores destination/focus/row/selection/Main+Inspector anchors; Back restores all of it exactly.
- Needs-you bell is opt-in and fires once per newly visible unresolved interaction. Completion/failure remains durable in Activity and never steals focus or forces navigation.
- A question modal traps focus, uses fixed option labels plus sanitized external bodies, and routes Other through `FieldKey`. It keeps sticky title/breadcrumb/footer, independently scrolls/wraps the body, auto-reveals focused rows, starts on the safest action, and Escape does not answer/skip. Tab/Shift+Tab and arrows work with first/last controls offscreen and after resize. Answer option 2 emits exactly one revision-7 command request containing A2 run/node/interaction IDs and fixed request UUID. Pending visibly disables resubmission; accepted then resolved marks the modal settled/read-only. Rejected/deadline/interrupted/conflict/outcome-unknown preserve the selection/Other editor and show corrective state. Resolution by another client settles read-only without focus theft; a later close or Back restores the Activity row/context.
- A destructive confirmation always starts on Cancel. Bare Enter cannot select the destructive action until explicit movement changes focus.

- [ ] **Step 1: Write priority/focus/question RED tests**

Cover all key tables relevant to the fake surface plus press/repeat/release gating, mouse parity, FieldKey paste/IME isolation, switcher prefix/ranking/no-results/async selection repair, modal focus trap/autoreveal/body scroll, Small resize suppression, single Escape, Back, safest default, exact Activity return, settled-by-other-client behavior, pending duplicate suppression, every non-accepted outcome, paste-not-submit, layout/composer controls, focus-loss motion pause, and queue equivalence.

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
SessionRuntime.start_link(init: Init.t(), data_source: GenServer.server(), frame_ms: pos_integer()) :: GenServer.on_start()
SessionRuntime.register_terminal(server(), GenServer.server(), non_neg_integer(), Capabilities.t()) ::
  {:ok, :ets.tid()} | {:error, :not_binding | :duplicate_terminal | :binding_failed}
SessionRuntime.input(server(), Input.t()) :: :ok
SessionRuntime.snapshot(server()) :: State.t()
SessionRuntime.close(server(), :detach) :: :ok

EffectRunner.run(Effect.t(), context()) :: :ok
```

- `SessionRuntime` starts in `:binding`, creates its protected SceneSlot, and reference-binds itself to the already-started unbound DataSource. A test terminal registers its stable handle, generation, and capabilities separately and receives the SceneSlot handle. Initial watches and first draw are emitted only after both acknowledgements, regardless of acknowledgement order. Duplicate/stale/failed/timed-out binding closes DataSource, cancels admitted work, destroys SceneSlot, requests terminal restore if initialized, and terminates; there is no constructor PID cycle or half-bound runtime.
- Once running, `SessionRuntime` serializes terminal input, DataBridge actions, terminal generation/capability/lifecycle actions, draw settlements, request settlements, and timer actions. It applies every matching semantic event immediately, updates the Scene/ActionTable, and has at most one current-frame draw timer. Additional semantic updates mark the frame dirty but remain individually present in state.
- `SceneSlot` is a protected, runtime-owned ETS table with one latest already-sanitized Scene keyed by revision and a fixed byte ceiling. SessionRuntime writes it and sends the renderer only `{:draw, revision}`. TerminalOwner reads that exact revision and returns a compact acknowledgment/error, then drops the local Scene value. Whole Scene/draft/transcript values never become a terminal process's retained state or last mailbox message, preventing crash reports from printing visible content. Destroy the table when SessionRuntime stops.
- `SessionRuntime`, `DataSource.Fake`, and `Fake.Source` implement redacted `format_status/1` output containing counts/IDs/status words only; no draft, SafeText value, transcript, reasoning, question body, or Scene appears in Logger crash reports.
- `EffectRunner` dispatches only the closed Effect union. It owns timers under `TimerSupervisor`, forwards typed watch/query/command/cancel to the fake adapter, and reports one settlement action. Clipboard remains disabled in this spike unless an explicit bounded test capability is injected. Presenter handoff first completes terminal restore/closure, then emits the fixed control-free `Rerun with --plain` instruction and detaches; it never starts Plain.Session inside the same full-screen tree.
- Draw failure becomes a typed safe error and starts orderly terminal/client closure. Client detach first projects a fixed final `DETACHED — RUNS CONTINUE` Scene, writes it to SceneSlot, requests its draw, and waits for that matching acknowledgment within the owned deadline; it then cancels UI timers/requests/watches and closes the client DataSource whether the paint succeeded or failed. It emits no run/agent/domain Stop command.
- Test renderer accepts only draw tokens/revisions, reads the matching SceneSlot entry, and sends deterministic acknowledgements/errors. It contains no ExRatatui type and never retains the Scene in state/messages.

- [ ] **Step 1: Write runtime RED tests**

Assert both bind-ack orders emit no watch/draw early and exactly one initial set afterward; duplicate/data/terminal bind failure rolls back every resource. Then assert 100 ordered semantic deltas are all applied while at most one pending paint timer exists, an update arriving after timer creation is included in the next actual draw, an update arriving during an in-flight draw schedules the next draw after its acknowledgment, stale/mismatched draw results do nothing, resize/capability/ambiguous-width generation changes reproject, focus loss pauses only visible motion, final detach/handoff paint is attempted once, hidden/reduced-motion states own no animation timer, renderer error settles closure, and all timers/requests/watches disappear under monitored shutdown.

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

Use explicit `:binding | :running | :closing` runtime states and stable handles. Keep current Scene revision/ActionTable and one draw state `:idle | {:timer, timer_id} | {:in_flight, draw_token, attempted_revision}`. The timer identity is independent of Scene revision; when it fires, it reads and draws the latest current revision. If state advances during an in-flight draw, the matching result immediately schedules one new frame. Stale timer IDs and mismatched draw tokens/results do nothing without clearing the valid pending state. On close, increment watch generations, perform the bounded final-paint handshake, cancel timers/requests, unwatch, close the adapter, request terminal shutdown, and acknowledge only after monitored children settle.

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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/plain/session.ex`
- Create: `apps/swarm_code_cli/test/fixtures/plain/three_run_output.txt`
- Create: `apps/swarm_code_cli/test/fixtures/plain/question_commands.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/plain/options_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/plain/presenter_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/plain/command_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/plain/session_test.exs`

**Interfaces:**

```elixir
Plain.Options.select([binary()], Plain.Environment.t()) :: {:ok, Plain.Options.t()} | {:error, :invalid_option}
Plain.Presenter.new(Plain.Options.t()) :: Plain.Presenter.t()
Plain.Presenter.present(Plain.Presenter.t(), binary(), Delivery.t()) :: {Plain.Presenter.t(), [output_record()]}
Plain.Command.parse(SafeText.t(), Plain.Presenter.t(), binary()) :: {:ok, Action.t()} | {:error, SafeText.t()}
Plain.Session.start_link(options: Plain.Options.t(), data_source: GenServer.server(), input: io_device(), output: io_device(), error: io_device()) :: GenServer.on_start()
Plain.Session.close(GenServer.server(), :eof | :interrupt | :detach) :: :ok

output_record() :: {:stdout, iodata()} | {:stderr, iodata()}
```

- Selection is explicit `--plain`, or automatic when stdin is non-TTY, stdout is non-TTY, no controlling TTY is usable, or TERM equals `dumb` case-insensitively. Plain may consume deterministic commands from piped stdin; full-screen raw polling never starts with a piped input. `--no-alt-screen` remains an interactive renderer option that preserves pre-existing scrollback and the final/restoration frame, not append-only redraw history, and does not imply plain when all three TTY checks pass. `--ascii`, `--no-color`, present `NO_COLOR`, `--reduced-motion`, and `--ambiguous-width=narrow|wide` are retained in options.
- Plain output is chronological and append-only, deduplicated by `{source_epoch, scope kind/id/generation, sequence}`. It uses fixed headings, exact state words, sanitized content, and explicit prompts. It emits no cursor rewriting, alternate-screen bytes, terminal hyperlinks, animation, bell, or terminal controls other than LF record separators.
- `Plain.Session` is the one owner of the bound DataSource, bounded line reader, prompt registry, and stdout/stderr writers. It serializes deliveries and complete input lines into non-interleaved LF-terminated records. After async output it re-emits the still-current prompt. Simultaneous completion/question delivery follows the runtime ingress order; no task writes directly to either stream.
- Prompt grammar is `PROMPT <scope>/<id>@<revision> ...`. Commands cover every fake action, including `answer Q1@7 2`, `approve|deny ID@REV`, lifecycle controls, Back, send, queue, follow, help, and detach. Bare `2` is valid only while exactly one current unresolved numbered prompt has been emitted at the same revision; otherwise a fixed correction shows the full command. Another-client settlement invalidates the stale prompt and emits settled/new-prompt records. Rejected/deadline/interrupted/conflict/outcome-unknown, invalid/overlong input, and unknown commands preserve state and recover. EOF/Ctrl+C detach only, never Stop.
- ASCII substitutes trusted box/glyph chrome only. No-color/reduced-motion output remains semantically identical. The full-screen TUI is not called screen-reader accessible; plain is the screen-reader acceptance surface/targeted path, with a proven accessibility claim deferred until Phase 5 VoiceOver and Orca runs.

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
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/plain/options_test.exs apps/swarm_code_cli/test/swarm_code_cli/plain/presenter_test.exs apps/swarm_code_cli/test/swarm_code_cli/plain/command_test.exs apps/swarm_code_cli/test/swarm_code_cli/plain/session_test.exs
```

Expected: FAIL because the permanent owned plain line surface does not exist.

- [ ] **Step 3: Implement one sanitized line protocol over typed deliveries**

Pass every external fragment through `SafeText`; fixed prompt syntax comes from `SafeText.chrome/1`. Session binds the unbound DataSource to itself, owns one bounded read request at a time, scans both stdout and stderr records before writing, and performs one idempotent close path. Tests cover prompt re-emission after async output, bare-number ambiguity, stale resolution by another client, invalid recovery, EOF/interrupt, and byte-for-byte stdout/stderr order.

- [ ] **Step 4: Run GREEN in every degraded combination**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/plain --seed 0
NO_COLOR=1 mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/plain --seed 0
```

Expected: PASS for Unicode/ASCII, color/no-color, motion/reduced-motion, explicit/automatic plain.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/plain apps/swarm_code_cli/test
git commit -m "feat: add permanent plain line session"
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
- Before constructing any widget, `SceneCompiler` validates schema version, Scene/backend size and ambiguous-width equality, every rectangle, visible-item/height bounds, palette role, cursor bounds, and SafeText provenance. It catches bridge encoding exceptions and returns a static typed error without logging content. It never calls ExRatatui layout NIFs because Projector already resolved cell rectangles.
- Input normalization maps fixed ExRatatui string codes/modifiers to neutral atoms, printable scalar keys to `{:text_fragment, kind, fragment, modifiers}`, paste to one reducer-facing payload bounded at 262,144 bytes, resize to positive `Size`, focus events, and mouse only when enabled. Exact 0.13.0 emits no composition lifecycle input, so adapter capabilities mark it unavailable and normalizer tests never fabricate support. Unknown/null values return `:ignore`/typed error and never atomize. `poll_event/2` treats every ExRatatui `{:error, reason}` as terminal failure; it never ignores and rearms after a poll error. CellSession raw-byte parsing is not used as local-input evidence because it omits mouse/focus and scalarizes bracketed paste; those structs are injected directly in headless normalizer tests, while real local Crossterm input is tested through PTY.
- `CellCapture` maps the ExRatatui snapshot immediately into `CellFrame`; it derives wide-cell continuation markers with `Width` using `Scene.ambiguous_width`, includes that policy plus Scene cursor/focus/action metadata, and releases every ExRatatui struct before returning. This compensates for `CellSession.Cell` not explicitly marking a wide trailing cell while testing the exact visual result.
- `CursorSequence.encode/1` accepts only a validated neutral cursor and returns fixed CSI hide or one-based row/column position-plus-show iodata. It is emitted only after a successful local draw. No arbitrary string enters control output. The theme sets no underline color because CellSession cannot expose it.
- `MainScreenMode.after_init/1` implements the exact-pinned `--no-alt-screen` feasibility path: after Native init and before any Scene draw it emits a fixed LeaveAlternateScreen sequence, marks the adapter main-screen-only, and performs every later draw/cursor operation on that screen. PTY tests seed scrollback before init and prove it remains, prove no later EnterAlternateScreen sequence occurs, and prove shutdown leaves the final/restoration frame. This mode does not promise append-only history of every redraw. If this backend behavior is not stable on any target, the ExRatatui no-alt dimension fails and the renderer is rejected; the permanent neutral option remains and must be implemented by the selected fallback before release.
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
- Create: `apps/swarm_code_cli/test/fixtures/goldens/ex_ratatui_013/*.json` (exact 87 files under the naming scheme below)
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_matrix_test.exs`

**Interfaces:**

```elixir
Renderer.Golden.capture(binary(), Scene.t(), Renderer.CellFrame.t()) :: map()
Renderer.Golden.encode(map()) :: iodata()
Renderer.Golden.verify_all(Path.t()) :: :ok | {:error, [binary()]}
Mix.Tasks.SwarmCode.Tui.Goldens.run(["--check" | "--accept"])
```

- File names are `{scene}--{columns}x{rows}--{color}[--ascii][--variant].json`. The manifest lists and SHA-256 hashes exactly:
  - `chat`, `swarm`, `consensus`, `research` × `80x24`, `120x40`, `160x50` × `truecolor`, `ansi256`, `ansi16`, `monochrome`: 48;
  - `workspace` × `170x34`, `50x16`, `50x14` × four color modes: 12;
  - `too-small--49x13--monochrome--ascii`: 1;
  - four representative scenes × `80x24--monochrome--ascii`: 4;
  - `question` and `destructive-confirmation` × `120x40` × truecolor/monochrome: 4.
  - 18 curated risk frames: `workspace--50x14--monochrome--ascii.json`, `workspace--120x40--truecolor--reduced-motion-active.json`, `question--80x24--truecolor.json`, `destructive-confirmation--80x24--monochrome.json`, `question--50x16--monochrome--ascii.json`, `destructive-confirmation--50x16--monochrome--ascii.json`, `workspace--100x24--truecolor--navigator-docked.json`, `workspace--100x24--truecolor--inspector-docked.json`, `workspace--72x20--monochrome--long-content.json`, `workspace--80x24--truecolor--focus-main.json`, `workspace--80x24--truecolor--focus-composer.json`, `workspace--80x24--monochrome--resync-retry.json`, `workspace--80x24--truecolor--mutation-pending.json`, `workspace--80x24--monochrome--mutation-conflict.json`, `workspace--72x20--ansi16--disabled-reason.json`, `activity--50x16--monochrome--needs-you-overflow.json`, `workspace--80x24--truecolor--ambiguous-narrow.json`, and `workspace--80x24--truecolor--ambiguous-wide.json`.
- Total is exactly 87: the original 69 coverage frames plus those 18 risk-selected frames, not a Cartesian expansion. All IDs, virtual time, elapsed labels, prices, stream chunks, selection, and cursor are fixed.
- Each canonical JSON record includes schema version, fixture ID, semantic intent, required assertion tags, size/class, ambiguous-width policy, focused region/item, sorted action IDs, cursor row/column/visibility, and row-major cells. Tags include `no_send`, `focus_visible`, `sticky_footer`, `static_progress`, `full_value_in_inspector`, and `pending_disables_action` where relevant, so a stable but semantically wrong render fails. Every cell records grapheme, foreground, background, sorted modifiers, and wide continuation. Run-length encoding may compress identical adjacent cells, but `verify_all/1` must expand to exactly `columns * rows` cells before comparison.
- Cursor fields in these JSON records are the renderer-neutral semantic cursor because CellSession exposes no physical cursor. The same test invokes `ExRatatui013.CursorSequence.encode/1` and stores its fixed expected bytes in the cursor record; Task 19 must observe those exact bytes on a real PTY after the frame. The matrix fails if semantic, encoded, and PTY-observed positions differ. Colored underline is not used because CellSession omits underline color.
- `--check` never writes. `--accept` refuses unless `UPDATE_GOLDENS=1`; it writes same-directory temporary files then atomically renames and rewrites the manifest last. No test silently refreshes expected output.

- [ ] **Step 1: Write a RED matrix test with no goldens present**

```elixir
test "the renderer spike has the exact 87-frame risk-selected evidence set" do
  manifest = GoldenFixtures.read_manifest!()
  assert manifest["schema_version"] == 1
  assert length(manifest["frames"]) == 87
  assert :ok = Golden.verify_all(GoldenFixtures.root())
end
```

Also mutate one cell style, continuation, cursor, focus ID, and action ID in task-owned fixture copies and assert each produces a field-specific diff.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/golden_matrix_test.exs
```

Expected: FAIL because the manifest and 87 frames do not exist.

- [ ] **Step 3: Implement deterministic capture and explicitly accept first goldens**

```bash
UPDATE_GOLDENS=1 mise exec -- mix swarm_code.tui.goldens --accept
mise exec -- mix swarm_code.tui.goldens --check
```

Inspect representative truecolor, monochrome, ASCII, reduced-motion-active, `50x14`, constrained question/confirmation, focus-pair, long-content, resync, pending/conflict, disabled-reason, Needs-you-overflow, and ambiguous narrow/wide frames as expanded rows. Confirm every manifest intent/tag plus no overlap, clipped action, missing focus, raw control, or untrusted approval label before treating generated files as expected behavior.

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
TerminalOwner.start_link(runtime: GenServer.server(), adapter: module(), options: Renderer.Options.t()) :: GenServer.on_start()
TerminalOwner.draw(server(), draw_token :: binary(), scene_revision :: non_neg_integer()) :: :ok
TerminalOwner.suspend(server(), command_sequence :: non_neg_integer()) :: :ok
TerminalOwner.resume(server(), command_sequence :: non_neg_integer()) :: :ok
TerminalOwner.shutdown(server(), deadline_ms :: non_neg_integer()) :: :ok | {:error, :deadline_exceeded}
```

- TerminalOwner starts last, after source, unbound client DataSource, and binding SessionRuntime. It is the only BEAM process that calls adapter init/read/current-size/draw/shutdown and writes fixed renderer control sequences. After init it calls `SessionRuntime.register_terminal/4` with its stable handle, generation, and complete capabilities; the acknowledgement returns the protected SceneSlot handle. Suspend performs shutdown/restore and retains only neutral suspended metadata; resume calls init again. It stores live adapter resource state but never Scene, ActionTable, draft, DTO, or transcript. It accepts only draw token/revision and reads the exact slot entry transiently.
- The allowed-path `selector.ex` defines generic `SwarmCodeCLI.UI.Renderer.Selector.primary/0`; only that file returns `ExRatatui013.Adapter`. Demo/Application call the generic selector and therefore contain no renderer implementation alias/type/string outside the architecture exemption.
- Use a proper GenServer with `Process.flag(:trap_exit, true)`. Record the supervisor parent PID and explicitly handle its `{:EXIT, parent, reason}` by stopping input polls, invoking adapter shutdown, restoring internal baseline, acknowledging LauncherControl, and then exiting. Do not rely on a whole-loop `try/after`. Child spec uses a 5,000 ms shutdown; if orderly restoration exceeds it, the permanent fake release terminates the client VM so the external launcher—not a restarted terminal child—performs final restoration.
- UISupervisor is `:one_for_all` with zero restart intensity and stable session-scoped handles. Its order is Fake.Source → unbound DataSource → SessionRuntime in `:binding` → TerminalOwner. Initial watches/draw occur only after DataSource-owner and terminal registrations both acknowledge. Data bind failure closes the client and slot; adapter/terminal bind failure restores the terminal then asks runtime to close DataSource/slot; any failure terminates the tree. TerminalOwner is not restarted into an unknown terminal state. Normal resume is an explicit in-process state transition that reinitializes the same owner PID and increments terminal generation.
- Before every local draw, call adapter `current_size/1`. If it differs from the Scene size, do not draw; send neutral `{:resize, size}` and `{:terminal_capabilities, next_generation, capabilities}` actions to SessionRuntime, then await a matching newer Scene revision. Draw success/error is returned as `{:draw_result, draw_token, scene_revision, result}`. Stale slots/tokens never clear current draw state.
- Input polling uses cancellable 0-20 ms calls and drains at most 64 ready events before checking owner messages. Every renderer poll error is terminal. Init/resume sends capability/lifecycle actions; suspend stops polling, restores terminal/input, sends `:suspended`, and waits for launcher protocol; resume redetects size/capabilities, increments generation, sends `:resumed`, and requests the latest full Scene.
- Internal baseline restoration is best effort plus exact checked `stty -g`; the external launcher remains the final safety boundary. Any internal mismatch, including Darwin PENDIN, is a failed lifecycle fact even when the launcher repairs it.

- [ ] **Step 1: Write TerminalOwner RED tests**

Use a fake adapter and runtime-owned protected SceneSlot. Assert exact start order, no initial effect before both binds, only revision tokens enter the mailbox, exact size/ambiguous-policy match draws once, resize race does not paint stale cells, draw errors surface, 64-event fairness, capability generation on resume, every bind-failure rollback, explicit parent-exit restoration, no automatic restart, and redacted `format_status/1`.

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
LauncherControl.start_link(runtime: GenServer.server(), control_fifo: Path.t(), ack_fifo: Path.t(), nonce: binary(), launcher_pid: pos_integer()) :: GenServer.on_start()
LauncherControl.ack(server(), non_neg_integer(), :ready | :restored | :failed) :: :ok
LauncherControl.request_suspend(server()) :: :ok
```

- The POSIX outer launcher creates one `0700` `mktemp -d` directory and two mode-`0600` FIFOs before child boot, opens both ends to avoid open-order deadlock, generates a 128-bit lowercase-hex nonce, exports only FIFO paths/nonce/launcher PID, and waits for the child's `ready` record before raw mode. Records are at most 128 bytes, newline terminated, strictly increasing, exact-token parsed, and nonce checked. The directory/FIFOs are removed in the EXIT trap.
- The child registers only supported `System.trap_signal(:sigusr2, id, fun)`; the callback sends a message and returns immediately. The launcher traps external HUP/INT/TERM/TSTP/CONT **and SIGUSR1**. Its SIGUSR1 handler marks work pending; the main state machine drains and validates at most the bounded child-request records before acting. Do not call unsupported child `System.trap_signal` for SIGINT or SIGCONT, do not replace the VM SIGTERM handler, and do not install a child TSTP trap.
- UISupervisor's final order is Fake.Source → unbound DataSource → binding SessionRuntime → LauncherControl ready acknowledgement → TerminalOwner registration/raw mode. LauncherControl resolves the stable runtime handle and later registers the TerminalOwner handle; neither constructor requires the later PID. A signal arriving during boot is queued as one closed command and cannot bypass restoration.
- For HUP/INT/TERM, launcher writes `detach` or `shutdown`, signals child SIGUSR2, and starts one owned escalation watchdog: wait 5 seconds for matching restored ack, then TERM; wait 2 seconds, then KILL. On ack, cancel and reap the watchdog, wait for the exact child, preserve its exit code, and run final restore. A direct signal/abrupt exit of the BEAM is detected by `wait`; the launcher restores without requiring child callbacks.
- Ctrl+Z becomes neutral suspend input. Child writes one bounded `request_suspend` record and signals the exact launcher PID with SIGUSR1. Launcher SIGTSTP and a validated child request enter the same transition: write ordinary `suspend` plus SIGUSR2 to the exact child, wait at most two seconds for matching `restored`, then send SIGSTOP to the exact child and SIGSTOP to the exact launcher. There is no recursive TSTP forwarding, disposition reset, or orphan-process-group stop dependency; isolated `setsid` PTYs therefore behave the same as interactive shells. After an external SIGCONT resumes the exact launcher, it sends SIGCONT to the exact child, writes `resume` plus SIGUSR2, and waits for matching `ready`. Both PIDs are resumed explicitly.
- Launcher captures validated exact `stty -g` before child start. Its EXIT handler, regardless of child status/escalation, writes fixed disable-mouse/focus/paste, leave-alt, and show-cursor sequences directly to `/dev/tty`, then applies the exact baseline and writes a sentinel. If launcher and child are both SIGKILLed, restoration is not claimed; document `reset; stty sane`.
- `tui_pty_driver.py` uses `pty.openpty`, forks, calls `setsid`, applies `TIOCSCTTY` to the slave, duplicates slave to fd 0/1/2, creates a dedicated process group/foreground pgrp, then execs the launcher. Parent retains master and slave FDs, uses selectors/readiness records rather than sleeps, sends signals to the exact launcher or child requested by the case, and compares `stty -g` on the retained slave before/after. This makes `/dev/tty` and job control real.
- PTY modes are normal, compiler/draw/poll error, parent supervisor shutdown, child abrupt exit, launcher INT/TERM/HUP, Ctrl+Z, launcher TSTP/CONT, alt-screen, and no-alt-screen. No-alt seeds main-screen scrollback, verifies the fixed immediate LeaveAlternateScreen before first draw, rejects any later EnterAlternateScreen, and verifies preserved scrollback/final output. Failure records the ExRatatui no-alt dimension rejected while the permanent neutral option remains.

- [ ] **Step 1: Write launcher protocol and PTY RED tests**

Assert nonce/sequence/bounds, SIGUSR1 trap/drain limits, stale/replayed request rejection, one acknowledgment, exact `restored → SIGSTOP child → SIGSTOP launcher → SIGCONT launcher → SIGCONT child → resume → ready` order, external TSTP translation, no recursive TSTP/orphan-group dependency, signal exit-code preservation, controlling TTY, cursor/physical position bytes, exact stty/PENDIN equality before internal and after external restore, final sentinel, and zero surviving watchdog/FIFO/process.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/launcher_control_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs
```

Expected: FAIL because launcher control and PTY harness do not exist.

- [ ] **Step 3: Implement one non-recursive launcher state machine**

Shell states are `booting/running/waiting_restore/stopped/resuming/exited`; every trap sets a closed pending event consumed by one transition function. The SIGUSR1 path drains no more than the record/count/byte bound. Validate exact child/launcher PID, nonce, and sequence before `kill` or FIFO use. Launcher diagnostics go to a separate bounded file/stderr, never TUI stdout. TerminalOwner explicitly closes before acknowledgment; external EXIT cleanup is unconditional.

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
- Unicode normalizer/editor cases cover accents, Georgian, RTL logical editing with visible caret/selection edges, CJK, the same ambiguous symbols under narrow and wide end-to-end policy, modifiers, flags, ZWJ, VS15/16, Option/Alt, Shift+Tab, press/repeat/release activation gating, focus, enhanced fallback, mouse-off/on, 10,000 key events, and 100 constructed paste events. Injected neutral composition tests pass editor/keymap; ExRatatui IME capability remains unavailable.
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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/release/identity_step.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/release/dependency_manifest_step.ex`
- Create: `apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.release_manifest.ex`
- Create: `scripts/acceptance/tui_tree_snapshot.py`
- Create: `apps/swarm_code_cli/test/fixtures/release/identity-precompiled.json`
- Create: `apps/swarm_code_cli/test/fixtures/release/identity-source-built.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/demo/application_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/demo/finite_script_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/release_config_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/identity_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/release_step_order_test.exs`

**Interfaces:**

```elixir
SwarmCodeCLI.Release.IdentityStep.pre_assemble(Mix.Release.t()) :: Mix.Release.t()
SwarmCodeCLI.Release.DependencyManifestStep.post_assemble(Mix.Release.t()) :: Mix.Release.t()
Mix.Tasks.SwarmCode.Tui.ReleaseManifest.run(["--check", release_root()]) :: :ok
ExRatatui013.ReleaseIdentity.verify_loaded_nif(identity_manifest()) :: :ok | {:error, Renderer.Error.t()}
```

- Application is idle by default; exact `SWARM_CODE_BOOT=fake_demo` starts fake composition. Unknown strings fail static. The release `:swarm_code_tui_spike` seeds core/CLI only, excludes daemon, includes ERTS, sets distribution none, and inventories required renderer/OTP transitive apps without starting SSH/distribution listeners.
- Root release configuration has this executable order, not a prose-only build convention:

```elixir
steps: [
  &SwarmCodeCLI.Release.IdentityStep.pre_assemble/1,
  :assemble,
  &SwarmCodeCLI.Release.DependencyManifestStep.post_assemble/1
]
```

- `pre_assemble/1` writes `priv/renderer_identity.json` atomically into the built `swarm_code_cli` application input tree before `:assemble`. `post_assemble/1` walks the actual final `release.path` bytes after assembly and atomically writes `release-dependencies.json` at the release root. The check task independently recomputes both identities and rejects a missing/reordered hook, a manifest derived from pre-assembly inputs, or any final byte mismatch.
- Overlay command is the audited non-exec external launcher from Task 19. It accepts only permanent presentation flags, complete script, and fixed lifecycle fault modes; it forwards signals, waits, restores, and preserves child exit.
- The identity fields separately identify: Hex inner/outer checksum; tag object/source commit; target/NIF ABI; `build_kind` precompiled or source; precompiled archive URL/SHA-256 or null; extracted loaded `.so/.dylib` relative path/SHA-256; Cargo.lock SHA-256; source crate/source-build output hashes or null; OTP/Elixir/Rust versions. Archive hash, extracted NIF hash, and source-built NIF hash remain separate fields and are never compared as if equal.
- Runtime resolves only `ExRatatui.Native.load_from/0` inside the exact adapter, hashes that extracted file, and matches the embedded manifest before native init. Linux source builds bake their new extracted hash. The build task also emits `release-dependencies.json` listing every assembled application, version, beam/native file hash, architecture, and link metadata.
- Tests acknowledge the dependency-source `erl_crash.dump` but reject it from Git-tracked files, source archives, dependency manifest, and assembled release. Release manifest also rejects non-selected NIF siblings, compiler/Cargo/Mix, daemon/Exqlite, and runtime downloaders.

- [ ] **Step 1: Write RED release and identity tests**

Inspect root release config, both identity fixtures, tampered archive-vs-extracted/source-built hashes, source-build fields, assembled dependency manifest schema, fake finite Plain.Session execution, tree snapshot behavior, and crash-dump exclusion. The RED ordering test runs assembly with the hooks absent/misordered and proves the identity is missing from the assembled application or the dependency manifest does not match a deliberately changed final file; GREEN requires identity inside the assembled release and manifest hashes from final bytes.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/demo/application_test.exs apps/swarm_code_cli/test/swarm_code_cli/demo/finite_script_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/release_config_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/identity_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/release_step_order_test.exs
```

Expected: FAIL because release/demo/identity manifest do not exist.

- [ ] **Step 3: Build and verify locally without touching user state**

```bash
build_root=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-build-home.XXXXXX")
mkdir -p "$build_root/home" "$build_root/config" "$build_root/data" "$build_root/state" "$build_root/cache"
HOME="$build_root/home" XDG_CONFIG_HOME="$build_root/config" XDG_DATA_HOME="$build_root/data" XDG_STATE_HOME="$build_root/state" XDG_CACHE_HOME="$build_root/cache" EX_RATATUI_BUILD="${SWARM_LINUX_BUILD_FROM_SOURCE:-0}" MIX_ENV=prod mise exec -- mix release swarm_code_tui_spike --overwrite
mise exec -- mix swarm_code.tui.release_manifest --check _build/prod/rel/swarm_code_tui_spike

runtime_root=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-runtime-home.XXXXXX")
snapshot_root=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-runtime-snapshot.XXXXXX")
mkdir -p "$runtime_root/home" "$runtime_root/config" "$runtime_root/data" "$runtime_root/state" "$runtime_root/cache"
python3 scripts/acceptance/tui_tree_snapshot.py "$runtime_root" > "$snapshot_root/before.json"
env -i HOME="$runtime_root/home" XDG_CONFIG_HOME="$runtime_root/config" XDG_DATA_HOME="$runtime_root/data" XDG_STATE_HOME="$runtime_root/state" XDG_CACHE_HOME="$runtime_root/cache" TERM=dumb PATH=/usr/bin:/bin SWARM_CODE_BOOT=fake_demo _build/prod/rel/swarm_code_tui_spike/bin/swarm-code-demo --plain --script complete
python3 scripts/acceptance/tui_tree_snapshot.py "$runtime_root" > "$snapshot_root/after.json"
cmp "$snapshot_root/before.json" "$snapshot_root/after.json"
```

Expected: the build may populate only its dedicated build HOME/XDG; the separately created runtime HOME/XDG snapshot is byte-for-byte unchanged after finite fake output. The assembled release already contains exact identity/dependency manifests and contains no daemon/crash dump/runtime downloader.

- [ ] **Step 4: Run GREEN and commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/demo apps/swarm_code_cli/test/swarm_code_cli/release --seed 0
git add mix.exs apps/swarm_code_cli config rel scripts/acceptance/tui_tree_snapshot.py
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
mise exec -- mix swarm_code.tui.release_manifest --check _build/prod/rel/swarm_code_tui_spike
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
- Create: `scripts/acceptance/tui_evidence_release.sh`
- Create: `scripts/acceptance/tui_evidence_inventory.exs`
- Create: `scripts/acceptance/tui_evidence_validate.exs`
- Create: `apps/swarm_code_cli/test/fixtures/evidence/valid-target.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/native_dispatch_test.exs`

**Interfaces:**

```elixir
Mix.Tasks.SwarmCode.Tui.Evidence.run([target(), output_path()] | ["--check" | "--ready-to-seal" | "--decision", evidence_directory()]) :: :ok
```

```text
tui_native_dispatch.sh --workflow-ref main --bootstrap-sha MAIN_SHA --expected-sha FEATURE_SHA --deadline-seconds 10800 --output-dir DIR
tui_evidence_release.sh create-draft --tag TAG --source-sha SHA --harness-sha SHA --harness-script-sha256 SHA256 --bootstrap-sha SHA --bootstrap-blob SHA --output RECORD
tui_evidence_release.sh upload-draft --release-id ID --inventory INVENTORY --asset-dir DIR
tui_evidence_release.sh seal --release-id ID --inventory INVENTORY --download-dir DIR
tui_evidence_inventory.exs SOURCE.json AUTOMATED_INVENTORY.json MANUAL_ASSET_DIR OUTPUT_INVENTORY.json STAGE_DIR
```

- Task 0's default-branch `tui-native-bootstrap.yml` is the only dispatchable workflow. `tui_native_dispatch.sh` selects its closed `native_evidence` phase; it never expects a feature-only workflow to be dispatchable. Every job checks out and asserts the exact expected feature commit before running `tui_target_gate.sh`.
- The native phase runs contracts, 87 goldens, scenario, disposable fuzz/sanitizer, 1,000 PTY cycles, 30-minute tagged soak, no-alt, offline clean-host release, and native inspection. Linux source-builds on exact 22.04 native architecture.
- Inspection separates precompiled archive, extracted NIF, and source-built NIF hashes; validates embedded identity/dependency manifests generated by the ordered release hooks; and rejects wrong architecture/RPATH/shared libs, GLIBC >2.35/pidfd symbols, crash dump, runtime toolchain/downloader, and daemon/Exqlite.
- Dispatch requires Task 1's complete policy/infrastructure record, verifies the current `origin/main` workflow blob equals the accepted bootstrap blob, validates online labels and the exact pushed source commit, and identifies one exact run by run-name/request ID/event/path/bootstrap head SHA. It uses an absolute 10,800-second deadline, bounded five-second polling, cancel plus 60-second cancellation observation, and never calls open-ended watch.
- `tui_evidence_release.sh` has only `create-draft`, `upload-draft`, and `seal` subcommands. Upload refuses a non-draft release, accepts an already-present asset only when name/size/digest match, uploads only missing inventoried files, and refuses replacement/unexpected names. Seal compares the complete name/size/SHA-256 inventory, publishes once, requires repository policy enabled and release JSON `immutable: true`, re-downloads every permanent asset URL, verifies every digest, and has no post-publication upload path.
- Evidence schema includes source/harness/bootstrap identities, licenses, native paste/IME/no-alt/cursor/stty facts, raw command hashes, metrics/PTYS, permanent-asset references, and pass/fail/incomplete.

- [ ] **Step 1: Write RED tooling, dispatch, draft, and immutable-seal tests**

Use valid/tampered manifests and fake `gh` responses for unavailable runner, feature-only workflow, wrong bootstrap blob/head/source SHA, timeout/cancel, archive-vs-NIF confusion, GLIBC 2.39, crash dump, emulation, incomplete/duplicate/unexpected inventory, digest mismatch, upload-after-publish attempt, repository policy false, release `immutable: false`, and three-of-four.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/native_dispatch_test.exs
```

Expected: FAIL because evidence tooling does not exist.

- [ ] **Step 3: Implement, run GREEN, commit, and push the tooling commit**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/native_dispatch_test.exs
chmod 0755 scripts/acceptance/tui_native_inspect.sh scripts/acceptance/tui_release_smoke.sh scripts/acceptance/tui_target_gate.sh scripts/acceptance/tui_native_dispatch.sh scripts/acceptance/tui_evidence_release.sh
git add apps/swarm_code_cli scripts/acceptance
git commit -m "ci: scaffold native renderer evidence"
git push origin feature/tui-interaction-spike
```

Expected: the exact tooling commit is remote. No native dispatch occurs until the manual harness is included in the common source commit in Task 25.

---

### Task 25: Implement and Push the Exact Manual Observation Harness

**Files:**
- Create: `scripts/acceptance/tui_terminal_matrix.sh`
- Create: `scripts/acceptance/tui_manual_record.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs`
- Create: `docs/evidence/tui-renderer/manual/README.md`

**Interfaces:**

```text
tui_terminal_matrix.sh --source-sha SHA --target TARGET --emulator NAME --context local|tmux|ssh --output DIR
tui_manual_record.exs --source-sha SHA --harness-sha SHA --script-sha256 SHA256 --record RECORD
```

- The terminal matrix runs sustained Unicode/ambiguous-width/RTL editing and paste, exact key phases, overlay focus/resize, optional mouse with keyboard parity, truecolor/256/16/mono, Unicode/ASCII, reduced motion, alt/no-alt, suspend/continue, normal/error/signal exit, exact stty, cursor, and scrollback observations. It only invokes closed fake-demo modes and writes bounded raw records.
- `tui_manual_record.exs` produces unsigned canonical JSON only. It requires equal source/harness commit identities for this spike plus the exact SHA-256 of `tui_terminal_matrix.sh`; it refuses a dirty or different checkout. Signing remains external with the registered operator's non-exported key.

- [ ] **Step 1: Write manual-harness RED schema, digest, and verification cases**

Use task-owned temporary SSH keys to test canonical record generation, valid signature, wrong namespace/key/source/harness/script digest, tampered JSON, missing emulator lane, failed fact, and expired-only asset. Harness tests also reject a dirty checkout and a source commit not present on the remote.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs
```

Expected: FAIL because the manual harness and record tool do not exist.

- [ ] **Step 3: Implement the closed harness and unsigned record builder**

Implement only the documented target/emulator/context matrix and canonical unsigned JSON. Reject dirty/different source, mismatched script digest, unknown lane/fact, over-bound raw output, and any attempt to open a private key. Keep every diagnostic static-safe.

- [ ] **Step 4: Run focused GREEN**

```bash
chmod 0755 scripts/acceptance/tui_terminal_matrix.sh
git diff --check
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs --seed 0
```

Expected: PASS with no observation or private-key access.

- [ ] **Step 5: Commit and push the exact common harness/source commit**

```bash
git add scripts/acceptance/tui_terminal_matrix.sh scripts/acceptance/tui_manual_record.exs apps/swarm_code_cli/test/swarm_code_cli/release/manual_evidence_test.exs docs/evidence/tui-renderer/manual/README.md
git commit -m "test: add terminal observation harness"
git push origin feature/tui-interaction-spike
harness_sha=$(git rev-parse HEAD)
test "$(git rev-parse origin/feature/tui-interaction-spike)" = "$harness_sha"
harness_script_sha=$(shasum -a 256 scripts/acceptance/tui_terminal_matrix.sh | awk '{print $1}')
```

Expected: `harness_sha` is the one pushed source commit that both automated gates and human observations must execute. No signed observation exists before this point.

---

### Task 26: Run Automated Native Gates and Create the Draft Evidence Release

**Files:**
- Create: `docs/evidence/tui-renderer/source.json`
- Create: `docs/evidence/tui-renderer/automated/inventory.json`
- Create after automated runs: `docs/evidence/tui-renderer/automated/macos-arm64.json`
- Create after automated runs: `docs/evidence/tui-renderer/automated/macos-x86_64.json`
- Create after automated runs: `docs/evidence/tui-renderer/automated/ubuntu-22.04-arm64.json`
- Create after automated runs: `docs/evidence/tui-renderer/automated/ubuntu-22.04-x86_64.json`

**Interfaces:**
- Consumes Task 25's exact pushed `harness_sha` and Task 0's verified default-branch workflow blob.
- Produces four truthful automated records, one common source identity, and draft-only asset references.

- NIF ABI 2.17 archive hashes are macOS arm64 `454b5e7d4f2002837e55d00e8fc8b9eea43fca165b9d6b82ab75d0bd358fc7a4`, macOS x86_64 `5600864b8083a1f61c57831a28ea0dd342ac89abed8c71d51d058c6a672daa2d`, Linux x86_64 GNU `95a23a060aadc58adea3fefd724dc7bb8ad4aead3152fac0ee62f130fe510320`, and rejected Linux arm64 GNU `1eb8f5b52d774c71590451ada25fef6423ff2e0419e09736676ca97df05d5f0c`. Observed macOS-arm64 extracted dylib is separately `ba42cc015e001296dd5beb78fb5262ff3b7866b7bc350cca08eb98ba1cfb8d9d`; other extracted/source hashes come from assembled bytes.
- Raw releases, logs, PTY/sanitizer/metric records, identity/dependency/SBOM/license manifests, and attestations are uploaded to draft evidence-only prerelease `tui-spike-evidence-<full-source-sha>`. Automated JSON stores draft asset ID/digest only. Expiring workflow artifacts and draft URLs never satisfy durable evidence.

- [ ] **Step 1: Verify exact common source and dispatch the default-branch native phase**

```bash
git fetch origin main feature/tui-interaction-spike
source_sha=$(git rev-parse HEAD)
test -z "$(git status --short)"
test "$(git rev-parse origin/feature/tui-interaction-spike)" = "$source_sha"
harness_script_sha=$(shasum -a 256 scripts/acceptance/tui_terminal_matrix.sh | awk '{print $1}')
bootstrap_sha=$(git rev-parse origin/main)
bootstrap_blob=$(git rev-parse "origin/main:.github/workflows/tui-native-bootstrap.yml")
test "$bootstrap_blob" = "$(jq -r .bootstrap_workflow_blob docs/evidence/tui-renderer/infrastructure.json)"
automated_asset_dir="${TMPDIR:-/tmp}/swarm-tui-automated-assets-$source_sha"
mkdir "$automated_asset_dir"
scripts/acceptance/tui_native_dispatch.sh --workflow-ref main --bootstrap-sha "$bootstrap_sha" --expected-sha "$source_sha" --deadline-seconds 10800 --output-dir "$automated_asset_dir"
```

Expected: four result records from jobs whose checked-out/source SHA equals `source_sha`, or truthful failed/incomplete records; dispatcher cancels by deadline.

- [ ] **Step 2: Create the draft prerelease, upload automated assets, and validate draft records**

```bash
source_sha=$(git rev-parse HEAD)
harness_script_sha=$(shasum -a 256 scripts/acceptance/tui_terminal_matrix.sh | awk '{print $1}')
bootstrap_sha=$(git rev-parse origin/main)
bootstrap_blob=$(git rev-parse "origin/main:.github/workflows/tui-native-bootstrap.yml")
tag="tui-spike-evidence-$source_sha"
automated_asset_dir="${TMPDIR:-/tmp}/swarm-tui-automated-assets-$source_sha"
scripts/acceptance/tui_evidence_release.sh create-draft --tag "$tag" --source-sha "$source_sha" --harness-sha "$source_sha" --harness-script-sha256 "$harness_script_sha" --bootstrap-sha "$bootstrap_sha" --bootstrap-blob "$bootstrap_blob" --output docs/evidence/tui-renderer/source.json
scripts/acceptance/tui_evidence_release.sh upload-draft --release-id "$(jq -r .release_id docs/evidence/tui-renderer/source.json)" --inventory docs/evidence/tui-renderer/automated/inventory.json --asset-dir "$automated_asset_dir"
mise exec -- mix swarm_code.tui.evidence --check docs/evidence/tui-renderer/automated
```

Expected: the release remains both draft and prerelease. Automated records bind source/harness/script/bootstrap identities and draft asset digests; nothing calls publish.

- [ ] **Step 3: Commit automated records and common source identity**

```bash
git add docs/evidence/tui-renderer/source.json docs/evidence/tui-renderer/automated
git commit -m "docs: record automated renderer evidence"
```

---

### Task 27: Collect Exact-Commit Manual Observations and Publish Evidence Once

**Files:**
- Create after observation: `docs/evidence/tui-renderer/manual/*.json`
- Create after observation: `docs/evidence/tui-renderer/manual/*.json.sig`
- Create before publication: `docs/evidence/tui-renderer/release-inventory.json`
- Create after immutable publication: `docs/evidence/tui-renderer/macos-arm64.json`
- Create after immutable publication: `docs/evidence/tui-renderer/macos-x86_64.json`
- Create after immutable publication: `docs/evidence/tui-renderer/ubuntu-22.04-arm64.json`
- Create after immutable publication: `docs/evidence/tui-renderer/ubuntu-22.04-x86_64.json`

**Interfaces:**
- Consumes the exact already-pushed `source_sha == harness_sha` recorded by Task 26 and the still-draft evidence prerelease.
- Produces signed observations bound to that commit/script plus immutable permanent asset references, or truthful incomplete evidence.

- Run only GUI/session/operator lanes recorded complete in Task 1. Each operator uses a clean detached checkout of the exact pushed source commit, verifies `tui_terminal_matrix.sh` against the recorded digest, runs every assigned emulator/context, generates unsigned canonical records, and signs outside the agent workflow using `ssh-keygen -Y sign -n swarm-code-tui-evidence`. No workflow asks for, opens, or stores an operator private key.
- Validator checks allowed public signer, namespace, target/source/harness commit, script digest, emulator/context, raw asset digest, UTC observation window, and every required fact. A signature proves provenance, not a passing result.
- Publication order is closed: keep/create the draft evidence-only prerelease; upload **every** automated/manual/raw/manifests/attestation asset; compare complete expected inventory names/sizes/SHA-256 while still draft; publish exactly once; assert repository policy `.enabled == true` and release `.immutable == true`; re-download every asset from its permanent URL and verify its digest; never append afterward. Missing policy, immutable status, lane, signature, or permanent asset leaves the renderer evidence incomplete and cannot be called durable.

- [ ] **Step 1: Run and sign every assigned lane from the exact pushed harness commit**

```bash
source_sha=$(jq -r .source_sha docs/evidence/tui-renderer/source.json)
harness_sha=$(jq -r .harness_sha docs/evidence/tui-renderer/source.json)
test "$source_sha" = "$harness_sha"
git fetch origin feature/tui-interaction-spike
git cat-file -e "$source_sha^{commit}"
operator_dir=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-operator.XXXXXX")
git worktree add --detach "$operator_dir" "$source_sha"
test -z "$(git -C "$operator_dir" status --short)"
script_sha=$(shasum -a 256 "$operator_dir/scripts/acceptance/tui_terminal_matrix.sh" | awk '{print $1}')
test "$script_sha" = "$(jq -r .harness_script_sha256 docs/evidence/tui-renderer/source.json)"
manual_asset_dir="${TMPDIR:-/tmp}/swarm-tui-manual-assets-$source_sha"
mkdir "$manual_asset_dir"
```

On each assigned operator host, run the exact matrix/record interfaces from Task 25 with these three identities, then sign each canonical record externally:

```bash
ssh-keygen -Y sign -f "$OPERATOR_SIGNING_KEY" -n swarm-code-tui-evidence RECORD.json
```

Expected: complete signed matrix or truthful incomplete/fail; no observation names a different source/harness/script.

- [ ] **Step 2: Validate every record and assemble the exact pre-publication inventory**

```bash
mise exec -- elixir scripts/acceptance/tui_infrastructure_validate.exs docs/evidence/tui-renderer/repository-policy.json docs/evidence/tui-renderer/infrastructure.json docs/evidence/tui-renderer/manual-operators.json
for record in docs/evidence/tui-renderer/manual/*.json; do scripts/acceptance/tui_manual_evidence_verify.sh "$record" "$record.sig" governance/tui-evidence-allowed-signers; done
mise exec -- mix swarm_code.tui.evidence --check docs/evidence/tui-renderer
mise exec -- mix swarm_code.tui.evidence --ready-to-seal docs/evidence/tui-renderer
```

`--ready-to-seal` requires every automated/manual lane, raw asset, manifest, attestation, identity, signature, source/script digest, and factual gate to be present and valid. If it exits nonzero, keep the prerelease draft, record renderer evidence `incomplete`, skip publication, and continue only to Task 28's incomplete decision.

Collect operator raw outputs, canonical records, signatures, and external attestations into the exact `manual_asset_dir`, then build/stage the complete inventory:

```bash
source_sha=$(jq -r .source_sha docs/evidence/tui-renderer/source.json)
manual_asset_dir="${TMPDIR:-/tmp}/swarm-tui-manual-assets-$source_sha"
seal_asset_dir="${TMPDIR:-/tmp}/swarm-tui-evidence-stage-$source_sha"
mkdir "$seal_asset_dir"
mise exec -- elixir scripts/acceptance/tui_evidence_inventory.exs docs/evidence/tui-renderer/source.json docs/evidence/tui-renderer/automated/inventory.json "$manual_asset_dir" docs/evidence/tui-renderer/release-inventory.json "$seal_asset_dir"
```

The builder combines already-uploaded automated inventory with every manual/raw/identity/dependency/SBOM/license/attestation file, recording exact name, size, and SHA-256. It stages every not-yet-uploaded asset and the inventory itself, rejects duplicate/unexpected names, and requires the closed expected target/lane/type set.

- [ ] **Step 3: Upload the remainder, publish once, prove immutability, and re-download all assets**

```bash
release_id=$(jq -r .release_id docs/evidence/tui-renderer/source.json)
source_sha=$(jq -r .source_sha docs/evidence/tui-renderer/source.json)
seal_asset_dir="${TMPDIR:-/tmp}/swarm-tui-evidence-stage-$source_sha"
redownload_dir=$(mktemp -d "${TMPDIR:-/tmp}/swarm-tui-evidence-redownload.XXXXXX")
scripts/acceptance/tui_evidence_release.sh upload-draft --release-id "$release_id" --inventory docs/evidence/tui-renderer/release-inventory.json --asset-dir "$seal_asset_dir"
scripts/acceptance/tui_evidence_release.sh seal --release-id "$release_id" --inventory docs/evidence/tui-renderer/release-inventory.json --download-dir "$redownload_dir"
test "$(gh api -H 'X-GitHub-Api-Version: 2026-03-10' repos/zaalipro/swarm-code-cli/immutable-releases --jq .enabled)" = true
test "$(gh api "repos/zaalipro/swarm-code-cli/releases/$release_id" --jq .immutable)" = true
```

Expected: all expected assets existed before the single publish transition and every permanent re-download matches. If any assertion fails, write aggregate status `incomplete`, do not claim durable evidence, and do not attempt a post-publication repair upload.

- [ ] **Step 4: Generate permanent aggregates, validate, and commit**

```bash
mise exec -- mix swarm_code.tui.evidence --check docs/evidence/tui-renderer
git add docs/evidence/tui-renderer
git commit -m "test: seal terminal emulator evidence"
```

Expected: target aggregates use only permanent immutable URLs/digests, all source identities match, or they explicitly remain incomplete.

---

### Task 28: Record the Objective ExRatatui Go/No-Go Decision and Finish the Spike

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

## Explicit Deferred Enhancement Ledger

These are deliberately outside the renderer spike and do not create inert controls in its Scene:

1. Carbon light and Obsidian/Graphite/Aurora mappings wait for a separate theme-parity plan after the Carbon dark role catalogue and monochrome focus contrast pass.
2. Optional mouse hit-testing/drag resize, terminal images, OSC 8 links, and opt-in OSC 52 wait for bounded capability/security specs with identical keyboard and plain routes. This spike keeps mouse off by default and clipboard capability-gated.
3. Bounded syntax highlighting, richer Markdown semantics, `$EDITOR` handoff with hash-conflict return, and process-crash draft persistence each require separate ownership/security/durability specs; none is represented as working here.
4. The Phase 3-5 workflow, research, schedule, settings, MCP, storage, usage, administration, and public-distribution matrices remain governed by contract sections 18 and 21. Representative blocks remain explicitly static rather than faking those interactions.

## Final Objective Acceptance

The plan is complete only when all of these statements have direct evidence:

1. Neutral Scene/Input/Action/Reducer/Effect/DataSource contracts compile without renderer/daemon leakage and express Back, layout/composer adjustment, transient FieldKey editing, pending settlement, resize help, and honest plain handoff.
2. SafeText and Unicode-width 0.2.2 pass the adversarial corpus; the one narrow/wide capability flows through editor, projector, Scene, capture, goldens, and PTY cursor evidence, including logical-order RTL caret/selection cases.
3. The two-phase DataSource/runtime/terminal binding starts in the specified order, emits no initial effect before both acknowledgements, and rolls back every partial failure without a circular constructor dependency.
4. Snapshot-before-delta, bounded pre-ready buffering, contiguous sequences, resync, page-edge deduplication, loading/error/retry/closed sentinels, off-window versus removed focus/anchor repair, and detach/reconnect pass without sleeps.
5. The deterministic three-run script preserves drafts, transient-field isolation, cursor/selection/focus/modal/layout, Main/Inspector anchors, unseen IDs, mutation ordering, and Q1's one revision-7 settlement.
6. Responsive projection passes every breakpoint with deterministic density/elision, the exact Carbon role/status map, both Medium drawers, constrained sticky/scrolling overlays, Activity return context/overflow, complete focus graphs, and no hidden small-screen send/destructive action.
7. Plain mode is an owned serialized append-only/control-free fake interaction with scoped prompt revisions, async prompt re-emission, stale/ambiguous input recovery, exact stdout/stderr ordering, and EOF/Ctrl+C detach. It is the screen-reader acceptance target; accessibility remains unproven until VoiceOver/Orca run. No-alt preserves prior scrollback/final frame but not redraw history.
8. Exactly 87 committed risk-selected frames compare every cell/style/continuation plus cursor/focus/action IDs and enforce semantic intent tags for monochrome/ASCII/reduced-motion/constrained/pending/recovery states.
9. ExRatatui references and NIF resources remain inside its exact adapter; neutral editor/reducer state never uses renderer textarea state.
10. Normal/error/INT/TERM and non-recursive SIGUSR1/TSTP/CONT PTY restoration passes 1,000 target cycles with exact child/launcher stop/resume order and honest SIGKILL recovery.
11. Ordered pre/post release hooks embed renderer identity before assembly and derive dependency hashes from final bytes; separate build and fresh runtime HOME/XDG trees prove packaged fake execution writes no runtime user state.
12. Native safety/input/performance/soak/link/glibc results exist for all four targets at the one pushed source/harness commit. Manual records bind the same commit and script digest.
13. Evidence assets are complete while draft, published once under enabled immutable-release policy, reported `immutable: true`, and re-downloaded from permanent URLs with matching digests; otherwise status is incomplete, not durable.
14. The decision is mechanically adopt/reject/incomplete with three-of-four never accepted, and README/ADR retain the fake/no-user-data/no-FoundationGate/Repo/IPC/no-installability boundary.

After this spike, a separate plan may implement the chosen renderer fallback if rejected. A real IPC workspace remains blocked on all daemon prerequisites in interaction-contract section 20 and must receive its own design/plan.
