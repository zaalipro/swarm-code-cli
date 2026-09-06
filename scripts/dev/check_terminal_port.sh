#!/usr/bin/env bash
set -euo pipefail

terminal_port_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd -- "$terminal_port_root"
export RUSTUP_AUTO_INSTALL=0
terminal_port_cargo="$(mise which cargo)"
export RUSTUP_TOOLCHAIN="$(awk '$1 == "rust" { print $2 }' .tool-versions)"
export CARGO_TARGET_DIR="$terminal_port_root/_build/terminal-port"
export CARGO_HOME="$terminal_port_root/_build/ratatui-port-cargo"

# Prefer the repository-local compiler when one was installed for this checkout.
# Otherwise mise/rustup selects the user's pinned compiler. Never install here.
if [[ -d "$terminal_port_root/_build/ratatui-port-toolchain/toolchains" ]]; then
  export RUSTUP_HOME="$terminal_port_root/_build/ratatui-port-toolchain"
fi

"$terminal_port_cargo" fmt --manifest-path native/terminal_port/Cargo.toml --check
"$terminal_port_cargo" test --manifest-path native/terminal_port/Cargo.toml --locked
