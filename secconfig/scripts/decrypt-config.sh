#!/usr/bin/env bash
# This script decrypts a sops-encrypted YAML file under SECCONFIG_DIR.
# It uses get-dek.sh to retrieve the DEK (Data Encryption Key),
# which is stored temporarily in /dev/shm for security.
# The SOPS_AGE_KEY_FILE environment variable is set to point to the DEK.
# The decrypted YAML is printed to stdout in cleartext.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_default_get_dek_script="${_script_dir}/../../keyring/get-dek.sh"

usage() {
    printf '%s\n' \
        "usage: decrypt-config.sh [-k|--get-dek SCRIPT] [--help] <file.enc.yaml>" >&2
    printf '%s\n' \
        "  SCRIPT = path to get-dek.sh (executable). It prints the DEK." >&2
    printf '%s\n' \
        "  SECCONFIG_DIR must name your config root (optional .sops.yaml)." >&2
    printf '%s\n' \
        "  Default SCRIPT: ${_default_get_dek_script}" >&2
}

_get_dek_script=""
# Parse options using getopt for both short and long option names
OPTS=$(getopt -o k:h --long get-dek:,help -n $(basename "${0}") -- "${@}")
if [[ ${?} != 0 ]]; then
    printf '%s\n' "Failed parsing options." >&2
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -k|--get-dek)
            _get_dek_script="${2}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            break
            ;;
        *)
            printf '%s\n' "Invalid option: ${1}" >&2
            usage
            exit 1
            ;;
    esac
done

shift $((OPTIND -1))

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
