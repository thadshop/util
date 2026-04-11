#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Output the decrypted DEK to a destination you choose (-o/--output).
# Default is /dev/null (no accidental leak). Use -o /dev/stdout to pipe or
# capture; use -o FILE for a path (e.g. /dev/shm/...).
# Exit 1 on failure; errors to stderr.
#
# Requires: dek.encrypted to exist (create via rotate-kek.sh when no
# DEK exists yet).

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
_dek_file="${_script_dir}/dek.encrypted"
# shellcheck source=lib.bash
source "${_script_dir}/lib.bash"

if ! keyring_no_debug; then
    printf '%s\n' "keyring: ${_script_path}: refused (debug mode enabled)" >&2
    exit 1
fi
if ! keyring_check_keyring; then
    printf '%s\n' "keyring: ${_script_path}: failed (keyring unavailable)" >&2
    exit 1
fi

kek=$(keyring_get_kek)
if [[ -z "${kek}" ]]; then
    printf '%s\n' "keyring: ${_script_path}: failed (KEK not in keyring)" >&2
    printf '%s\n' "keyring: to initialize: source ${_script_dir}/init.bash" >&2
    exit 1
fi

if [[ ! -f "${_dek_file}" ]]; then
    printf '%s\n' "keyring: ${_script_path}: failed (DEK file not found)" >&2
    printf '%s\n' "keyring: expected at ${_dek_file}" >&2
    printf '%s\n' "keyring: to create: ${_script_dir}/rotate-kek.sh" >&2
    kek=''
    exit 1
fi

output_file="/dev/null"

OPTS=$(getopt -o o: --long output: -n "$(basename "${0}")" -- "${@}")
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
    printf '%s\n' \
      "keyring: ${_script_path}: output sent to /dev/null by default." \
      " To get output, specify -o <file> or -o /dev/stdout." >&2
fi

if ! keyring_decrypt_dek_with_kek "${kek}" "${_dek_file}" "${output_file}"; then
    printf '%s\n' "keyring: ${_script_path}: failed (decrypt)" >&2
    printf '%s\n' 'keyring: wrong KEK or corrupted file' >&2
    kek=''
    exit 1
fi
kek=''
