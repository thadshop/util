#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Decrypt a file encrypted by encrypt.sh (age).
# Default: plaintext goes to /dev/null (verify without exposing data).
# Use -o /dev/stdout or -o FILE when you need the cleartext.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_default_get_dek="${_script_dir}/get-dek.sh"
_get_dek="${_default_get_dek}"
_input_file=""
_output_file="/dev/null"

usage() {
    printf '%s\n' \
        "usage: decrypt.sh [-k|--get-dek SCRIPT] -i|--input FILE" >&2
    printf '%s\n' \
        "                  [-o|--output FILE] [--help]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  -i is required. Use -i - for stdin (same as /dev/stdin)." \
        >&2
    printf '%s\n' \
        "  Input must be age ciphertext from encrypt.sh, not sops." >&2
    printf '%s\n' \
        "  -o defaults to /dev/null (no cleartext on terminal)." >&2
    printf '%s\n' \
        "  Use -o /dev/stdout or -o FILE to capture plaintext." >&2
    printf '%s\n' \
        "  SCRIPT retrieves the DEK" \
        "  (default: ${_default_get_dek})." >&2
}

if ! OPTS=$(getopt -o k:i:o:h --long get-dek:,input:,output:,help \
    -n "$(basename "${0}")" -- "${@}"); then
    printf '%s\n' "Failed parsing options." >&2
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -k|--get-dek)
            _get_dek="${2}"
            shift 2
            ;;
        -i|--input)
            _input_file="${2}"
            shift 2
            ;;
        -o|--output)
            _output_file="${2}"
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

if [[ ${#} -ne 0 ]]; then
    printf '%s\n' \
        "decrypt.sh: unexpected arguments (use -i for input)" >&2
    usage
    exit 1
fi

if [[ -z "${_input_file}" ]]; then
    printf '%s\n' \
        'decrypt.sh: -i|--input is required (use - for stdin).' >&2
    usage
    exit 1
fi

if [[ "${_input_file}" == "-" ]]; then
    _input_file="/dev/stdin"
fi

if [[ ! -x "${_get_dek}" ]]; then
    printf '%s\n' "decrypt.sh: get-dek not executable: ${_get_dek}" >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' \
        "decrypt.sh: plaintext sent to /dev/null by default." \
        " To get output, specify -o <file> or -o /dev/stdout." >&2
fi

_dek_tmp="$(mktemp /dev/shm/keyring-decrypt-dek.XXXXXX)"
chmod 600 "${_dek_tmp}"
trap 'rm -f "${_dek_tmp}"' EXIT

if ! "${_get_dek}" -o "${_dek_tmp}"; then
    printf '%s\n' "decrypt.sh: get-dek.sh failed" >&2
    exit 1
fi

if ! age -d -i "${_dek_tmp}" -o "${_output_file}" "${_input_file}"; then
    printf '%s\n' '' >&2
    printf '%s\n' 'decrypt.sh: age decryption failed.' >&2
    printf '%s\n' 'Common causes:' >&2
    printf '%s\n' \
        '  - Input is not age ciphertext from encrypt.sh.' >&2
    printf '%s\n' \
        '  - File was encrypted to a different DEK.' >&2
    printf '%s\n' \
        '  - For sops files use with-sops-dek.sh and sops decrypt,' >&2
    printf '%s\n' \
        '    or secconfig/scripts/decrypt-config.sh.' >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' 'decrypt.sh: decryption OK (plaintext discarded).' >&2
else
    printf '%s\n' \
        "decrypt.sh: wrote plaintext to ${_output_file}" >&2
fi
