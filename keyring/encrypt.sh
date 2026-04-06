#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Encrypt data using a KEK (Key Encryption Key) stored in the keyring.
# The KEK is retrieved using get-kek.sh.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_get_kek="${_script_dir}/get-kek.sh"

usage() {
    printf '%s\n' \
      "usage: encrypt.sh [-k|--get-kek SCRIPT] -i|--input FILE" >&2
    printf '%s\n' \
      "                  [-o|--output FILE] [--help]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
      "  -i is required. Use -i - for stdin (same as /dev/stdin)." >&2
    printf '%s\n' \
      "  -o defaults to /dev/null." >&2
    printf '%s\n' \
      "  SCRIPT = path to get-kek.sh (executable). It retrieves the KEK." >&2
    printf '%s\n' \
      "  Default SCRIPT: ${_get_kek}" >&2
}

_get_kek_script=""
_input_file=""
_output_file="/dev/null"

OPTS=$(getopt -o k:i:o:h --long get-kek:,input:,output:,help \
  -n "$(basename "${0}")" -- "${@}")
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

if [[ ${#} -ne 0 ]]; then
    printf '%s\n' "encrypt.sh: unexpected arguments (use -i for input)" >&2
    usage
    exit 1
fi

if [[ -z "${_input_file}" ]]; then
    printf '%s\n' 'encrypt.sh: -i|--input is required (use - for stdin).' >&2
    usage
    exit 1
fi

if [[ "${_input_file}" == "-" ]]; then
    _input_file="/dev/stdin"
fi

if [[ -z "${_get_kek_script}" ]]; then
    _get_kek_script="${_get_kek}"
fi

if [[ ! -x "${_get_kek_script}" ]]; then
    printf '%s\n' "encrypt.sh: get-kek.sh not executable: ${_get_kek_script}" >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' "encrypt.sh: No output file specified. Defaulting to /dev/null." >&2
fi

_kek_file="/dev/shm/keyring-kek-$$"
trap 'rm -f "${_kek_file}"' EXIT

if ! "${_get_kek_script}" -o "${_kek_file}"; then
    printf '%s\n' "encrypt.sh: get-kek.sh failed" >&2
    exit 1
fi

openssl enc -aes-256-cbc -salt -in "${_input_file}" -out "${_output_file}" \
    -pass file:"${_kek_file}"
printf '%s\n' "Encrypted (input) to ${_output_file}"
