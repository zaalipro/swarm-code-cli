#!/usr/bin/env bash
set -euo pipefail
if [[ $# -eq 1 && "$1" == "--help" ]]; then
  cat <<'HELP'
SwarmCode development TUI — SAVED · DEV

Usage: scripts/dev/run_saved_session.sh

Runs the same session as the installed swarmcode on the canonical database.
Resumes the latest saved conversation for SWARM_PROJECT_ROOT by default.
Set SWARM_CONVERSATION to latest, new, or an existing conversation UUID.
The conversation's own provider and model (or the SwarmCode default) are used;
SWARM_MODEL_OVERRIDE=<model|provider/model> overrides them for this session
only. SWARM_* settings create a provider only when none exists yet.
Logs: ~/Library/Logs/SwarmCode/cli.log (XDG state dir on Linux).

First build: scripts/dev/check_terminal_port.sh
Keys: type to write; Enter sends, Esc stops a turn, Ctrl-C twice quits, Ctrl-P palette.
Visual companion: Ctrl-P, "Open visual companion" (SWARM_COMPANION=0 disables).
HELP
  exit 0
fi
if [[ $# -ne 0 ]]; then echo "Usage: scripts/dev/run_saved_session.sh [--help]" >&2; exit 2; fi
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/dev/load_provider_env.sh"
export SWARM_PROJECT_ROOT="${SWARM_PROJECT_ROOT:-$PWD}"
cd "$root"
exec mise exec -- elixir --erl '-noinput' -S mix run --no-start -r scripts/dev/persisted_session.exs -e 'SwarmCode.Development.PersistedSession.run()'
