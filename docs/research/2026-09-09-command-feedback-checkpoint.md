# Saved slash-command feedback

The prior goal turn made verification progress: the saved PTY smoke proved that
the previous Page Error was resolved and that the conversation resumed after
restart. This turn changed CLI code and tests; the full parity goal stays active.

## Implemented

- The persisted backend accepts `/goal` as a report, `/rewind` as checkpoint
  navigation, and workflow/research navigation results. It previously rejected
  these dispatcher results as `not_allowed`.
- A closed `Feedback` DTO carries report, navigation, and notice results through
  command outcomes. The codec accepts historical ledger outcomes without the new
  field, while still rejecting unknown fields, invalid kinds, missing nested
  nullable fields, mismatched conversation identities, oversized text, and
  feedback attached to nonaccepted outcomes.
- The TUI renders a scrollable goal report with wrapping, PgUp/PgDn and Home/End.
  A new report resets the prior dialog's scroll position. Mode changes show a
  notice without opening a dialog. Late responses from another conversation
  settle the original request without navigating the active conversation.
- Saved workflow/research slash navigation now travels through the dispatcher,
  so successful commands clear their exact submitted composer draft.
- Goal text is no longer cut to the command-list label limit. The report preview
  remains bounded to 60,000 UTF-8 bytes under the 65,536-byte DTO text limit.
- README startup guidance now distinguishes saved and transient launchers and
  explains the shared-storage desktop shutdown order. The adapted dispatcher's
  destination hash was refreshed without changing its upstream provenance pins.

## Verification

- Regression tests first reproduced backend selection rejections, dropped UI
  feedback, wrong-conversation feedback, truncated long report lines, and saved
  slash commands bypassing the correlated dispatcher.
- Final focused run: daemon persisted backend **16 tests**, CLI feedback/codec/
  library **21 tests**, zero failures (`--seed 424242`).
- A subsequent full repository run remains active in unified exec session15309
  (BEAM PID23509). Core122 passed; daemon was still running without an observed
  assertion failure at checkpoint time. Resume that handle; do not restart it.
- Earlier broad service/client run during this slice: daemon service **62 tests**,
  CLI **580 tests plus 5 properties**, zero failures. Later changes were checked
  with the focused runs above; this is not a full repository final acceptance.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix swarm_code.provenance.verify`, and `git diff --check` passed.
- Saved PTY smoke passed after adding `/goal`, `/plan`, and `/rewind` to the real
  guarded database/socket/native-terminal flow, followed by a second launcher
  process that resumed the saved transcript. Provider traffic stays on loopback
  and all database/project state is disposable test data.
- Independent reviewer `feedback_review` identified the report scroll-reset bug;
  it was fixed and verified. No web checkout was edited.
- Ego-browser inspected the captured terminal cells. Dedicated task spaces 11
  and 12 returned `done: true` on close. User sessions/cookies were not wiped.
  The task-owned preview HTTP server was stopped.

## Remaining full objective

Full feature parity is not proved. Continue research attachment selection and
composer metadata, forms for research/schedules/settings/providers/workflows/MCP,
planning gates and advanced mode end-to-end acceptance, Git/checkpoint workflows,
memory/attachments, plain/NDJSON startup, persistent daemon lifecycle, and
installable releases with supported-platform verification. Keep the full scope
and the active goal; this report closes only the feedback slice.

## Follow-up: saved workspace metadata

The saved workspace snapshot now carries mode, chat model, swarm model and effort
metadata. The header and composer use that metadata, so a persisted `/plan` or
`/ultra` change is visible immediately and after restart. A typed
`workspace_metadata` delta updates an open conversation without replacing the
transcript or draft; stale metadata revisions are ignored. Historical snapshots
without these optional fields remain accepted by the codec.

Focused metadata evidence: daemon service **63 tests**, CLI metadata/projector/
codec/watch **46 tests**, zero failures. The saved PTY smoke verifies the real
header as `SAVED · DEV · Build · pty-fixture`, then `SAVED · DEV · Plan ·
pty-fixture` after `/plan` and after the second launcher resumes the conversation.
Independent review found no new metadata defect. Run destination navigation still
has a separate pre-existing workspace/inspector slot mismatch and is being fixed
as the next bounded task.
