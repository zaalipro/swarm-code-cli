#!/usr/bin/env bash
set -euo pipefail
# pass71 S3: what the session writes (logs, sockets, backups, temp files) is
# owner-only, like the release (`rel/env.sh.eex`).
export SWARM_USER_UMASK="${SWARM_USER_UMASK:-$(umask)}"
umask 077
if [[ $# -eq 1 && "$1" == "--help" ]]; then
  cat <<'HELP'
SwarmCode development TUI — LIVE · UNSAVED

Usage: scripts/dev/run_live_session.sh

Set SWARM_MODEL to your provider's model ID and SWARM_PROJECT_ROOT to the
project directory. Set an explicit SWARM_BASE_URL and provider API key:

  export SWARM_MODEL=your-model-id
  export SWARM_BASE_URL=https://api.openai.com/v1
  export OPENAI_API_KEY=your-key
  scripts/dev/run_live_session.sh

SWARM_PROVIDER: openai (default), anthropic
SWARM_API_KEY: overrides OPENAI_API_KEY / ANTHROPIC_API_KEY
SWARM_APPROVAL: ask (default), read-only, auto
SWARM_EFFORT: medium (default), or a supported effort key

For the saved, database-backed session use:

  scripts/dev/run_saved_session.sh

It uses the guarded canonical database, resumes the selected project
conversation, and preserves history across restart. Set SWARM_CONVERSATION to a
conversation UUID to select one, or leave it unset to resume the latest.

First build: scripts/dev/check_terminal_port.sh
Keys: type to write; Enter sends, Esc stops a turn, Ctrl-C twice quits, Ctrl-P palette.
Visual companion: Ctrl-P, "Open visual companion" (SWARM_COMPANION=0 disables).
Sessions are unsaved; tools can modify the selected project's files.
HELP
  exit 0
fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/dev/load_provider_env.sh"
export SWARM_PROJECT_ROOT="${SWARM_PROJECT_ROOT:-$PWD}"
cd "$root"
exec mise exec -- elixir --erl '-noinput' -S mix run --no-start scripts/dev/live_session.exs "$@"
