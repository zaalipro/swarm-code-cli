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

apps/swarm_code_cli/lib/swarm_code_cli/ui/{session_runtime,effect_runner,terminal_owner,signal_relay,ui_supervisor}.ex
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

### Task 1: Make the Root Precommit Command Use the Test Environment

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

### Task 2: Establish Renderer-Neutral Types and Architecture Guards

**Files:**
- Modify: `apps/swarm_code_cli/mix.exs`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/size.ex`
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
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/contracts_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs`
- Create: `apps/swarm_code_cli/test/support/contract_fixtures.ex`

**Interfaces:**
- Produces the exact neutral contracts from spec sections 4-9:

```elixir
%SwarmCodeCLI.UI.Size{columns: pos_integer(), rows: pos_integer()}

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
        | :suspend
        | :continue

@type SwarmCodeCLI.UI.Action.t() ::
        :boot
        | {:resize, Size.t()}
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
        | {:announce, SafeText.t()}
        | {:bell, :needs_you}
        | {:clipboard_write, ClipboardPayload.t()}
        | {:detach, non_neg_integer()}

SwarmCodeCLI.UI.Renderer.init(Renderer.Options.t()) ::
  {:ok, term(), SwarmCodeCLI.UI.Capabilities.t()} | {:error, Renderer.Error.t()}

SwarmCodeCLI.UI.Renderer.normalize_event(term(), term()) ::
  {:ok, Input.t(), term()} | {:ignore, term()} | {:error, Renderer.Error.t(), term()}

SwarmCodeCLI.UI.Renderer.draw(Scene.t(), term()) ::
  {:ok, term()} | {:error, Renderer.Error.t(), term()}

SwarmCodeCLI.UI.Renderer.shutdown(term()) :: :ok
```

- `Scene.Block.t/0` is an exhaustive union of `%Text{}`, `%RichText{}`, `%Markdown{}`, `%Code{}`, `%VirtualList{}`, `%RunCard{}`, `%AgentList{}`, `%ConsensusLedger{}`, `%ResearchDocument{}`, `%Progress{}`, `%Tabs{}`, `%KeyValues{}`, `%Composer{}`, `%Notice{}`, and `%ActionDeck{}`. Each block carries stable binary IDs, closed style roles, `SafeText`, bounded integers, and opaque action IDs only.
- `Input.key_code/0` is `:enter | :escape | :tab | :back_tab | :backspace | :delete | :insert | :up | :down | :left | :right | :home | :end | :page_up | :page_down | {:function, 1..12}`. Modifiers are only `:shift | :control | :alt | :super | :hyper | :meta`; mouse kinds/buttons are the closed values in interaction-contract section 6. Because exact ExRatatui local events expose a Unicode scalar rather than a complete extended grapheme, textual keys normalize honestly to `{:text_fragment, kind, valid_utf8_fragment, modifiers}`. The editor resegments after every inserted fragment and keeps cursor/selection in grapheme units. Neutral composition actions let a future adapter block Enter while IME composition is active; ExRatatui 0.13.0 cannot emit them and must report that capability unavailable rather than claiming it observed IME lifecycle.
- `Projector` will later return `{Scene.t(), %{required(binary()) => Action.t()}}`; no Scene value contains the semantic action table.
- This task creates the referenced contract structs (`LayerSpec`, `Destination`, `DraftKey`, `Editor.Operation`, `ScrollOperation`, `ClipboardPayload`, `Watch`, `Request`, `Delivery`, and `AdmissionError`) with their closed types and structural validation. Later tasks add behavior to these same types rather than temporarily using `term()` or untyped maps.
- Adds `{:stream_data, "== 1.4.0", only: :test, runtime: false}` and `elixirc_paths/1` for `test/support`; no renderer dependency is added in this task.

- [ ] **Step 1: Write failing contract and source-boundary tests**

Use tests with these assertions:

```elixir
test "scene and action identifiers are binary and renderer neutral" do
  scene = ContractFixtures.minimal_scene()
  assert :ok = Scene.validate(scene)
  assert %{"open-help" => {:open_layer, %LayerSpec{kind: :help}}} =
           ContractFixtures.action_table()
  refute contains_forbidden_struct?(scene)
end

test "only the exact renderer adapter directory may mention renderer implementation types" do
  root = Path.expand("../../../lib", __DIR__)

  offenders =
    root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, "/ui/renderer/ex_ratatui_013/"))
    |> Enum.filter(fn path ->
      source = File.read!(path)
      Enum.any?(["ExRatatui", "Ratatui", "Rustler", "ResourceArc"], &String.contains?(source, &1))
    end)

  assert offenders == []
end

test "CLI has no daemon, persistence, or IPC implementation dependency" do
  mix_source = File.read!(Path.expand("../../../mix.exs", __DIR__))
  refute mix_source =~ "swarm_code_daemon"

  cli_source =
    Path.expand("../../../lib/**/*.ex", __DIR__)
    |> Path.wildcard()
    |> Enum.map_join("\n", &File.read!/1)

  Enum.each(["FoundationGate", "Ecto.Repo", "DATABASE_PATH", "UnixSocket", "Migrations"], fn banned ->
    refute cli_source =~ banned
  end)
end
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/contracts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs
```

Expected: FAIL because neutral contracts and fixtures do not exist.

- [ ] **Step 3: Add the closed types and validators**

Define `@enforce_keys` for required struct fields. `Scene.validate/1` must recursively reject raw binaries in text positions, functions, PIDs, ports, references, unknown block structs, unknown style atoms, negative rectangles, duplicate region IDs, duplicate action IDs, and regions outside the Scene size. It returns only `:ok` or `%Renderer.Error{code: closed_atom, message: static_binary}`.

Define key codes and modifiers with compile-time unions. Character input is `{:grapheme, binary()}` rather than a runtime atom. Define all renderer errors through clauses such as:

```elixir
def new(:invalid_scene), do: %__MODULE__{code: :invalid_scene, message: "invalid renderer-neutral scene"}
def new(:unknown_input), do: %__MODULE__{code: :unknown_input, message: "unsupported terminal input"}
def new(:input_too_large), do: %__MODULE__{code: :input_too_large, message: "terminal input exceeds the configured bound"}
def new(:renderer_failed), do: %__MODULE__{code: :renderer_failed, message: "terminal renderer failed"}
```

- [ ] **Step 4: Run GREEN and the existing CLI suite**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/contracts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs
mise exec -- mix test apps/swarm_code_cli/test
```

Expected: PASS; the locked dependency graph still contains no TUI renderer.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli
git commit -m "feat: define renderer-neutral UI contracts"
```

---

### Task 3: Make Safe Text, Unicode wcwidth, Capabilities, and Theme Deterministic

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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text/limits.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities/probe.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/theme.ex`
- Create: `scripts/dev/sync_unicode_width.exs`
- Create: `apps/swarm_code_cli/test/fixtures/safe_text/adversarial.json`
- Create: `apps/swarm_code_cli/test/fixtures/unicode_width/vectors.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/width_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs`

**Interfaces:**

```elixir
SafeText.chrome(chrome_key()) :: SafeText.t()
SafeText.number(non_neg_integer()) :: SafeText.t()
SafeText.external(binary(), SafeText.Limits.t()) :: {:ok, SafeText.t()} | {:error, :input_too_large | :escaped_output_too_large}
SafeText.concat([SafeText.t()]) :: SafeText.t()
SafeText.value(SafeText.t()) :: binary()
SafeText.lines(SafeText.t()) :: [binary()]

Width.cells(binary(), :narrow | :wide) :: non_neg_integer()
Width.graphemes(binary()) :: [binary()]
Width.take_cells(binary(), non_neg_integer(), :narrow | :wide) :: {binary(), binary(), non_neg_integer()}
Width.wrap(binary(), pos_integer(), :narrow | :wide) :: [binary()]

Capabilities.from_probe(Capabilities.Probe.t()) :: Capabilities.t()
Theme.style(style_role(), Capabilities.t()) :: Scene.Style.t()
```

- `SafeText.Limits` defaults to 65,536 input bytes, 262,144 escaped-output bytes, and tab stops every eight cells. Callers must supply a smaller field bound where a DTO defines one.
- External sanitization preserves LF as the only control separator and expands tabs to the next eight-cell stop. It replaces invalid UTF-8 with `�`; maps C0/C1, CR, BS, DEL, ESC, CSI, OSC, DCS, APC, and PM introducers to fixed visible `⟦NAME⟧` tokens; names bidi controls such as `⟦RLO U+202E⟧`; and names standalone zero-width deception such as `⟦ZWSP U+200B⟧`. Valid combining graphemes, emoji ZWJ sequences, and VS15/VS16 sequences remain intact.
- `Width.Table` is a faithful generated Elixir wcwidth representation of `unicode-width` 0.2.2's `WidthInfo` state machine and lookup tables. `sync_unicode_width.exs --check` verifies the crate/source hashes, regenerates `table.ex` and `vectors.json` deterministically, and fails on drift. It never downloads at compile time or runtime.
- `Capabilities` fixes color modes to `:truecolor | :ansi256 | :ansi16 | :monochrome`, ASCII/reduced-motion/TTY booleans, `Size`, and feature states `:supported | :best_effort | :unavailable` for enhanced keys, focus, paste, mouse, clipboard, and alternate screen. A separate `paste_preallocation_bound?` is false unless target evidence proves it. Precedence is explicit flag/`NO_COLOR` → monochrome, then truecolor, 256, 16; non-TTY or `TERM=dumb` selects plain later. ExRatatui 0.13.0 does not auto-detect color depth, Unicode font coverage, focus forwarding, paste safety, tmux forwarding, or screen readers, so inferred capabilities remain `:best_effort` until a target probe promotes them.
- Carbon truecolor values are fixed: background `#141414`, surface `#191919`, raised `#1e1e1e`, border `#2a2a2a`, text `#f3f2f0`, muted `#8c8b88`, accent `#ff6a1a`, success `#42be65`, warning `#f1c21b`, error `#fa4d56`, and info `#4589ff`. 256-color indices are `233, 234, 235, 236, 255, 245, 202, 42, 220, 203, 33`. ANSI-16 and monochrome retain state words and focus through fixed modifiers.

- [ ] **Step 1: Write adversarial and complete-width RED tests**

Include these direct cases and load every committed upstream vector:

```elixir
test "external terminal and bidi controls become inert visible text" do
  bytes = "ok\e]0;owned\a\rFAIL\b\u202Etxt\u202C\u200B"
  assert {:ok, safe} = SafeText.external(bytes, Limits.default())
  assert SafeText.value(safe) ==
           "ok⟦ESC⟧]0;owned⟦BEL⟧⟦CR⟧FAIL⟦BS⟧⟦RLO U+202E⟧txt⟦PDF U+202C⟧⟦ZWSP U+200B⟧"
  refute SafeText.value(safe) =~ <<0x1B>>
end

test "valid graphemes survive and use unicode-width 0.2.2 cells" do
  values = [{"é", 1}, {"é", 1}, {"ქართული", 8}, {"中", 2}, {"👩🏽‍🚒", 2}, {"🇬🇪", 2}, {"✈️", 2}]
  Enum.each(values, fn {text, cells} -> assert Width.cells(text, :narrow) == cells end)
end

test "expansion is rejected before exceeding its configured allocation" do
  limits = %Limits{input_bytes: 8, escaped_output_bytes: 12, tab_width: 8}
  assert {:error, :input_too_large} = SafeText.external(:binary.copy("a", 9), limits)
  assert {:error, :escaped_output_too_large} = SafeText.external(<<0, 0, 0>>, limits)
end
```

Also prove no adversarial fixture leaves ESC, C0/C1 other than LF, CR, BS, or bidi controls in the `SafeText.value/1` result. Property tests generate arbitrary binaries no larger than 4,096 bytes and assert output bounds without crashing.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/width_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs
```

Expected: FAIL because text, width, capability, and theme modules do not exist.

- [ ] **Step 3: Vendor, attest, and port the exact width source**

Fetch only while implementing this task, verify SHA-256 before extraction, and commit the listed licensed inputs:

```bash
curl -A 'SwarmCodeCLI-width-sync/1' -fsSLo "$TMPDIR/unicode-width-0.2.2.crate" \
  https://static.crates.io/crates/unicode-width/unicode-width-0.2.2.crate
printf '%s  %s\n' b4ac048d71ede7ee76d585517add45da530660ef4390e49b098733c6e897f254 \
  "$TMPDIR/unicode-width-0.2.2.crate" | shasum -a 256 -c -
```

`UPSTREAM.json` records version, crate checksum, commit, Unicode version, source paths, licenses, and the generator output hashes. Port both narrow and CJK/ambiguous state transitions, including emoji presentation, modifiers, flags, keycaps, tag sequences, ZWJ ligatures, combining characters, and variation selectors. `Width.take_cells/3` and `wrap/3` iterate extended graphemes and never split a grapheme or return a prefix wider than its limit.

- [ ] **Step 4: Implement the bounded streaming sanitizer and pure feature policy**

Check `byte_size(input)` before decoding. Decode one scalar/invalid byte and append iodata while tracking the prospective encoded byte count; return an error before adding an over-limit token. Validate ZWJ/variation selectors within the current extended grapheme before retaining them. `SafeText.chrome/1` consists only of exhaustive clauses for fixed UI labels and glyph variants.

Build capabilities only from `%Capabilities.Probe{}` data; no pure module reads environment or TTY state. Build theme mappings with exhaustive clauses for every style role × color mode, plus ASCII glyph clauses and reduced-motion static state glyphs.

- [ ] **Step 5: Verify generation and GREEN**

```bash
mise exec -- elixir scripts/dev/sync_unicode_width.exs --check
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/width_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs
```

Expected: PASS against every upstream vector and the complete interaction-contract Unicode/adversarial corpus.

- [ ] **Step 6: Commit**

```bash
git add NOTICE third_party apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test scripts/dev/sync_unicode_width.exs
git commit -m "feat: sanitize and measure terminal text exactly"
```

---

### Task 4: Implement Typed Fake Watches, Deltas, Gaps, and Resynchronization

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/watch.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/request.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/delivery.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/admission_error.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/data_bridge.ex`
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
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/fake.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/fake/script.ex`
- Create: `apps/swarm_code_cli/test/fixtures/fake/three_run_script.json`
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

Fake.Source.start_link(script: Fake.Script.t(), source_epoch: binary()) :: GenServer.on_start()
Fake.Source.advance(server(), binary()) :: :ok | {:error, :unknown_barrier}
Fake.Source.snapshot(server()) :: Fake.Script.snapshot()

DataBridge.normalize({:swarm_code_ui_data, binary(), Delivery.t()}, expected_epoch :: binary() | nil) ::
  {:ok, {:data, Delivery.t()}} | {:ignore, :stale_epoch} | {:error, :invalid_delivery}
```

- `Watch` has `watch_ref`, closed slot `:shell | :workspace | :inspector | :activity`, typed `SwarmCode.Protocol.Scope`, generation, positive page size at most 200, and byte limit at most 1,048,576.
- `Request` has binary request ID, closed kind, scope, generation, origin, absolute integer deadline, and expected response type. Initial kinds are the seven spec queries, `{:resync_watch, watch_ref}`, dispatcher launch, lifecycle control, steer, answer question, resolve approval, and mark seen.
- `Delivery` fields match spec section 10 exactly. Its body is the closed DTO/delta/outcome union; arbitrary maps are rejected before delivery.
- `Fake.Source` is the fake daemon analogue and outlives a client adapter. Each `Fake` adapter owns only its watches, bounded pre-ready buffers, requests, timers, and monitor. Limits are 128 buffered events and 1,048,576 encoded bytes per watch; overflow emits one `:resyncing`/snapshot-required transition rather than dropping canonical source state.
- The script uses fixed UUIDs and clock `2_025_09_03T12:00:00Z`; barriers are binary IDs. `advance/2` returns only after that barrier's deliveries have been placed in subscribed client mailboxes, so tests need no sleeps.

- [ ] **Step 1: Write the behavior-conformance RED tests**

Cover ready-before-delta, exact `through_sequence`, strict contiguous delivery, pre-ready buffer ordering, count/byte overflow, duplicate rejection, explicit gap, source-epoch replacement, unwatch, request cancellation, client close, and a new client snapshot from the continuing source.

The core gap assertion is:

```elixir
assert :ok = Fake.Source.advance(source, "workspace-a-gap")
assert_receive {:swarm_code_ui_data, ^epoch, %Delivery{kind: :delta, sequence: 8}}
assert :ok = DataSource.query(client, FakeFixtures.resync_request("watch-a"))
assert_receive {:swarm_code_ui_data, ^epoch, %Delivery{kind: :resyncing, body: %Connection{state: :snapshot_required}}}
assert_receive {:swarm_code_ui_data, ^epoch, %Delivery{kind: :watch_ready, body: %WorkspaceSnapshot{through_sequence: 9}}}
```

Assert closing the client yields exactly one `:closed` delivery, empties source subscriber state after a deterministic monitor barrier, and leaves `Fake.Source.snapshot(source).runs` unchanged.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/conformance_test.exs
```

Expected: FAIL because the typed DataSource and fake source do not exist.

- [ ] **Step 3: Implement the bounded fake source and client adapter**

Validate the committed JSON fixture with existing bounded `SwarmCode.Protocol.JsonLimits` before converting closed string values through clause tables. Do not call `String.to_atom/1`, `binary_to_atom/1`, or decode arbitrary operation names.

Implement source-side canonical state first, then per-client delivery. On client watch admission, register the watch, establish its starting sequence, build a page-limited snapshot, and emit `watch_ready`; deltas become visible only after readiness. A scripted gap or `snapshot_required` delivery remains visible to the reducer so it can emit exactly one resync request; handling that typed request retains source state, emits `resyncing`, replaces the client buffer, then emits a new ready snapshot with the current `through_sequence`. Pre-ready buffer overflow is detected inside the adapter because no delta is yet visible; it performs the same resync transition once.

- [ ] **Step 4: Run GREEN with multiple deterministic seeds**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/conformance_test.exs --seed 0
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/fake_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/conformance_test.exs --seed 4901
```

Expected: PASS with no sleep, mailbox polling, leaked monitor, or unbounded buffer.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source.ex apps/swarm_code_cli/test
git commit -m "feat: add deterministic fake UI data source"
```

---

### Task 5: Build the Grapheme Editor and Process-Local Draft Store

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/buffer.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/operation.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/selection.ex`
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

DraftKey.t() :: {binary(), :main | {:thread, binary()} | {:edit, binary()}}
Draft.new(DraftKey.t(), Editor.t()) :: Draft.t()
Drafts.fetch(Drafts.t(), DraftKey.t()) :: Draft.t()
Drafts.put(Drafts.t(), Draft.t()) :: Drafts.t()
Drafts.clear_origin(Drafts.t(), DraftKey.t(), binary()) :: Drafts.t()
```

- `Editor.Buffer` is a two-sided grapheme zipper. Insert/paste splits once, prepends/reverses bounded chunks, and does not append repeatedly to a growing binary. Cursor and selection are grapheme indices; vertical movement retains preferred display cell using `Width`.
- Operations are insert/resegment text fragment, one bounded paste, composition start/update/end, delete backward/forward, left/right/up/down/home/end movement, selection extension, select all, undo, redo, and explicit newline. Paste never produces an activate/send action. Composition text remains editor-local until committed and Enter cannot activate send while composition state is active.
- Default editor text bound is 262,144 bytes. Undo is bounded to 100 records and 1,048,576 bytes; eviction drops only derived undo history, never current text.
- `Draft` carries exact editor state, vertical/horizontal editor scroll, Reply/Steer/Revise/command/goal/research chip state, attachment metadata references only, validation state, and height clamped to 1-8 rows.
- A clear operation requires both the exact draft key and originating request ID. It cannot clear a currently newer submission or any other conversation draft.

- [ ] **Step 1: Write Unicode editing and draft-isolation RED tests**

Exercise composed/decomposed accents, Georgian, Arabic/Hebrew, CJK, ambiguous width, skin tones, flags, family/occupation ZWJ sequences, VS15/VS16, multiline vertical movement, selection replacement, 100 repeated paste events, undo eviction, navigation fetch/restore, and per-origin clearing.

```elixir
test "paste is one grapheme-safe edit and cannot submit" do
  editor = Editor.new(max_bytes: 262_144, undo_bytes: 1_048_576, undo_count: 100)
  assert {:ok, editor} = Editor.apply(editor, {:paste, "ქართული\n👩🏽‍🚒"})
  assert Editor.text(editor) == "ქართული\n👩🏽‍🚒"
  assert Editor.cursor(editor) == 10
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

### Task 6: Implement the Pure Reducer, Generations, and Logical Scroll Anchors

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/state.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/init.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/watch_state.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/read_model.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/chunk_deque.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scroll.ex`
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
  unseen: MapSet.t(binary()),
  before_cursor: binary() | nil,
  after_cursor: binary() | nil
}
```

- `State` owns size/capabilities, source epoch, four closed watch slots, destination/back history, visible and hidden focus, selections, expansions, tabs/filters, drafts, independent Main/Inspector scroll maps, logical layer stack, bounded read model, outstanding requests, dirty revision, and current action/request UUID sequence supplied by `Init`.
- `ChunkDeque` stores stream chunks in prepend-only chunk collections by entity/channel/attempt ID. Reset replaces a failed attempt; projection materializes only the visible item. It enforces the DTO field bound while reading and requests resync/detail instead of dropping bytes.
- Matching requires source epoch, watch reference, scope kind/ID/generation, revision, contiguous sequence, and request reference as applicable. Duplicate/stale events produce byte-for-byte identical state and no effects.
- A first sequence gap marks the slot stale/resyncing and emits one `%Request{kind: {:resync_watch, watch_ref}}`; later gap events while resyncing emit nothing. A replacement ready snapshot installs facts while retaining drafts, focus, selection, modal, layout preference, and logical anchors.
- Navigation increments/freeze-invalidates the old slot generation before emitting `unwatch`; the replacement watch carries the new generation. View queries are canceled; admitted command requests remain correlated offscreen.
- User scrolling detaches immediately; repeated changes to one stable item count once; `:last`/`:follow` rejoins and clears unseen. Main and Inspector are independent; prepending history and resizing preserve stable item/intra-line anchors.

- [ ] **Step 1: Write stale/gap/navigation/scroll RED tests**

Use the exact reducer list in spec section 17.2 through “prepended page and resize anchor preservation.” Include this ordering assertion:

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

### Task 7: Project Responsive Scenes and the Four Representative Surfaces

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

### Task 8: Add the Keymap, Switcher, Activity Center, and Safe Question Modal

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

### Task 9: Own Runtime Effects and Prove the Deterministic Three-Run Scenario

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

- `SessionRuntime` serializes terminal input, DataBridge actions, request settlements, and timer actions. It applies every matching semantic event immediately, updates the Scene/ActionTable, and has at most one current-frame draw timer. Additional semantic updates mark the frame dirty but remain individually present in state.
- `SceneSlot` is a protected, runtime-owned ETS table with one latest already-sanitized Scene keyed by revision and a fixed byte ceiling. SessionRuntime writes it and sends the renderer only `{:draw, revision}`. TerminalOwner reads that exact revision and returns a compact acknowledgment/error, then drops the local Scene value. Whole Scene/draft/transcript values never become a terminal process's retained state or last mailbox message, preventing crash reports from printing visible content. Destroy the table when SessionRuntime stops.
- `SessionRuntime`, `DataSource.Fake`, and `Fake.Source` implement redacted `format_status/1` output containing counts/IDs/status words only; no draft, SafeText value, transcript, reasoning, question body, or Scene appears in Logger crash reports.
- `EffectRunner` dispatches only the closed Effect union. It owns timers under `TimerSupervisor`, forwards typed watch/query/command/cancel to the fake adapter, and reports one settlement action. Clipboard remains disabled in this spike unless an explicit bounded test capability is injected.
- Draw failure becomes a typed safe error and starts orderly terminal/client closure. Client detach cancels UI timers/requests/watches and closes the client DataSource. It emits no run/agent/domain Stop command.
- Test renderer accepts Scene values and sends deterministic draw acknowledgements/errors. It contains no ExRatatui type.

- [ ] **Step 1: Write runtime RED tests**

Assert 100 ordered semantic deltas are all applied while at most one pending paint exists, hidden/reduced-motion states own no animation timer, renderer error settles closure, and all timers/requests/watches disappear under monitored shutdown.

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

Keep the current Scene revision/ActionTable in runtime state. Paint timers carry revision and timer ID; stale timer actions do nothing. On close, increment generations first, cancel timers/requests, unwatch, close the adapter, request renderer shutdown, and acknowledge the caller only after monitored children settle.

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

### Task 10: Add the Permanent Plain, ASCII, No-Color, and Reduced-Motion Surface

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

- Selection is explicit `--plain`, or automatic when stdout is non-TTY or TERM equals `dumb` case-insensitively. `--no-alt-screen` remains an interactive renderer option and does not imply plain. `--ascii`, `--no-color`, present `NO_COLOR`, and `--reduced-motion` are retained in options for both presenters.
- Plain output is chronological and append-only, deduplicated by `{source_epoch, scope kind/id/generation, sequence}`. It uses fixed headings, exact state words, sanitized content, and explicit prompts. It emits no cursor rewriting, alternate-screen bytes, terminal hyperlinks, animation, bell, or terminal controls other than LF record separators.
- Plain commands cover every action exposed by the fake slice: navigate conversations/Activity, inspect run, answer Q1 by number/name, Back, allowed Skip, send, queue, follow, and detach. The same typed answer request and queue intent used by TUI are produced; there is no second domain-command vocabulary.
- ASCII substitutes trusted box/glyph chrome only. No-color/reduced-motion output remains semantically identical. The full-screen TUI is not called screen-reader accessible; plain is the VoiceOver/Orca acceptance surface.

- [ ] **Step 1: Write selection/output/command RED tests**

```elixir
test "non-TTY and TERM dumb always select plain" do
  assert {:ok, %{presenter: :plain}} = Options.select([], %Environment{stdout_tty?: false, term: "xterm", no_color?: false})
  assert {:ok, %{presenter: :plain}} = Options.select([], %Environment{stdout_tty?: true, term: "dumb", no_color?: false})
end

test "plain three-run output is append-only, deduplicated, and control-free" do
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

### Task 11: Pin ExRatatui 0.13.0 and Prove the Isolated Adapter

**Hard gate:** Stop renderer work if a valid bounded input causes a reproducible BEAM crash, abort, non-cancellable NIF hang, input loss, or adapter-boundary leak. Preserve evidence and proceed only to the objective reject decision; do not patch neutral state around a renderer defect.

**Files:**
- Modify: `apps/swarm_code_cli/mix.exs`
- Modify: `mix.lock`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/cell.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/cell_frame.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/state.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/input.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/scene_compiler.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/cell_capture.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/cursor_sequence.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/package_identity.ex`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_input_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/ex_ratatui_013_boundary_test.exs`

**Interfaces:**

```elixir
ExRatatui013.init(%Renderer.Options{backend: {:cells, pos_integer(), pos_integer()}}) ::
  {:ok, ExRatatui013.State.t(), Capabilities.t()} | {:error, Renderer.Error.t()}

ExRatatui013.init(%Renderer.Options{backend: :local}) ::
  {:ok, ExRatatui013.State.t(), Capabilities.t()} | {:error, Renderer.Error.t()}

ExRatatui013.poll_event(ExRatatui013.State.t(), non_neg_integer()) ::
  {:ok, Input.t() | nil, ExRatatui013.State.t()} | {:error, Renderer.Error.t(), ExRatatui013.State.t()}

ExRatatui013.capture(Scene.t(), ExRatatui013.State.t()) ::
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
{:rustler, "== 0.38.0", runtime: false},
{:stream_data, "== 1.4.0", only: :test, runtime: false}
```

- Verify the exact lock entry checksums from Global Constraints and version `0.13.0` in tests.
- Lock and assert `rustler_precompiled` 0.9.0, Rustler 0.38.0, and telemetry 1.4.2. `PackageIdentity.verify!/0` checks application version, Hex lock checksums, tag/source metadata, expected OTP NIF ABI 2.17, and the selected native hash before first renderer init. It treats the Hex package as authoritative and never substitutes the checksum-stale Git tag.
- The headless adapter uses `ExRatatui.CellSession.new/2`, `draw/2`, `take_cells/1`, `resize/3`, and idempotent `close/1`; it does not use CellSession byte-stream input as a proxy for local Crossterm. The pinned local adapter uses `ExRatatui.Native.init_terminal/2`, `ExRatatui.draw/2`, explicit `ExRatatui.poll_event/1`, `ExRatatui.Native.restore_terminal/1`, and `ExRatatui.LocalInput.detach/0`/`reattach/1` inside this exact boundary rather than ExRatatui App/Server, whose poll-error handling and termination restoration are insufficient for this gate. All ExRatatui structs/resources remain in adapter state or locals.
- `SceneCompiler.compile/2` maps the closed Scene exhaustively using only ExRatatui 0.13.0 `Block`, `Clear`, `Paragraph`, rich `Text/Line/Span`, `Tabs`, optional `Scrollbar`, and optional SwarmCode-ticked `Throbber`. It renders virtual lists/run cards/agents/consensus/research/progress as bounded Paragraph/span groups in already resolved rectangles. It does not use ExRatatui TextInput, Textarea, Markdown, CodeBlock, Image, Viewport3D, Focus, Command, subscriptions, SSH/distribution, List/Table, custom widgets, or WidgetList. Composer text, selection, and caret are Paragraph spans from the neutral editor.
- Before constructing any widget, `SceneCompiler` validates schema version, Scene/backend size equality, every rectangle, visible-item/height bounds, palette role, cursor bounds, and SafeText provenance. It catches bridge encoding exceptions and returns a static typed error without logging content. It never calls ExRatatui layout NIFs because Projector already resolved cell rectangles.
- Input normalization maps fixed ExRatatui string codes/modifiers to neutral atoms, printable scalar keys to `{:text_fragment, kind, fragment, modifiers}`, paste to one reducer-facing payload bounded at 262,144 bytes, resize to positive `Size`, focus events, and mouse only when enabled. Exact 0.13.0 emits no composition lifecycle input, so adapter capabilities mark it unavailable and normalizer tests never fabricate support. Unknown/null values return `:ignore`/typed error and never atomize. `poll_event/2` treats every ExRatatui `{:error, reason}` as terminal failure; it never ignores and rearms after a poll error. CellSession raw-byte parsing is not used as local-input evidence because it omits mouse/focus and scalarizes bracketed paste; those structs are injected directly in headless normalizer tests, while real local Crossterm input is tested through PTY.
- `CellCapture` maps the ExRatatui snapshot immediately into `CellFrame`; it derives wide-cell continuation markers with `Width`, includes Scene cursor/focus/action metadata, and releases every ExRatatui struct before returning. This compensates for `CellSession.Cell` not explicitly marking a wide trailing cell while testing the exact visual result.
- `CursorSequence.encode/1` accepts only a validated neutral cursor and returns fixed CSI hide or one-based row/column position-plus-show iodata. It is emitted only after a successful local draw. No arbitrary string enters control output. The theme sets no underline color because CellSession cannot expose it.
- ExRatatui adapter state derives a redacted Inspect representation that omits terminal references, input handles, widgets, and native resources; terminal errors are mapped to static codes before logging and never interpolate ExRatatui error terms that may contain Scene data.

- [ ] **Step 1: Write dependency, adapter, input, and boundary RED tests**

Assert exact package/lock checksums, source/tag identity, absence of packaged `erl_crash.dump`, all four representative scenes draw through CellSession, all event variants normalize, 10,000 injected normalized key events have no loss/duplicate, 100 constructed bracketed-paste events each arrive once, resize preserves neutral editor state, every physical cursor control sequence is fixed/coordinate-bounded, and idempotent shutdown releases the CellSession. Record the post-decode paste cap as defense in depth; do not mark the native preallocation-bound dimension passed here.

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

### Task 12: Commit the Complete Exact Cell, Style, Cursor, Focus, and Action Goldens

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
- Cursor fields in these JSON records are the renderer-neutral semantic cursor because CellSession exposes no physical cursor. The same test invokes `ExRatatui013.CursorSequence.encode/1` and stores its fixed expected bytes in the cursor record; Task 13 must observe those exact bytes on a real PTY after the frame. The matrix fails if semantic, encoded, and PTY-observed positions differ. Colored underline is not used because CellSession omits underline color.
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

### Task 13: Put Local Rendering Under One Terminal Owner and Prove PTY Restoration

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/terminal_owner.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/signal_relay.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/ui_supervisor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/host.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ex_ratatui_013/selector.ex`
- Create: `apps/swarm_code_cli/test/support/pty_harness.ex`
- Create: `scripts/acceptance/tui_pty_driver.py`
- Create: `scripts/acceptance/tui_pty.sh`
- Create: `scripts/acceptance/tui_external_launcher.sh`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs`

**Interfaces:**

```elixir
TerminalOwner.child_spec(runtime: pid(), scene_slot: :ets.tid(), host: module(), options: Renderer.Options.t()) :: Supervisor.child_spec()
TerminalOwner.draw(server(), scene_revision :: non_neg_integer()) :: :ok | {:error, Renderer.Error.t()}
TerminalOwner.shutdown(server()) :: :ok

SignalRelay.start_link(owner: pid(), terminal_owner: pid()) :: GenServer.on_start()
UISupervisor.start_link(fake_source: pid(), presentation: :tui, capabilities: Capabilities.t()) :: Supervisor.on_start()
```

- `TerminalOwner.child_spec/1` starts one `:proc_lib` renderer host PID registered as `SwarmCodeCLI.UI.TerminalOwner`; that exact PID invokes the adapter's native init/draw/poll/restore functions and is the only BEAM process touching raw/cooked mode, cursor visibility, alternate screen, bracketed paste, focus reporting, or mouse reporting. The separately delivered outer launcher is only a post-child restoration safety net. Do not start ExRatatui App/Server beside it.
- `ExRatatui013.Host` acknowledges startup only after capturing and validating baseline `stty -g`, initializing the adapter, and installing a `try/after` finalizer. Its bounded receive/poll loop relays normalized neutral Input to `SessionRuntime`, accepts immutable Scene messages, treats poll/draw errors as terminal failures, and holds no editor/domain/DataSource state. Polling is input-oriented; redraws remain event-driven and reduced motion schedules no animation.
- The finalizer always calls native restore, reattaches BEAM input, emits fixed disable/show/main-screen sequences allowed by the adapter, then restores the exact validated baseline with `/bin/sh -c 'stty "$1" </dev/tty' swarm-code-stty "$baseline"`, after requiring `baseline =~ ~r/^[0-9a-fA-F:]+$/`. Failure of either restore is reported and fails lifecycle evidence. This outer guard specifically catches Darwin `PENDIN` drift observed with ExRatatui 0.13.0 on SIGTERM.
- Initialization failure after each owner-observable transition (`baseline_captured`, `native_initialized`, `input_detached`, `initial_scene_drawn`, `signals_installed`) settles startup and restores completed transitions. The outer finalizer is installed before the monolithic native init call and performs baseline restore even when no terminal reference is returned. If a failure within ExRatatui's monolithic native transition cannot be induced and its post-failure terminal state cannot be proven, the lifecycle dimension is recorded failed and ExRatatui is rejected rather than assumed safe. Callback/draw/poll error restores before surfacing a static safe error. Logs/diagnostics never use TUI stdout.
- `SignalRelay` installs app-level `System.trap_signal/3` handlers for SIGINT, SIGTERM, SIGHUP, SIGTSTP, and SIGCONT. Traps only send tagged messages. SIGINT/TERM/HUP request orderly client close; none emits Stop. TSTP closes/restores the renderer, then a supervised exact `/bin/kill -TSTP <validated-launcher-pid>` Port asks the surviving outer launcher to suspend the job; the launcher's TSTP trap restores, forwards TSTP to the exact child, resets its own disposition, and stops itself. On foreground/SIGCONT the launcher reinstalls its trap and forwards CONT; the BEAM restarts the host, requests the latest Scene revision, and redraws. Trap IDs are removed on every owner shutdown path.
- `UISupervisor` starts the client timer/request supervisor, fake DataSource adapter, SessionRuntime/SceneSlot, and SignalRelay before TerminalOwner. SignalRelay accepts terminal registration only after traps are installed, closing the signal-before-raw race. Shutdown order is TerminalOwner restore, runtime/effect settlement, DataSource close, then signal unregistration; a failure still runs the external launcher guard.
- `tui_pty_driver.py` uses only Python standard library `pty.openpty`, `subprocess.Popen`, `termios`, `fcntl`, `selectors`, and `signal`. The parent retains the slave FD, obtains exact `stty -g` before/after, sets window size, waits for a fixed rendered readiness marker, drives input/signals, and writes a sentinel after exit. It never attaches to the user's controlling TTY.
- `tui_external_launcher.sh` is the production-shaped outer guard used inside the test PTY. It captures/validates `stty -g` before spawning (not `exec`ing) the BEAM child, forwards HUP/INT/TERM/TSTP/CONT to the exact child/process group, preserves its exit status, and in an EXIT trap emits fixed leave-alt/show-cursor/disable-paste/focus/mouse sequences then restores the baseline through `/dev/tty`. The final Mix-release overlay in Task 15 embeds this audited launcher; the guard must survive when the child terminates. If both launcher and child receive SIGKILL, recovery is not claimed.
- PTY output proves final cursor-show, alternate-screen exit when enabled, bracketed-paste disable, focus-report disable, mouse disable, restored main screen, and sentinel order. SIGKILL is documented as unrestorable with `reset`/`stty sane`; it is not counted in the 1,000 restorable cycles.

- [ ] **Step 1: Write owner and PTY RED tests**

The focused ExUnit test starts a host under `start_supervised!/1`, monitors it, injects normal close and draw error, and asserts one terminal owner/one settlement. The PTY driver supports exact modes `normal`, `renderer-error`, `sigint`, `sigterm`, and `sigtstp-sigcont` and outputs one bounded JSON result to its stdout; child/TUI logs go to a separate stderr file.

```elixir
assert %{mode: "sigterm", baseline_stty: same, final_stty: same, sentinel_after_restore: true} =
         PTYHarness.run!("sigterm", cycles: 1)
```

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs
```

Expected: FAIL because terminal ownership and PTY driver do not exist.

- [ ] **Step 3: Implement the single owner, signals, and deterministic PTY driver**

Use monitor acknowledgements for host readiness/restoration; do not infer readiness from process liveness. The custom host surrounds its entire loop with `try/after`, rather than relying on a GenServer `terminate/2` callback. Install SIGTSTP/SIGCONT handling before raw mode. Ctrl+Z resolves to the same explicit suspend request because raw mode delivers it as a key instead of invoking the kernel default. On suspend, stop polling, wait for exact native-plus-stty restoration acknowledgement, then temporarily restore default TSTP and signal the BEAM; on continue, redetect size/capabilities, increment terminal generation, wait for host-ready, and redraw the latest Scene revision. Every failure path cancels signal traps, request/timer children, fake watches, and adapter resources.

- [ ] **Step 4: Run the focused lifecycle matrix GREEN**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_owner_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/terminal_lifecycle_test.exs --seed 0
scripts/acceptance/tui_pty.sh --cycles 5 --modes normal,renderer-error,sigint,sigterm,sigtstp-sigcont
```

Expected: PASS for 25 cycles, exact stty equality, restoration sequences, sentinel, and no live owned child. The full 1,000-cycle target run is Task 15.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli/lib/swarm_code_cli/ui apps/swarm_code_cli/test scripts/acceptance/tui_pty_driver.py scripts/acceptance/tui_pty.sh scripts/acceptance/tui_external_launcher.sh
git commit -m "feat: own and restore the terminal lifecycle"
```

---

### Task 14: Add Fuzz, Unicode, Performance, Windowing, and Resource Gates

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/probe.ex`
- Create: `apps/swarm_code_cli/test/fixtures/renderer/fuzz_corpus.json`
- Create: `apps/swarm_code_cli/test/fixtures/renderer/unicode_input.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/fuzz_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/unicode_input_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/performance_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/resource_test.exs`
- Create: `scripts/acceptance/tui_soak.exs`
- Create: `scripts/acceptance/tui_renderer_sanitizers.sh`
- Create: `rust-toolchain-tui-sanitizer.toml`

**Interfaces:**

```elixir
Renderer.Probe.frame_samples(Scene.t(), pos_integer(), keyword()) :: [non_neg_integer()]
Renderer.Probe.input_samples(pid(), [Input.t()], keyword()) :: [non_neg_integer()]
Renderer.Probe.resource_snapshot(pid()) :: %{heap: non_neg_integer(), mailbox: non_neg_integer(), monitors: non_neg_integer(), timers: non_neg_integer(), native_sessions: non_neg_integer()}
```

- Fuzz/property inputs include malformed/zero/huge rectangles, constraints, block values, action IDs, invalid bytes, incomplete terminal sequences, event bursts, resizes, and bounded paste. Invalid Scene values are rejected before NIF encoding. Valid bounded inputs may return only success or typed error; a crash/abort/hang is a hard rejection.
- Paste tests distinguish `adapter_post_decode_cap` from `native_preallocation_bound`. Drive fragmented, 262,144-byte, one-byte-over, and escalating multi-megabyte bracketed pastes through the real local PTY while recording BEAM/native peak allocation before the adapter receives the event. Exact ExRatatui exposes no preallocation limiter, so this dimension remains failed for 0.13.0 unless contrary evidence proves a bound in the selected exact artifact. A watchdog/OS memory limit prevents the probe from exhausting the host; a post-allocation rejection never counts as a pass.
- Unicode input covers all spec section 16.2 values plus Option/Alt, Shift+Tab, repeat/release, focus, enhanced-key fallback, mouse-off default, and mouse-on keyboard parity. It drives 10,000 normalized key events and 100 repeated paste fixtures with exact hashes.
- IME evidence separately records whether composition start/update/end and Enter suppression are observable. The neutral editor/keymap must pass injected composition actions; ExRatatui target evidence records `unavailable` unless the exact artifact produces them, feeding the objective rejection rule rather than weakening the neutral contract.
- Performance thresholds on recorded pinned hardware are `120x40` frame p95 ≤16 ms, input-to-painted p95 ≤50 ms with three fake streams, idle CPU ≤2 percent of one core, motion capped near 15-30 FPS, and no unconditional redraw in reduced motion.
- The 10,000-message source exposes only the projector's visible window plus two-item overscan. Cache count and bytes remain bounded; eviction recomputes exact cells. Final content hashes match the fake source.
- The 30-minute soak compares post-warmup/post-GC heap, mailbox, ETS, timer, monitor, process, and native-session counts. Growth may vary within a documented fixed jitter band but must not be monotonic across all checkpoints.
- `rust-toolchain-tui-sanitizer.toml` pins `nightly-2026-08-13`, `profile = "minimal"`, and components `rust-src` and `clippy`. `tui_renderer_sanitizers.sh` forces source build using `EX_RATATUI_BUILD=1` and `rustler` 0.38.0, enables AddressSanitizer/LeakSanitizer for the exact Hex native source, runs Cargo tests plus the NIF fuzz corpus under a watchdog, and fails on any sanitizer report. macOS release jobs may use their verified matching precompiled NIF; Ubuntu 22.04 release jobs force a target-native source build so the linked glibc symbol floor is 2.35.

- [ ] **Step 1: Write RED tests for bounds and measurements**

Mark long performance/resource tests `:renderer_gate`; exclude them from ordinary focused test unless `RENDERER_GATE=1`. Ordinary tests still run 1,000 fuzz cases and a 60-second virtual-step resource sequence. Assert the full gate command refuses to pass without a hardware metadata record containing OS, architecture, CPU, terminal, OTP, Elixir, dependency checksums, and source commit.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/fuzz_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/unicode_input_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/performance_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/resource_test.exs
```

Expected: FAIL because renderer probes/corpora do not exist.

- [ ] **Step 3: Implement bounded probes and source sanitizer runner**

Use `System.monotonic_time/0` only in probe/runtime code, never Reducer. Force GC before resource checkpoints and record raw samples plus computed percentiles. Use a watchdog OS process around sanitizer/fuzz runs so a non-cancellable NIF call times out and records rejection rather than hanging CI indefinitely.

- [ ] **Step 4: Run local GREEN gates**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/fuzz_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/unicode_input_test.exs --seed 0
RENDERER_GATE=1 mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/performance_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/renderer/resource_test.exs --seed 0
scripts/acceptance/tui_renderer_sanitizers.sh
```

Expected: PASS on the development target or record an objective renderer rejection. Local performance is diagnostic until Task 15's native target evidence.

- [ ] **Step 5: Commit**

```bash
git add apps/swarm_code_cli scripts/acceptance rust-toolchain-tui-sanitizer.toml
git commit -m "test: gate renderer safety and performance"
```

---

### Task 15: Build the Fake-Only Release and Collect Four Native Target Results

**Files:**
- Modify: `mix.exs`
- Modify: `apps/swarm_code_cli/mix.exs`
- Modify: `NOTICE`
- Modify: `config/runtime.exs`
- Modify: `rel/env.sh.eex`
- Create: `rel/vm.args.eex`
- Create: `rel/overlays/bin/swarm-code-demo`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/application.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/demo/supervisor.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/demo/main.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/demo/finite_script.ex`
- Create: `apps/swarm_code_cli/lib/mix/tasks/swarm_code.tui.evidence.ex`
- Create: `scripts/acceptance/tui_native_inspect.sh`
- Create: `scripts/acceptance/tui_release_smoke.sh`
- Create: `scripts/acceptance/tui_target_gate.sh`
- Create: `scripts/acceptance/tui_terminal_matrix.sh`
- Create: `scripts/acceptance/tui_evidence_validate.exs`
- Create: `scripts/ci/tui_dependency_audit.exs`
- Create: `governance/tui-license-policy.json`
- Create: `.github/workflows/tui-renderer-native.yml`
- Create: `docs/evidence/tui-renderer/README.md`
- Create: `docs/evidence/tui-renderer/sbom.spdx.json`
- Create: `docs/evidence/tui-renderer/third-party-notices.txt`
- Create after each native run: `docs/evidence/tui-renderer/macos-arm64.json`
- Create after each native run: `docs/evidence/tui-renderer/macos-x86_64.json`
- Create after each native run: `docs/evidence/tui-renderer/ubuntu-22.04-arm64.json`
- Create after each native run: `docs/evidence/tui-renderer/ubuntu-22.04-x86_64.json`
- Create: `apps/swarm_code_cli/test/fixtures/evidence/valid-target.json`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/demo/application_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/demo/finite_script_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/release_config_test.exs`
- Create: `apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs`

**Interfaces:**

```elixir
SwarmCodeCLI.Application.start(:normal, []) :: Supervisor.on_start()
SwarmCodeCLI.Demo.Main.start(keyword()) :: Supervisor.on_start()
Mix.Tasks.SwarmCode.Tui.Evidence.run([target(), output_path()] | ["--check" | "--decision", evidence_directory()]) :: :ok
```

- `apps/swarm_code_cli/mix.exs` sets `mod: {SwarmCodeCLI.Application, []}`. Application boot is idle by default. Only the exact closed runtime value `SWARM_CODE_BOOT=fake_demo` starts the fake source/client. Unknown values fail with a static error; no runtime string becomes an atom.
- Root release is named `:swarm_code_tui_spike`, seeds only `swarm_code_core` and `swarm_code_cli`, uses `include_erts: true`, and excludes `swarm_code_daemon`. Required transitive renderer/OTP applications such as ExRatatui, RustlerPrecompiled, telemetry, and OTP `ssh` are inventoried even though no SSH listener/transport is started. `RELEASE_DISTRIBUTION=none`; EPMD/TCP/distributed Erlang stay disabled.
- The overlay command embeds the audited external launcher from Task 13 and accepts only `--plain`, `--no-alt-screen`, `--ascii`, `--no-color`, `--reduced-motion`, `--script complete`, and the five fixed lifecycle fault modes. It exports closed values, spawns the release child without `exec`, forwards signals, waits, performs the final terminal restore, and returns the exact child exit status. `--script complete` advances deterministic barriers through messages, prints/presents final fake state, detaches, and exits without user data.
- Each native target runs exact dependency/architecture tests; 69 goldens; Unicode/input; complete three-run scenario; source sanitizer; 1,000 PTY cycles split 200 per mode; 30-minute soak; terminal/color/ASCII/no-alt/reduced-motion cases; clean offline release boot; and native inspection. The Ubuntu jobs set `EX_RATATUI_BUILD=1` while compiling on the exact 22.04 architecture and record the Rust/C/glibc build provenance; use of the published aarch64 GNU NIF is an automatic failure because it imports GLIBC_2.39 `pidfd_spawnp`/`pidfd_getpid`.
- For NIF ABI 2.17, verify published-asset SHA-256 when selected: macOS arm64 `454b5e7d4f2002837e55d00e8fc8b9eea43fca165b9d6b82ab75d0bd358fc7a4`, macOS x86_64 `5600864b8083a1f61c57831a28ea0dd342ac89abed8c71d51d058c6a672daa2d`, and Linux x86_64 GNU `95a23a060aadc58adea3fefd724dc7bb8ad4aead3152fac0ee62f130fe510320`. The rejected Linux arm64 GNU asset hash is `1eb8f5b52d774c71590451ada25fef6423ff2e0419e09736676ca97df05d5f0c`; Ubuntu arm64 evidence must instead attest its native source-build hash and Cargo.lock.
- `tui_native_inspect.sh` checks every executable and NIF with `file`; macOS uses `otool -L`/`otool -l` and rejects wrong architecture/RPATH; Ubuntu uses `readelf -h/-d/-V`, `objdump -T`, and `ldd`, explicitly searches for `pidfd_spawnp`/`pidfd_getpid`, and rejects any GLIBC symbol above 2.35 or unrecorded runtime library. It verifies the one ExRatatui NIF selected by the adapter, bundled ERTS, no Exqlite/daemon payload, and no first-start download.
- `tui_dependency_audit.exs` reads the locked Hex graph plus ExRatatui's exact Cargo.lock, verifies every package against the closed SPDX/license-choice policy, hashes each license source, and deterministically emits a source-commit-bound SPDX JSON and human notices file. It includes ExRatatui's MIT terms, Mauricio Cassola copyright, the vendored render3d/ratatui-3d revision, the Po Chen syntax-definition MIT terms, and all statically incorporated crates. Unknown/missing/ambiguous license data fails; the script never guesses a license.
- Clean-host smoke uses a native VM/machine without Erlang, Elixir, Rust, compiler, or unrecorded NIF library; network is disabled before first boot. Non-TTY chooses plain without hang. Terminal logs are separate from TUI stdout. `tui_terminal_matrix.sh` records tmux and SSH-launched shells on all targets; Terminal.app, iTerm2, Ghostty, and Kitty on both macOS architectures; and GNOME Terminal and Kitty on both Ubuntu architectures, across truecolor/256/16/monochrome, ASCII, reduced-motion, alternate-screen, and no-alt-screen paths. Overall pass is withheld until every required native observation exists.
- The GitHub workflow uses four native/self-hosted label sets exactly: `[self-hosted, swarm-code, macos-14, arm64]`, `[self-hosted, swarm-code, macos-14, x86_64]`, `[self-hosted, swarm-code, ubuntu-22.04, arm64]`, and `[self-hosted, swarm-code, ubuntu-22.04, x86_64]`. A runner verifies `uname`/OS before doing work. Emulation cannot set result `pass`.
- Each evidence JSON includes schema version, target, native boolean, OS/minimum, architecture, runner/hardware, commit, dirty flag, OTP/Elixir/Rust versions, ExRatatui/package/NIF hashes, unicode-width hash, release hash, package/tag/checksum attestation, crash-dump exclusion, native preallocation paste-bound result, semantic and physical cursor results, exact stty/PENDIN result, every command/status/duration/output hash, latency/resource metrics, PTY counts, sanitizer result, terminal coverage, and overall `pass | fail`. No credentials or environment secrets are included.

- [ ] **Step 1: Write release/evidence RED tests**

Add tests that inspect `Mix.Project.config()[:releases]`, assert bundled ERTS and the exact two seeded applications, inventory required transitive applications, reject daemon/FoundationGate strings from release metadata, execute finite plain mode in a task-owned HOME/XDG root, and validate a fixture evidence document. Assert zero created files under the task-owned HOME/XDG root after fake execution.

- [ ] **Step 2: Run RED**

```bash
mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/demo/application_test.exs apps/swarm_code_cli/test/swarm_code_cli/demo/finite_script_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/release_config_test.exs apps/swarm_code_cli/test/swarm_code_cli/release/evidence_test.exs
```

Expected: FAIL because fake application/release/evidence wiring does not exist.

- [ ] **Step 3: Implement and locally verify the fake-only release**

```bash
mise exec -- elixir scripts/ci/tui_dependency_audit.exs --check
EX_RATATUI_BUILD="${SWARM_LINUX_BUILD_FROM_SOURCE:-0}" MIX_ENV=prod mise exec -- mix release swarm_code_tui_spike --overwrite
scripts/acceptance/tui_native_inspect.sh "$(uname -s)" "$(uname -m)" _build/prod/rel/swarm_code_tui_spike
env -i HOME="$TMPDIR/swarm-home" TERM=dumb PATH=/usr/bin:/bin \
  _build/prod/rel/swarm_code_tui_spike/bin/swarm-code-demo --plain --script complete
```

Expected: release starts with bundled ERTS, visibly says fake/no-user-data, completes the exact script, leaves HOME/XDG empty, and loads no daemon/Exqlite code.

- [ ] **Step 4: Run the target gate on each native runner**

On each matrix target:

```bash
if [ "$(uname -s)" = Linux ]; then
  EX_RATATUI_BUILD=1 MIX_ENV=prod mise exec -- mix deps.compile ex_ratatui --force
fi
scripts/acceptance/tui_target_gate.sh --target "$SWARM_TUI_TARGET" --evidence "$RUNNER_TEMP/$SWARM_TUI_TARGET.json"
mise exec -- elixir scripts/acceptance/tui_evidence_validate.exs "$RUNNER_TEMP/$SWARM_TUI_TARGET.json"
```

Expected: one signed CI artifact containing the release archive, raw bounded logs, hashes, and evidence JSON. A failed command sets overall `fail`; the script never rewrites it to pass.

- [ ] **Step 5: Import and validate all four immutable evidence files**

Download the four artifacts from the same commit, verify GitHub artifact attestations, copy only the secret-free JSON records to `docs/evidence/tui-renderer/`, then run:

```bash
mise exec -- mix swarm_code.tui.evidence --check docs/evidence/tui-renderer
```

Expected: PASS only when all records are schema-valid, native, same commit/dependency hashes, and contain a truthful pass/fail outcome. Missing target data is `incomplete`, never pass.

- [ ] **Step 6: Commit release wiring and evidence**

```bash
git add mix.exs config rel apps/swarm_code_cli NOTICE governance/tui-license-policy.json .github/workflows/tui-renderer-native.yml scripts/acceptance scripts/ci/tui_dependency_audit.exs docs/evidence/tui-renderer
git commit -m "ci: collect four-target TUI renderer evidence"
```

---

### Task 16: Record the Objective ExRatatui Go/No-Go Decision and Finish the Spike

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
