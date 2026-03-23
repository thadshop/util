#!/usr/bin/env bash
# Output the decrypted DEK to stdout. Usable from Bash or Python.
# Exit 1 on failure; errors to stderr.
#
# Requires: dek.encrypted to exist (create via rotate-kek.sh when no
# DEK exists yet).

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
_dek_file="${_script_dir}/dek.encrypted"
# shellcheck source=lib.sh
source "${_script_dir}/lib.sh"

if ! secrets_no_debug; then
    printf '%s\n' "secrets: ${_script_path}: refused (debug mode enabled)" >&2
    exit 1
fi
if ! secrets_check_keyring; then
    printf '%s\n' "secrets: ${_script_path}: failed (keyring unavailable)" >&2
    exit 1
fi

kek=$(secrets_get_kek)
if [[ -z "${kek}" ]]; then
    printf '%s\n' "secrets: ${_script_path}: failed (KEK not in keyring)" >&2
    printf '%s\n' "secrets: to initialize: source ${_script_dir}/init.sh" >&2
    exit 1
fi

if [[ ! -f "${_dek_file}" ]]; then
    printf '%s\n' "secrets: ${_script_path}: failed (DEK file not found)" >&2
    printf '%s\n' "secrets: expected at ${_dek_file}" >&2
    printf '%s\n' "secrets: to create: ${_script_dir}/rotate-kek.sh" >&2
    kek=''
    exit 1
fi

output_file="/dev/null"

# Parse options using getopt for both short and long option names
OPTS=$(getopt -o o: --long output: -n $(basename "${0}") -- "${@}")
if [[ ${?} != 0 ]]; then
    printf '%s\n' "Failed parsing options." >&2
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -o|--output)
            output_file="${2}"
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            printf '%s\n' "Invalid option: ${1}" >&2
            exit 1
            ;;
    esac
done

if [[ "${output_file}" == "/dev/null" ]]; then
    printf '%s\n' "secrets: ${_script_path}: output sent to /dev/null by default. Specify -o <file> to save output, or -o /dev/stdout for stdout." >&2
fi

if ! openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass file:<(printf '%s' "${kek}") -in "${_dek_file}" > "${output_file}" 2>/dev/null; then
    printf '%s\n' "secrets: ${_script_path}: failed (decrypt)" >&2
    printf '%s\n' 'secrets: wrong KEK or corrupted file' >&2
    kek=''
    exit 1
fi
kek=''
