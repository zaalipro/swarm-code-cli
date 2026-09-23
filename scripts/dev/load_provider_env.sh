#!/usr/bin/env bash
# Sourced by the launchers (and copied into the release as bin/load_provider_env.sh).
# Never print or persist private settings.
#
# pass70 B4 (rel F5): only provider variables leave the environment file. The
# file is evaluated in a clean child shell and just SWARM_*, OPENAI_* and
# ANTHROPIC_* come back, so a GitHub, npm or Linear token in ~/.secrets never
# reaches the BEAM, and therefore never a model-run shell command.
# SWARM_MODEL_OVERRIDE is set only by `swarmcode --model` and is never loaded.
swarm_load_provider_env() {
  # Presence matters: an explicitly empty key selects unauthenticated local APIs.
  if [[ ${SWARM_API_KEY+x} || ${OPENAI_API_KEY+x} || ${ANTHROPIC_API_KEY+x} ]]; then
    return 0
  fi

  local swarm_env_path="${SWARM_ENV_FILE:-${HOME}/.secrets}"
  if [[ ! -f "$swarm_env_path" ]]; then
    if [[ -n ${SWARM_ENV_FILE:-} ]]; then
      echo 'SWARM_ENV_FILE must point to an existing environment file.' >&2
      return 1
    fi
    return 0
  fi

  local swarm_env_name swarm_env_value
  # Shell exports win over the file: only unset names are taken from it.
  while IFS= read -r -d '' swarm_env_name && IFS= read -r -d '' swarm_env_value; do
    case "$swarm_env_name" in
      SWARM_MODEL_OVERRIDE) continue ;;
      SWARM_*|OPENAI_*|ANTHROPIC_*) ;;
      *) continue ;;
    esac
    [[ $swarm_env_name =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    if [[ -z ${!swarm_env_name+x} ]]; then
      printf -v "$swarm_env_name" '%s' "$swarm_env_value"
      export "$swarm_env_name"
    fi
  done < <(
    env -i HOME="$HOME" PATH="$PATH" bash --noprofile --norc -c '
      set -a
      # shellcheck disable=SC1090
      source "$1" >/dev/null 2>&1 </dev/null
      for name in $(compgen -e); do
        case "$name" in
          SWARM_*|OPENAI_*|ANTHROPIC_*) printf "%s\0%s\0" "$name" "${!name}" ;;
        esac
      done
    ' swarm-env "$swarm_env_path"
  )
}

swarm_load_provider_env
unset -f swarm_load_provider_env
