# Indexed question service checkpoint

The CLI checkout now supports the complete question-answer transport for the
persisted service backend:

- Closed `question.answer` service request and negotiated capability.
- Existing option-only intents plus a closed custom-text answer payload.
- TUI custom-answer field, multiple selection, and a 4,000-byte input limit.
- Stable question identities derived from node, pending revision, and original
  question index; duplicate labels have distinct option IDs.
- Synchronous `RunServer.answer_question/5` validates selections, custom input,
  duplicates, and indices. Partial answers stay in the run owner until all
  questions have answers, then the original tool waiter receives ordered results.
- Pending projections omit answered questions and preserve remaining indices.
- The persisted backend advertises `answer_question` (the actual DTO permission),
  validates scope/node/revision/options, and projects question Activity entries.
- A loopback provider acceptance test calls the actual `ask_user` tool, receives
  two questions, answers one with an option and one with custom text, and verifies
  both answers in the provider's following request and a completed run.

Verified focused results:

- Persisted backend suite: 10 tests passed, including the new real interview.
- CLI ActivityQuestion suite: 6 tests passed, including custom answer wire encoding.
- Indexed RunServer answer and bounded interaction tests passed (5 + 5).
- Core question/feature request tests and question identity/selection test passed.
- CLI suite: 576 tests and 5 properties passed (seed 24680).
- Native DatabaseBinding suite: 5 tests passed; unsafe sidecars now reject and
  explicitly closed binding resources release their retained lease reference.
- Compile with warnings as errors, provenance, and whitespace checks passed.

The first broad seed-24680 run reported three Backup.Gate failures at test lines
338, 770, and 918. The three selected cases passed in isolation, recorded in
`_build/backup-three-repro.log` (52 discovered, 49 excluded, 3 passed). The cause
has not been proven; concurrent VM activity and cleanup deadlines are hypotheses.
The isolated broad run (`mix test apps/swarm_code_core/test
apps/swarm_code_daemon/test apps/swarm_code_cli/test --seed 24680`) completed with
core **122**, daemon **544**, CLI **576 and 5 properties**, all passing. The changed
question UI also passed the terminal demo PTY suite (8 tests). Its `question.txt`
capture was inspected through ego-browser task space 10, then that dedicated task
space was closed; no user browser state was touched.

Full parity remains incomplete. Most importantly, the native binding still has no
production descriptor-relative SQLite connection path, and the live launcher is
still unsaved. The complete remaining scope is listed in the prior persisted
service checkpoint. Do not treat the question feature or these tests as proof of
production startup, advanced-mode parity, or release readiness.
