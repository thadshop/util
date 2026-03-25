#!/usr/bin/env bash
# Decrypt a sops-encrypted YAML under SECCONFIG_DIR.
# DEK / sops env: keyring/with-sops-dek.sh (hard dependency on util checkout).
# Default: decrypted YAML goes to /dev/null (verify only). Use -o to capture.

set -e

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_keyring_dir="$(cd "${_script_dir}/../../keyring" && pwd)"
_default_get_dek_script="${_keyring_dir}/get-dek.sh"
_with_sops_dek="${_keyring_dir}/with-sops-dek.sh"

usage() {
    printf '%s\n' \
      "usage: decrypt-config.sh [-k|--get-dek SCRIPT] -i|--input FILE" >&2
    printf '%s\n' \
      "                         [-o|--output FILE] [--help]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
      "  -i is required. Sops file: path relative to \$SECCONFIG_DIR, absolute" \
      >&2
    printf '%s\n' \
      "  under that tree, or - / /dev/stdin (spooled to /dev/shm for sops)." >&2
    printf '%s\n' \
      "  Example: decrypt-config.sh -i copy-of-test.enc.yaml -o /dev/stdout" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
      "  SCRIPT = path to get-dek.sh (passed to keyring/with-sops-dek.sh)." \
      >&2
    printf '%s\n' \
      "  Default output: /dev/null. Use -o /dev/stdout or -o FILE for YAML." >&2
    printf '%s\n' \
      "  SECCONFIG_DIR must name your config root (optional .sops.yaml)." >&2
    printf '%s\n' \
      "  Default SCRIPT: ${_default_get_dek_script}" >&2
}

_get_dek_script=""
_in=""
_output_file="/dev/null"
_stdin_tmp=""

OPTS=$(getopt -o k:i:o:h --long get-dek:,input:,output:,help \
  -n "$(basename "${0}")" -- "${@}")
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
        -i|--input)
            _in="${2}"
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
        "decrypt-config: unexpected arguments (use -i for input)" >&2
    usage
    exit 1
fi

if [[ -z "${_in}" ]]; then
    printf '%s\n' \
        'decrypt-config: -i|--input is required (use - for stdin).' >&2
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

if [[ ! -x "${_with_sops_dek}" ]]; then
    printf '%s\n' \
      "decrypt-config: with-sops-dek.sh not executable: ${_with_sops_dek}" >&2
    exit 1
fi

_root="$(cd "${SECCONFIG_DIR}" && pwd)"
_sops_cfg="${_root}/.sops.yaml"

trap 'rm -f "${_stdin_tmp}"' EXIT

if [[ "${_in}" == "-" ]] || [[ "${_in}" == "/dev/stdin" ]]; then
    _stdin_tmp="$(mktemp /dev/shm/decrypt-config-in.XXXXXX.yaml)"
    chmod 600 "${_stdin_tmp}"
    cat > "${_stdin_tmp}"
    _in="${_stdin_tmp}"
elif [[ "${_in}" != /* ]]; then
    _in="${_root}/${_in}"
fi

_in="$(cd "$(dirname "${_in}")" && pwd)/$(basename "${_in}")"

if [[ -z "${_stdin_tmp}" ]]; then
    if [[ "${_in}" != "${_root}"/* ]]; then
        printf '%s\n' 'decrypt-config: file must be under SECCONFIG_DIR' >&2
        exit 1
    fi
fi

if [[ ! -f "${_in}" ]]; then
    printf '%s\n' "decrypt-config: not a file: ${_in}" >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' \
      'decrypt-config: decrypted YAML sent to /dev/null by default.' \
      ' Use -o /dev/stdout or -o FILE to capture.' >&2
elif [[ "${_output_file}" == "/dev/stdout" ]] && [[ -t 1 ]]; then
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
else
    _out_dir="$(dirname "${_output_file}")"
    if [[ ! -d "${_out_dir}" ]]; then
        printf '%s\n' \
          "decrypt-config: output directory missing: ${_out_dir}" >&2
        exit 1
    fi
    if [[ ! -w "${_out_dir}" ]]; then
        printf '%s\n' \
          "decrypt-config: output directory not writable: ${_out_dir}" >&2
        exit 1
    fi
fi

_wsdc=(-k "${_get_dek_script}")
if [[ -f "${_sops_cfg}" ]]; then
    _wsdc+=(-c "${_sops_cfg}")
fi

if ! "${_with_sops_dek}" "${_wsdc[@]}" -- \
    sops decrypt --output "${_output_file}" "${_in}"; then
    printf '%s\n' 'decrypt-config: sops decrypt failed' >&2
    exit 1
fi

if [[ "${_output_file}" == "/dev/null" ]]; then
    printf '%s\n' 'decrypt-config: decryption OK (YAML discarded).' >&2
fi
