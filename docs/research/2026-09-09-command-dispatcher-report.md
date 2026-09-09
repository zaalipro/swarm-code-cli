# Daemon slash-command dispatcher

`SwarmCode.Daemon.Service.CommandDispatcher.dispatch/3` resolves a persisted conversation, builds parser metadata from its project commands/workflows, and executes parsed command intents through Domain APIs. Results are explicit maps with `:started`, `:updated`, `:stopped`, `:select`, `:navigate`, `:attached`, or `:saved` types; failures use bounded atoms.

The dispatcher covers all sixteen builtins, custom commands, and workflow aliases. Starts use `Domain.Engine` and verify the returned persisted run belongs to the conversation. Goal commands persist a goal before starting chat/swarm execution; mode and effort commands update conversation fields; workflow launch/control/save routes use persisted workflow definitions/runs; research and rewind commands return bounded selection results or validate attachment before returning a next-message attachment intent. Bare workflows/navigation/selection commands never claim a UI operation happened.

Focused fixture tests run with the real Domain Repo/migrations and an in-process loopback OpenAI-compatible HTTP server. The suite covers malformed requests, every mode/effort path, selection/navigation, not-configured failures, custom expansion, workflow launch/control/save, research attachment, and a completed custom chat plus review run. Latest result: 8 tests, 0 failures.
