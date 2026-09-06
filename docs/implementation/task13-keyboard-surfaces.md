# Keyboard interaction surface

The current runnable spike routes semantic inputs through `UI.Keymap.resolve/3` and uses the current ActionTable for domain commands. Action IDs are opaque; routing compares stored targets. The reducer owns request IDs, pending mutations, editor state, modal focus, and return context.

Implemented routes include committed typing/paste, neutral editor movement and undo, Enter Send, Ctrl+O newline, capability-gated Shift+Enter newline, Alt+Enter Queue, Ctrl+K switcher, region focus cycling, list navigation/scrolling, dock toggles and sizing, composer height, run controls, Activity questions/approvals, Stop confirmations, and detail paging. Queue is searchable as `/queue` in the switcher. Retry and agent Stop have distinct authorized catalogue targets. Escape closes one layer. Other-client resolution and accepted/pending submissions suppress further answers without automatically closing the layer.

The switcher uses the closed `/`, `@`, `#`, and `>` prefix grammar. Search results are deterministic; an absent category produces no results. Its catalogue exposes only destinations and actions supported by the current closed Action/Intent/DTO contracts.

Remaining interaction-spec surfaces:

- The destination union currently contains conversation, run, and Activity. Chats index, new-conversation creation, Workflows, Research, Scheduled, Usage, and Settings have no destination/action contract. Their jump shortcuts are not mapped to substitute destinations. `g g` uses the jump layer to reach the first logical row.
- Mode selection, prompt history, fork/edit workflows, and target-selection layers need explicit semantic actions before their shortcuts can be implemented. The existing draft-target primitive remains available to callers.
- Region-filter editing is isolated from composer text; applying that query to source rows and next/previous-match navigation remain to be implemented.
- The Question DTO supports fixed options and multi-select but carries no Other-text or Skip authority. Free-form Other submission and Skip therefore emit no invented command. FieldKey supports an isolated Other editor for a future DTO extension.
- Needs-you bell preference and durable once-per-visible-interaction notification tracking are not present; background Activity updates remain silent and do not navigate.

Focused coverage lives in `keymap_test.exs`, `layers_test.exs`, and `activity_question_test.exs`. It exercises input isolation, press/repeat/release gating, current-target membership, selected-run identity, default-Cancel confirmations, queue equivalence, detail paging, deterministic switcher ranking, Activity ordering, exact revision-7 question requests, multi-select, and duplicate suppression across pending/accepted states.
