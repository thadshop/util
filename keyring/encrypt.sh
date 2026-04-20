#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Encrypt a file to the age DEK recipient.
# The recipient public key is retrieved using get-age-public-key.sh.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_default_get_pub="${_script_dir}/get-age-public-key.sh"
_get_pub="${_default_get_pub}"
_input_file=""
_output_file="/dev/null"

usage() {
    printf '%s\n' \
        "usage: encrypt.sh [-k|--get-pub SCRIPT] -i|--input FILE" >&2
    printf '%s\n' \
        "                  [-o|--output FILE] [--help]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  -i is required. Use -i - for stdin (same as /dev/stdin)." \
        >&2
    printf '%s\n' "  -o defaults to /dev/null." >&2
    printf '%s\n' \
        "  SCRIPT retrieves the age public key" \
        "  (default: ${_default_get_pub})." >&2
}

if ! OPTS=$(getopt -o k:i:o:h --long get-pub:,input:,output:,help \
    -n "$(basename "${0}")" -- "${@}"); then
    printf '%s\n' "Failed parsing options." >&2
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -k|--get-pub)
            _get_pub="${2}"
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
        "encrypt.sh: unexpected arguments (use -i for input)" >&2
    usage
    exit 1
fi

if [[ -z "${_input_file}" ]]; then
    printf '%s\n' \
        'encrypt.sh: -i|--input is required (use - for stdin).' >&2
    usage
    exit 1
fi

if [[ "${_input_file}" == "-" ]]; then
    _input_file="/dev/stdin"
fi

if [[ ! -x "${_get_pub}" ]]; then
    printf '%s\n' "encrypt.sh: not executable: ${_get_pub}" >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' \
        "encrypt.sh: no output file specified; defaulting to /dev/null." \
        >&2
fi

_pub_key="$("${_get_pub}")"
if [[ -z "${_pub_key}" ]]; then
    printf '%s\n' "encrypt.sh: failed to get age public key" >&2
    exit 1
fi

age -r "${_pub_key}" -o "${_output_file}" "${_input_file}"
printf '%s\n' "Encrypted (input) to ${_output_file}"
