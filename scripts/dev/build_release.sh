#!/usr/bin/env bash
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

# cli020 A7: a release is never cut while the desktop has moved past the pin
# (new migrations would make this CLI refuse the shared database; code drift
# means the domain is stale). NCODE_ALLOW_DRIFT=1 is the escape hatch.
if [ "${NCODE_ALLOW_DRIFT:-}" = "1" ]; then
  echo "NCODE_ALLOW_DRIFT=1: skipping the provenance drift gate"
else
  mise exec -- mix swarm_code.provenance.drift --strict
fi

# The release owns the BEAM/daemon. The native terminal port remains an explicit
# checked artifact so a release can never silently fall back to a fake renderer.
# Released binaries must run on macOS 15; without this the toolchain targets the
# host SDK (macOS 26). Override with MACOSX_DEPLOYMENT_TARGET when needed.
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.0}"
scripts/dev/check_terminal_port.sh
export MIX_ENV="${MIX_ENV:-prod}"
overlay_root="$root/rel/overlays"
mkdir -p "$overlay_root/bin"
cp -- "${root}/_build/terminal-port/debug/swarm-terminal-port" "$overlay_root/bin/swarm-terminal-port"
chmod 0755 "$overlay_root/bin/swarm-terminal-port"
# The installed `ncode` launcher loads provider settings with the same
# rules as the development launchers, from the same file.
cp -- "${root}/scripts/dev/load_provider_env.sh" "$overlay_root/bin/load_provider_env.sh"
cleanup_overlay() {
  rm -f -- "$overlay_root/bin/swarm-terminal-port" "$overlay_root/bin/load_provider_env.sh"
}
trap cleanup_overlay EXIT INT TERM
# The daemon's C and Objective-C helpers (priv/native) are shared by every
# MIX_ENV and rebuilt only when their source changes, so a dev or test build
# leaves helpers compiled for the host's macOS. Rebuild them under
# MACOSX_DEPLOYMENT_TARGET before the release copies them (cli020 fix round).
(cd apps/swarm_code_daemon && mise exec -- mix compile.schema_snapshot --force)
mise exec -- mix release swarm_code_cli --overwrite
# The cookie is unused (RELEASE_DISTRIBUTION=none) but never world-readable.
chmod 0600 "_build/${MIX_ENV}/rel/swarm_code_cli/releases/COOKIE"

echo "Release ready: _build/${MIX_ENV}/rel/swarm_code_cli"
echo "Start it with: _build/${MIX_ENV}/rel/swarm_code_cli/bin/ncode [DIR]"
