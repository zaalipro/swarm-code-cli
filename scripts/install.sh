#!/usr/bin/env bash
# Builds the release from this checkout and installs it as the `ncode` command
# (the contributor path; users install with the one-line installer from
# code.llmotions.com).
#
#   scripts/install.sh              -> ~/.local/share/ncode and ~/.local/bin/ncode
#   NCODE_PREFIX=/opt/x scripts/install.sh   (SWARMCODE_PREFIX is still read)
#
# Re-running replaces the previous install. Nothing outside the prefix is
# touched, and the user's conversations live in the canonical database, not
# under the prefix, so a reinstall never loses them. `ncode`, the old
# name, stays as a command that runs ncode.
set -euo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
prefix="${NCODE_PREFIX:-${SWARMCODE_PREFIX:-$HOME/.local}}"
share="$prefix/share/ncode"
bin="$prefix/bin"

"$root/scripts/dev/build_release.sh"

release="$root/_build/prod/rel/swarm_code_cli"
[[ -x "$release/bin/ncode" ]] || { echo "install: the release has no bin/ncode" >&2; exit 1; }

rm -rf -- "$share"
mkdir -p -- "$share" "$bin"
cp -R -- "$release/." "$share/"
chmod 0600 "$share/releases/COOKIE"

cat > "$bin/ncode" <<SHIM
#!/bin/sh
exec "$share/bin/ncode" "\$@"
SHIM
chmod 0755 "$bin/ncode"

# The old command name keeps working: it runs the release's deprecated alias.
cat > "$bin/swarmcode" <<SHIM
#!/bin/sh
exec "$share/bin/swarmcode" "\$@"
SHIM
chmod 0755 "$bin/swarmcode"

echo "Installed ncode: $bin/ncode -> $share"
if [[ -d "$prefix/share/swarmcode" ]]; then
  echo "The previous install is still in $prefix/share/swarmcode; nothing uses it now, so you can remove it."
fi
case ":$PATH:" in
  *":$bin:"*) echo "Run: ncode [DIR]" ;;
  *) echo "Add $bin to your PATH, then run: ncode [DIR]" ;;
esac
