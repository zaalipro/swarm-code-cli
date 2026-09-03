# Task 5 report — Scene and renderer-neutral boundary

Implemented closed renderer-neutral Scene data model, block union, validation, renderer behavior/options/error shells, and architecture guard tests.

## Verification

`mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/scene_contracts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/architecture_test.exs`

Result: 5 tests, 0 failures.

## Notes

- Scene validation enforces SafeText-only text positions, bounded rectangles, closed roles/styles, cursor and dialog metadata, opaque action IDs, duplicate-ID rejection, and process/function/reference rejection.
- Architecture guard excludes only the exact conditional `ui/renderer/ex_ratatui_013/` directory.

## Fix round 1

Addressed all review findings:

- Virtual-list windows now require `first_index + length(items) <= total_count`; overscan is explicitly bounded to the projector policy of `0..2`.
- Architecture checks now use the exact normalized approved adapter root and adversarially cover remote calls, captures, dynamic `apply/3`/`Module.concat`, dependency references, code-path loading, daemon IPC, FoundationGate, Repo, and database paths.
- Scene validation rejects forged extra keys recursively on every struct.
- All fifteen block variants now publish explicit field types using `SafeText`, opaque binary IDs, bounded numbers, and closed nested unions.
- Added regression coverage for incoherent windows, overscan, forged block/style fields, exact-path exemptions, and adversarial coupling forms.

RED evidence:

- Scene regression: 4 tests, 1 failure; out-of-range virtual-list window incorrectly returned `:ok`.
- Architecture regression: 3 tests, 1 failure; split dynamic module lookup / generic apply / code-path forms were not rejected.

GREEN evidence:

- Focused Task 5 tests: 7 tests, 0 failures.
- Full CLI tests: 39 tests, 0 failures.

Changed files are limited to Task 5 Scene/block/test/report paths. Self-review confirmed the exact adapter-root check is used by the actual repository scan, no arbitrary error messages or semantic action targets enter Scene, and the virtual-list typespec matches its runtime `0..2` bound.

## Fix round 2

- Architecture guard now scans `apps/swarm_code_cli/mix.exs` for denied dependency declarations while retaining the `lib/**/*.ex` production scan.
- Added standalone denials for `:database_path`, `DatabasePath.resolve`, `Exqlite`/SQLite and db-path spellings, plus independent adversarial cases.
- Replaced the broad `apply` source regex with AST arity checks, preserving neutral identifiers such as `apply_delivery`.

Verification: focused Scene/architecture suite **7 tests, 0 failures**; full CLI suite **39 tests, 0 failures**; format and `git diff --check` passed. Self-review confirms mix dependency scanning is independently callable and comments remain ignored.
