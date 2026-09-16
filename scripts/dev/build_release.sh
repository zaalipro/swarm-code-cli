#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

# The release owns the BEAM/daemon. The native terminal port remains an explicit
# checked artifact so a release can never silently fall back to a fake renderer.
scripts/dev/check_terminal_port.sh
export MIX_ENV="${MIX_ENV:-prod}"
overlay_root="$root/rel/overlays"
mkdir -p "$overlay_root/bin"
cp -- "${root}/_build/terminal-port/debug/swarm-terminal-port" "$overlay_root/bin/swarm-terminal-port"
chmod 0755 "$overlay_root/bin/swarm-terminal-port"
# The installed `swarmcode` launcher loads provider settings with the same
# rules as the development launchers, from the same file.
cp -- "${root}/scripts/dev/load_provider_env.sh" "$overlay_root/bin/load_provider_env.sh"
cleanup_overlay() {
  rm -f -- "$overlay_root/bin/swarm-terminal-port" "$overlay_root/bin/load_provider_env.sh"
}
trap cleanup_overlay EXIT INT TERM
mise exec -- mix release swarm_code_cli --overwrite

echo "Release ready: _build/${MIX_ENV}/rel/swarm_code_cli"
echo "Start it with: _build/${MIX_ENV}/rel/swarm_code_cli/bin/swarmcode [DIR]"
