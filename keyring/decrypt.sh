#!/usr/bin/env bash
# Decrypt data using a KEK (Key Encryption Key) stored in the keyring.
# The KEK is retrieved using get-kek.sh.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_get_kek="${_script_dir}/get-kek.sh"

usage() {
    printf '%s\n' \
        "usage: decrypt.sh [-k|--get-kek SCRIPT] [-i|--input FILE] [-o|--output FILE] [--help]" >&2
    printf '%s\n' \
        "  SCRIPT = path to get-kek.sh (executable). It retrieves the KEK." >&2
    printf '%s\n' \
        "  FILE = input/output file for the data. Defaults: /dev/stdin and /dev/stdout." >&2
    printf '%s\n' \
        "  Default SCRIPT: ${_get_kek}" >&2
}

_get_kek_script=""
_input_file="/dev/stdin"
_output_file="/dev/stdout"

OPTS=$(getopt -o k:i:o:h --long get-kek:,input:,output:,help -n $(basename "${0}") -- "${@}")
if [[ ${?} != 0 ]]; then
    printf '%s\n' "Failed parsing options." >&2
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -k|--get-kek)
            _get_kek_script="${2}"
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

if [[ -z "${_get_kek_script}" ]]; then
    _get_kek_script="${_get_kek}"
fi

if [[ ! -x "${_get_kek_script}" ]]; then
    printf '%s\n' "decrypt.sh: get-kek.sh not executable: ${_get_kek_script}" >&2
    exit 1
fi

_kek_file="/dev/shm/keyring-kek-$$"
trap 'rm -f "${_kek_file}"' EXIT

if ! "${_get_kek_script}" -o "${_kek_file}"; then
    printf '%s\n' "decrypt.sh: get-kek.sh failed" >&2
    exit 1
fi

openssl enc -d -aes-256-cbc -in "${_input_file}" -out "${_output_file}" -pass file:"${_kek_file}"
printf '%s\n' "Decrypted ${_input_file} to ${_output_file}"