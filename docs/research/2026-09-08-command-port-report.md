# Slash command port report (2026-09-08)

Implemented pure CLI registry/parser in `apps/swarm_code_core/lib/swarm_code/commands.ex` with tests in `apps/swarm_code_core/test/swarm_code/commands_test.exs`.

API: `SwarmCode.Commands.parse(text, opts \\ [])` returns `{:ok, map}` for validated built-ins, workflows and custom commands, or `{:error, %{type: atom}}` for invalid, unknown, missing argument, and invalid effort input. `catalogue(query \\ "/", opts \\ [])` returns ranked metadata (prefix then word-boundary matches), enforcing builtin > workflow > custom precedence. `modes/0` and `mode_values/0` expose the six composer modes. Custom command bodies expand `$ARGUMENTS`; parser performs no filesystem or runtime execution.

Source provenance (web repository `HEAD` at port time):
- `lib/swarm_code_web/components/chat.ex` — commit blob `1ec58363ddc950e3187975b5f476cb5ece036920`
- `lib/swarm_code_web/live/workspace_live.ex` — commit blob `ad70e4e3197e0a6664a0d9a443ad08c1205d3cc0`
- `lib/swarm_code/commands.ex` — commit blob `52e6c749a6cf26fb387307b7feb58d4139b1fb53`

Root agent should run the core ExUnit suite; this subtask intentionally did not run Mix/tests per coordination instructions.
