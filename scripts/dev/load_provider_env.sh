#!/usr/bin/env bash
# Sourced by the launchers (and copied into the release as bin/load_provider_env.sh).
# Never print or persist private settings.
#
# pass70 B4 (rel F5): only provider variables leave the environment file. The
# file is evaluated in a clean child shell and just SWARM_*, NCODE_*, OPENAI_*,
# ANTHROPIC_* and LLMOTIONS_* come back, so a GitHub, npm or Linear token in
# ~/.secrets never reaches the BEAM, and therefore never a model-run shell
# command. SWARM_MODEL_OVERRIDE is set only by `ncode --model` and is never
# loaded (nor is NCODE_MODEL_OVERRIDE).
#
# ncode: NCODE_* first, SWARM_* as the fallback. The release reads only the
# SWARM_* names, so an exported NCODE_X is copied over SWARM_X first (bin/ncode
# has already done this for the release; the dev launchers source this file
# directly), and inside the child shell a file's NCODE_X is copied over its
# SWARM_X. Shell exports still win over the file. The list is the launcher's
# (rel/overlays/bin/ncode); keep them in step.
swarm_load_provider_env() {
  local swarm_ncode_pairs="MODEL:MODEL BASE_URL:BASE_URL API_KEY:API_KEY PROVIDER:PROVIDER
    EFFORT:EFFORT CONVERSATION:CONVERSATION KEYMAP:KEYMAP ASCII:ASCII COMPANION:COMPANION
    THEME:THEME MOUSE:MOUSE APPROVAL:APPROVAL ENV_FILE:ENV_FILE
    CONFIG_DIR:CODE_CONFIG_DIR SHELL:CODE_SHELL"
  local swarm_ncode_pair swarm_ncode_name
  for swarm_ncode_pair in $swarm_ncode_pairs; do
    swarm_ncode_name="NCODE_${swarm_ncode_pair%%:*}"
    if [[ -n ${!swarm_ncode_name+x} ]]; then
      export "SWARM_${swarm_ncode_pair#*:}=${!swarm_ncode_name}"
    fi
  done

  # Presence matters: an explicitly empty key selects unauthenticated local APIs.
  if [[ ${SWARM_API_KEY+x} || ${OPENAI_API_KEY+x} || ${ANTHROPIC_API_KEY+x} ]]; then
    return 0
  fi

  local swarm_env_path="${SWARM_ENV_FILE:-${HOME}/.secrets}"
  if [[ ! -f "$swarm_env_path" ]]; then
    if [[ -n ${SWARM_ENV_FILE:-} ]]; then
      echo 'NCODE_ENV_FILE (or SWARM_ENV_FILE) must point to an existing environment file.' >&2
      return 1
    fi
    return 0
  fi

  local swarm_env_name swarm_env_value
  # Shell exports win over the file: only unset names are taken from it.
  while IFS= read -r -d '' swarm_env_name && IFS= read -r -d '' swarm_env_value; do
    case "$swarm_env_name" in
      SWARM_MODEL_OVERRIDE | NCODE_MODEL_OVERRIDE) continue ;;
      SWARM_* | NCODE_* | OPENAI_* | ANTHROPIC_* | LLMOTIONS_*) ;;
      *) continue ;;
    esac
    [[ $swarm_env_name =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    if [[ -z ${!swarm_env_name+x} ]]; then
      printf -v "$swarm_env_name" '%s' "$swarm_env_value"
      export "$swarm_env_name"
    fi
  done < <(
    env -i HOME="$HOME" PATH="$PATH" bash --noprofile --norc -c '
      pairs=$2
      set -a
      # shellcheck disable=SC1090
      source "$1" >/dev/null 2>&1 </dev/null
      for pair in $pairs; do
        ncode="NCODE_${pair%%:*}"
        if [[ -n ${!ncode+x} ]]; then export "SWARM_${pair#*:}=${!ncode}"; fi
      done
      for name in $(compgen -e); do
        case "$name" in
          SWARM_*|NCODE_*|OPENAI_*|ANTHROPIC_*|LLMOTIONS_*) printf "%s\0%s\0" "$name" "${!name}" ;;
        esac
      done
    ' swarm-env "$swarm_env_path" "$swarm_ncode_pairs"
  )
}

swarm_load_provider_env
unset -f swarm_load_provider_env
