#!/usr/bin/env bash
# Sourced by development launchers. Never print or persist private settings.
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

  local swarm_env_names=() swarm_env_values=()
  local swarm_env_name swarm_env_index=0 swarm_env_autoexport=0
  while IFS= read -r swarm_env_name; do
    case "$swarm_env_name" in
      SWARM_*|OPENAI_*|ANTHROPIC_*)
        swarm_env_names+=("$swarm_env_name")
        swarm_env_values+=("${!swarm_env_name}")
        ;;
    esac
  done < <(compgen -e)

  [[ $- == *a* ]] && swarm_env_autoexport=1
  set -a
  # shellcheck disable=SC1090
  source "$swarm_env_path"
  for swarm_env_name in "${swarm_env_names[@]}"; do
    printf -v "$swarm_env_name" '%s' "${swarm_env_values[$swarm_env_index]}"
    export "$swarm_env_name"
    swarm_env_index=$((swarm_env_index + 1))
  done
  if [[ $swarm_env_autoexport == 0 ]]; then set +a; fi
}

swarm_load_provider_env
unset -f swarm_load_provider_env
