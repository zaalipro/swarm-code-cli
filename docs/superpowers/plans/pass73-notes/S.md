# Pass 73, owner S (daemon and wire): notes, published contract, requests

Branch `p73/S`. Tag `p73-S-wire` marks the commit where every wire field below exists and
decodes on the client. Read the new fields with `Map.get(x, :field)` (or the default in brackets)
until S is merged.

## T11: why the session died, and what changed

The cause: the daemon closed a busy client's connection without logging anything. A watch
overflowed when several runs were live and the terminal fell behind. The daemon then dropped the
watch and wrote `snapshot_required` after the deltas already on the wire. The client's 32-slot
delivery queue was full, so it consumed those deltas and acknowledged them before it read
`snapshot_required`. Its acks named a watch that no longer existed. `Connection.handle_ack/3`
treated that as a protocol violation, and the connection closed with no log line. The client saw
only `the daemon closed the connection` and then `session closed: :source_unavailable`, which is
exactly what the owner's cli.log showed. `pass73_session_flow_test.exs` reproduces this through
the real client, socket and backend. On 30b27fc the session dies 10 ms after the overflow.

Other ways a busy session closed or refused things, all fixed, each with a test:

| Where | Before | Now |
| --- | --- | --- |
| daemon `Connection` | an ack for a dropped or stale watch closed the connection | acknowledged; nothing changes |
| daemon `Connection` | the 4,097th request id closed the connection (every consumed delta is one ack request) | request ids are a recent window of 4,096 |
| daemon `Connection` | a pending watch took one of the 32 request slots, and the 33rd request closed the connection | watches have their own 16; the 33rd request gets `capacity_exceeded`, the connection stays |
| daemon listener | `send_timeout: 2000`: a client that paused reading for 2 s lost its connection (Unix sockets here buffer 8 KB) | 45 s (the client allows its owner 30 s per delivery) |
| daemon `Connection` | an unencodable reply closed the connection | that request fails on its own |
| client `DataSource.Daemon` | one socket read carrying more frames than the queue holds: "rejected a daemon message" and the session closed | the extra frames wait in a read backlog, in order; reading pauses (backpressure) |
| client | request ids were never forgotten: the 257th request of a session was refused for good ("The daemon refused that request") | a recent window of 256 |
| client | `requests + queued deliveries < 32`: a streaming swarm refused every command | only requests in flight count (32) |
| backend | the response cache refused every command after the 4,096th | it evicts the oldest; the durable ledger still replays |

Close reasons in cli.log (redacted: check or operation names, never payloads):

- Daemon, warning: `SwarmCode daemon closed a client connection: <why>`. The reasons are: the
  hello carried the wrong nonce; the handshake failed; a request carried the wrong nonce; a
  request reused a recent id; a request did not decode (op); a request needs a capability this
  session lacks; a watch past the limit of 16; a watch reused its reference; an ack past the last
  delta sent; an ack/unwatch named another scope's watch; a frame did not decode; an unexpected
  <type> frame in phase <phase>; a frame could not be written (timeout|closed…); a reply could not
  be written (op: why); an acknowledgement could not be written; a delta could not be sent; a
  watch snapshot could not be published; the backend went away; the client did not complete the
  handshake in time; the client left a frame unfinished; socket error.
- Daemon, info: `SwarmCode daemon: the client closed its connection (N watches, M requests in
  flight)`. This means the client side closed.
- Daemon, warning: `SwarmCode daemon refused a request: 32 already in flight (op)`.
- Client (unchanged): `SwarmCode: closing the daemon connection: <why>`, `SwarmCode: the daemon
  closed the connection.`

## T3/T8: what a send does while work runs (the daemon's rules)

These rules follow the desktop domain. `Engine.start_*` never blocks on a running run, and
`Engine.steer/4` delivers to the running chat run. The daemon's persisted backend routes a
`dispatch` with `action: "send"` as follows:

1. `/compact` while a chat turn or a compaction runs goes on the conversation's queue:
   `disposition: queued`, `identifiers: []` (a queued send starts no run, so it names none).
2. Any other slash command runs at once, beside the live runs. Run-launching commands give
   `disposition: started` with `identifiers: [run_id]`. This covers `/swarm`, `/consensus <task>`,
   `/create-workflow`, `/workflow`, `/goal`, `/review`, `/resume-run`, and now `/plan <task>`
   (a planner run; the conversation keeps its mode). Bare `/plan` still toggles the mode.
3. A plain message while a chat turn runs steers the newest running chat turn:
   `disposition: steered`, `identifiers: [that run_id]`, feedback notice "Sent to the running
   turn.". The message is stored against that run, and the model reads it on the turn's next
   call. If the turn ended between the check and the steer, the message is queued. With images it
   starts its own turn, because images cannot wait on the queue.
4. A plain message while only a compaction runs is queued, so it reads the summary.
5. Otherwise the message starts a chat turn: `disposition: started`.

`action: "queue"` (Tab, Alt-Enter, `/queue`) queues any text, commands included, while a turn
or compaction runs. With nothing running it is an ordinary send. A queued image is refused with
`attachments_not_queued`.

The queue drains when the turn (chat or compaction) ends. A queued command goes through the
dispatcher, so a queued `/compact` runs as a compaction, and a queued prompt starts a chat turn. A
queued command that can never run (for example `nothing_to_compact`) leaves the queue with a
toast in words. A prompt is never dropped; its failures are retried.

## Published wire fields (tag `p73-S-wire`)

- `DTO.Outcome.disposition`: `:started | :steered | :queued | nil` (only on `:accepted`).
- `DTO.Outcome.reason`: `%DTO.Refusal{code: String.t(), text: String.t()} | nil` (only on
  `:rejected`). `code` is the service's reason and never becomes an atom. The codes are
  `nothing_to_compact missing_argument unexpected_argument invalid_argument unknown_command
  unknown_workflow invalid_workflow_arguments not_configured no_project database_busy
  nothing_to_stop not_resumable not_running not_paused not_found conversation_not_found
  ambiguous_run ambiguous_conversation unknown_model invalid_effort invalid_budget
  budget_too_low input_too_large expansion_too_large not_attachable attachments_not_queued
  too_many_attachments client_only operation_failed run_not_found agent_not_found
  decision_not_offered run_finished steer_finished`. `text` is the sentence to show, for example
  "/swarm needs <task>.", "Nothing to compact yet: this conversation has no history to
  summarise.", "The database was busy; send it again.". `error` still carries the closed
  `AdmissionError` code, as before.
- Run control (pass73 S10). A stop that reaches a run already finished is now `accepted`, with
  the notice "That run had already finished.". In the live check, a second Ctrl-C reached the
  swarm the first had stopped, and the footer said "The daemon refused that request". Every other
  run-control, steer or approval refusal carries a `reason`: `run_not_found`, `agent_not_found`,
  `decision_not_offered`, `run_finished`, `steer_finished` ("That run has finished; send the
  message in the chat to start a new turn."), `not_running`, `not_paused`. cli.log logs each one
  as `SwarmCode daemon refused a command (<op>): <code>`.
- A queued send (pass73 S11) answers `identifiers: []`. Before, it named the conversation id,
  and every client read that as the run the send started. The terminal's `note_sent_turn/3`
  kept `sent_turn: {conversation, conversation_id}`, which the read model never shows. The next
  Ctrl-C then said "Stopping the turn." and did nothing, and only a later press armed the quit. A
  one-shot `exec` would have waited for that "run" to finish.
- `DTO.TranscriptItem.target_kind == :steer` with `target_id` set to the run: a user message
  the running turn took in, whether it came from the chat or from the overlay's steer.
- `DTO.WorkspaceSnapshot.queued_texts` and `DTO.WorkspaceMetadata.queued_texts`: `[String.t()]`,
  what waits on the queue, oldest first (at most 20, 2 KB each). `queued` is still the count.
- Approval policy (T7): the client can already observe every change through
  `WorkspaceMetadata.approval_mode`. A `workspace_metadata` delta follows `/approval …`, the
  `project_update` op and `/trust`. No new event was needed.

## Requests for other owners (exact changes)

### K (reducer, keymap, composer)

1. `ui/reducer.ex`, `settle_command/3`: a refused command shows its words. Add a clause before
   the fallback `_ ->`:
   ```elixir
   {:rejected, _, {:draft, {conversation, _}}, {conversation, _}} when outcome.reason != nil ->
     {%{settled | notice: {:command_feedback, outcome.reason.text}}, effects}
   ```
   Use `Map.get(outcome, :reason)` until S is merged.
2. `SwarmCodeCLI.UI.Composer.enter_action/1` should say what the daemon will do. The rules are
   in the T3/T8 section above:
   - `:steer` when the text is plain and a chat run of this conversation is live, i.e.
     `RunSummary.kind == :chat` with a live status.
   - `:queue` for `/compact` while a chat or compact run is live, and for plain text while only a
     compaction is live.
   - `:run_command` for other slash commands.
   - `:send` otherwise.
   Differences from `Composer.enter_action/1` at tag `p73-K-keyword` (ef2239b), where the
   daemon will do something else:
   - `@after_turn ~w(compact rewind)`: the daemon runs `/rewind` at once. It only opens the
     checkpoint picker (a selection), and a queued selection would have nowhere to open. Please
     drop `rewind`.
   - A chat turn that is `:paused` or `:queued`: the daemon steers it. Registered runs include
     paused ones, and `Engine.steer/4` hands the message to the root agent, which reads it when
     the turn resumes. The client says `:queue`. Please treat these states as `:steer`, or accept
     that the daemon's `disposition: :steered` corrects the mark.
   - A plain message while only a compaction runs: the daemon queues it, so the next turn reads
     the summary. A compaction is presented as `kind: :chat` (`presentation_kind/1`), so the
     client predicts `:steer`. That is rare and short-lived. The outcome's
     `disposition: :queued` is the truth; no client change is needed.
3. Keep the steered and queued marks for the sent message from `outcome.disposition`
   (`:steered` / `:queued`). The durable facts come from the transcript (`target_kind: :steer`)
   and `queued_texts`.
4. `note_sent_turn/3` (reducer.ex, about line 1957) takes the first identifier of any accepted
   send as the run the send started. Since S11 a queued send names none, so that is safe again.
   A steered send names the running turn, which is already in the read model, so no `sent_turn`
   is kept. To make the rule explicit, match only `disposition` `nil` or `:started`:
   ```elixir
   %Outcome{status: :accepted, identifiers: [run_id | _]} = outcome
   when outcome.disposition in [nil, :started]
   ```
   Use `Map.get(outcome, :disposition)` in a body check until S is merged.
5. Seen in the sandbox live check and not explained in S's files: after the first Ctrl-C
   stopped a swarm of 5, further Ctrl-C presses each showed "The daemon refused that request",
   and the quit never armed; `/quit` worked. At that point the header already drew the swarm as
   stopped, and every run in the database was terminal. The refusal was a stop of the finished
   swarm; since S10 the daemon accepts it with "That run had already finished.". If
   `Keymap.live_turn(state, @live_states)` still returns a run there, every press sends a stop
   and never reaches `:idle`, so the quit never arms. Please check which run it returns once the
   header shows none live. The candidates are a run held in `:paused`, `:waiting_question` or
   `:waiting_approval`, which `@live_states` counts but the header may draw differently. From
   now on, cli.log names each refusal (`SwarmCode daemon refused a command (run_control):
   <code>`).

### V1 (transcript)

1. A user item with `target_kind == :steer` gets the small "→ to the running turn" mark. It sits
   under its run, because the item's `run_id` is the steered run.
2. `WorkspaceSnapshot.queued_texts` / `WorkspaceMetadata.queued_texts`: draw each waiting
   message after the live turn with "queued · sends after the running turn". When the queue
   drains, it becomes an ordinary user message.

### V2 (status)

1. `projector/status.ex`, `mutation_toast/1`: `{:settled, _, :rejected}` reads "The daemon
   refused that request". With K's request 1 the reason's words are already the notice.
   Suggested change: return `nil` for `:rejected` when `state.notice` is a `{:command_feedback,
   _}` set by that settlement. Otherwise use "That was refused" and never the word "daemon".
