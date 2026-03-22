#!/usr/bin/env bash
# Decrypt a sops YAML under SECCONFIG_DIR and write cleartext YAML to stdout.
# Runs get-dek.sh into a /dev/shm file and sets SOPS_AGE_KEY_FILE (same idea
# as secconfig's Python loader). sops may read that file more than once, so
# piping the key or SOPS_AGE_KEY_FILE=/dev/stdin is not reliable.
#
# Optional: set the private key without a temp file using SOPS_AGE_KEY (sops
# reads the env var); that keeps the DEK in the environment — avoid if
# untrusted users can read process environments.
#
# Usage:
#   export SECCONFIG_DIR=/path/to/config
#   decrypt-config.sh [--get-dek /path/to/get-dek.sh] path/to/file.enc.yaml
#
# --get-dek / -k: path to the get-dek.sh executable (not a file containing
# the key). That script prints the DEK to stdout; this wrapper captures it.
#
# Path may be relative to SECCONFIG_DIR or absolute (must stay under it).
# After checks, prompts on stderr: cleartext warning; only "y" proceeds
# (default N).

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_default_get_dek_script="${_script_dir}/../../keyring/get-dek.sh"

usage() {
    printf '%s\n' \
      "usage: decrypt-config.sh [-k|--get-dek SCRIPT] [--help] <file.enc.yaml>" \
      >&2
    printf '%s\n' \
      "  SCRIPT = path to get-dek.sh (executable). It prints the DEK; not a" \
      >&2
    printf '%s\n' "  key-on-disk file." >&2
    printf '%s\n' \
      "  SECCONFIG_DIR must name your config root (optional .sops.yaml)." \
      >&2
    printf '%s\n' \
      "  Default SCRIPT: ${_default_get_dek_script}" >&2
    printf '%s\n' \
      "  Override: -k, --get-dek, or GET_DEK_PATH (same: path to script)." >&2
}

_get_dek_script=""
while [[ ${#} -gt 0 ]]; do
    case ${1} in
        -k|--get-dek)
            if [[ ${#} -lt 2 ]] || [[ "${2}" == -* ]]; then
                printf '%s\n' \
                  'decrypt-config: -k/--get-dek requires path to get-dek.sh' \
                  >&2
                exit 1
            fi
            _get_dek_script="${2}"
            shift 2
            ;;
        --get-dek=*)
            _get_dek_script="${1#*=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        -*)
            printf '%s\n' "decrypt-config: unknown option: ${1}" >&2
            usage
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ ${#} -ne 1 ]]; then
    usage
    exit 1
fi

if [[ -z "${SECCONFIG_DIR:-}" ]]; then
    printf '%s\n' 'decrypt-config: SECCONFIG_DIR is not set or empty' >&2
    exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
    printf '%s\n' 'decrypt-config: sops not in PATH' >&2
    exit 1
fi

if [[ -z "${_get_dek_script}" ]]; then
    _get_dek_script="${GET_DEK_PATH:-${_default_get_dek_script}}"
fi

if [[ ! -x "${_get_dek_script}" ]]; then
    printf '%s\n' \
      "decrypt-config: get-dek.sh not executable: ${_get_dek_script}" >&2
    exit 1
fi

_root="$(cd "${SECCONFIG_DIR}" && pwd)"
_sops_cfg="${_root}/.sops.yaml"

_in="${1}"
if [[ "${_in}" != /* ]]; then
    _in="${_root}/${_in}"
fi

if [[ ! -f "${_in}" ]]; then
    printf '%s\n' "decrypt-config: not a file: ${_in}" >&2
    exit 1
fi

_in="$(cd "$(dirname "${_in}")" && pwd)/$(basename "${_in}")"

if [[ "${_in}" != "${_root}"/* ]]; then
    printf '%s\n' 'decrypt-config: file must be under SECCONFIG_DIR' >&2
    exit 1
fi

printf '%s\n' '' >&2
printf '%s\n' \
  'decrypt-config: decrypted YAML will be printed to stdout in CLEARTEXT.' \
  >&2
printf '%s\n' \
  '  Secrets may appear in terminal scrollback, logs, or downstream pipes.' \
  >&2
printf '%s\n' '' >&2
printf '%s' 'Proceed? [y/N] ' >&2
read -r _reply
if [[ "${_reply}" != y ]]; then
    printf '%s\n' 'decrypt-config: cancelled' >&2
    exit 1
fi

_key_file="/dev/shm/secconfig-decrypt-key-$$"
trap 'rm -f "${_key_file}" 2>/dev/null' EXIT

if ! "${_get_dek_script}" > "${_key_file}"; then
    printf '%s\n' 'decrypt-config: get-dek.sh failed' >&2
    exit 1
fi
chmod 600 "${_key_file}"

unset SOPS_AGE_KEY 2>/dev/null || true
export SOPS_AGE_KEY_FILE="${_key_file}"
if [[ -f "${_sops_cfg}" ]]; then
    export SOPS_CONFIG="${_sops_cfg}"
fi

sops decrypt "${_in}"
