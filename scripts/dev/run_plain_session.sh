#!/usr/bin/env bash
set -euo pipefail

if [[ $# -eq 1 && "$1" == "--help" ]]; then
  cat <<'HELP'
SwarmCode plain CLI — persisted, headless session

Usage: scripts/dev/run_plain_session.sh [--ndjson]

Reads one command per line from stdin and writes human-readable output. It is
safe for pipes and CI; EOF closes the owned session cleanly. Use the same
SWARM_PROJECT_ROOT, SWARM_CONVERSATION and provider variables as
run_saved_session.sh.

Pass --ndjson to emit one JSON object per output record.

Examples:
  printf 'send -- inspect this project\ndetach\n' | scripts/dev/run_plain_session.sh
  scripts/dev/run_plain_session.sh < commands.txt

Plain commands: send -- TEXT, queue -- TEXT, answer ID@REV OPTION,
pause RUN, continue RUN, stop RUN, retry RUN@REV, inspect RUN, detail REF,
back, detach. The full slash-command registry is available through send.
HELP
  exit 0
fi

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--ndjson" ) ]]; then
  echo "Usage: scripts/dev/run_plain_session.sh [--ndjson|--help]" >&2
  exit 2
fi

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/dev/load_provider_env.sh"
export SWARM_PROJECT_ROOT="${SWARM_PROJECT_ROOT:-$PWD}"
export SWARM_PLAIN_FORMAT="${1:-text}"
cd "$root"
exec mise exec -- elixir -S mix run --no-start scripts/dev/plain_session.exs
