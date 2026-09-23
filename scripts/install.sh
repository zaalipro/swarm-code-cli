#!/usr/bin/env bash
# Builds the release and installs it as the `swarmcode` command.
#
#   scripts/install.sh              -> ~/.local/share/swarmcode and ~/.local/bin/swarmcode
#   SWARMCODE_PREFIX=/opt/x scripts/install.sh
#
# Re-running replaces the previous install. Nothing outside the prefix is
# touched, and the user's conversations live in the canonical database, not
# under the prefix, so a reinstall never loses them.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${SWARMCODE_PREFIX:-$HOME/.local}"
share="$prefix/share/swarmcode"
bin="$prefix/bin"

"$root/scripts/dev/build_release.sh"

release="$root/_build/prod/rel/swarm_code_cli"
[[ -x "$release/bin/swarmcode" ]] || { echo "install: the release has no bin/swarmcode" >&2; exit 1; }

rm -rf -- "$share"
mkdir -p -- "$share" "$bin"
cp -R -- "$release/." "$share/"
chmod 0600 "$share/releases/COOKIE"

cat > "$bin/swarmcode" <<SHIM
#!/bin/sh
exec "$share/bin/swarmcode" "\$@"
SHIM
chmod 0755 "$bin/swarmcode"

echo "Installed swarmcode: $bin/swarmcode -> $share"
case ":$PATH:" in
  *":$bin:"*) echo "Run: swarmcode [DIR]" ;;
  *) echo "Add $bin to your PATH, then run: swarmcode [DIR]" ;;
esac
