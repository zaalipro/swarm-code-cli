#!/usr/bin/env bash
set -euo pipefail
terminal_demo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd -- "$terminal_demo_root/apps/swarm_code_cli"
exec mise exec -- elixir --erl '-noinput' -S mix swarm_code.demo.terminal "$@"
