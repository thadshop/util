#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Decrypt data using a KEK (Key Encryption Key) stored in the keyring.
# The KEK is retrieved using get-kek.sh.
# Default: plaintext goes to /dev/null (verify decrypt without exposing data).
# Use -o /dev/stdout or -o FILE when you need the cleartext.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_get_kek="${_script_dir}/get-kek.sh"

usage() {
    printf '%s\n' \
      "usage: decrypt.sh [-k|--get-kek SCRIPT] -i|--input FILE" >&2
    printf '%s\n' \
      "                  [-o|--output FILE] [--help]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
      "  -i is required. Use -i - for stdin (same as /dev/stdin)." >&2
    printf '%s\n' \
      "  Input must be ciphertext from encrypt.sh (openssl enc), not sops." >&2
    printf '%s\n' \
      "  -o defaults to /dev/null (no cleartext on terminal)." >&2
    printf '%s\n' \
      "  Use -o /dev/stdout or -o FILE to capture plaintext." >&2
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
    printf '%s\n' "decrypt.sh: unexpected arguments (use -i for input)" >&2
    usage
    exit 1
fi

if [[ -z "${_input_file}" ]]; then
    printf '%s\n' 'decrypt.sh: -i|--input is required (use - for stdin).' >&2
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
    printf '%s\n' "decrypt.sh: get-kek.sh not executable: ${_get_kek_script}" >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' \
      "decrypt.sh: plaintext sent to /dev/null by default." \
      " To get output, specify -o <file> or -o /dev/stdout." >&2
fi

_kek_file="/dev/shm/keyring-kek-$$"
_openssl_err="/dev/shm/keyring-decrypt-openssl-$$"
trap 'rm -f "${_kek_file}" "${_openssl_err}"' EXIT

if ! "${_get_kek_script}" -o "${_kek_file}"; then
    printf '%s\n' "decrypt.sh: get-kek.sh failed" >&2
    exit 1
fi

if ! openssl enc -d -aes-256-cbc -in "${_input_file}" \
    -out "${_output_file}" -pass file:"${_kek_file}" 2>"${_openssl_err}"; then
    if [[ -s "${_openssl_err}" ]]; then
        cat "${_openssl_err}" >&2
    fi
    printf '%s\n' '' >&2
    printf '%s\n' 'decrypt.sh: OpenSSL decryption failed.' >&2
    printf '%s\n' 'Common causes:' >&2
    printf '%s\n' \
        '  - Input is not openssl AES-256-CBC ciphertext from encrypt.sh' >&2
    printf '%s\n' \
        '    (e.g. "bad magic number" means wrong file format).' >&2
    printf '%s\n' \
        '  - File is sops-encrypted (e.g. YAML): use with-sops-dek.sh and' >&2
    printf '%s\n' \
        '    sops decrypt, or secconfig/scripts/decrypt-config.sh.' >&2
    printf '%s\n' \
        '  - Wrong KEK, corrupt file, or wrong -i path.' >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' 'decrypt.sh: decryption OK (plaintext discarded).' >&2
else
    printf '%s\n' "decrypt.sh: wrote plaintext to ${_output_file}" >&2
fi
