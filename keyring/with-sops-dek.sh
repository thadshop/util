#!/usr/bin/env bash
# Run a command with the age DEK from get-dek.sh exported as SOPS_AGE_KEY_FILE.
# Cleartext DEK file lives under /dev/shm and is removed on exit.
# Callers (e.g. secconfig/scripts/decrypt-config.sh) keep path validation local
# and delegate DEK + sops env setup here.

set -e

# Directory containing this script and default get-dek.sh
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_default_get_dek="${_script_dir}/get-dek.sh"

usage() {
    printf '%s\n' \
        "usage: with-sops-dek.sh [-k|--get-dek SCRIPT] [-c|--sops-config FILE]" \
        >&2
    printf '%s\n' \
        "                        [-h|--help] -- <command> [arg ...]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  Sets SOPS_AGE_KEY_FILE from get-dek (-o temp under /dev/shm)." >&2
    printf '%s\n' \
        "  With -c, sets SOPS_CONFIG (file must exist)." >&2
    printf '%s\n' \
        "  Default SCRIPT: ${_default_get_dek}" >&2
    printf '%s\n' "  Example:" >&2
    printf '%s\n' \
        "    with-sops-dek.sh -c /app/.sops.yaml -- \\" >&2
    printf '%s\n' \
        "      sops decrypt --output /dev/null encrypted.yaml" >&2
}

_get_dek="${_default_get_dek}"
_sops_cfg=""

while [[ ${#} -gt 0 ]]; do
    case "${1}" in
        -k|--get-dek)
            if [[ ${#} -lt 2 ]]; then
                printf '%s\n' 'with-sops-dek: -k needs an argument' >&2
                exit 1
            fi
            _get_dek="${2}"
            shift 2
            ;;
        -c|--sops-config)
            if [[ ${#} -lt 2 ]]; then
                printf '%s\n' 'with-sops-dek: -c needs an argument' >&2
                exit 1
            fi
            _sops_cfg="${2}"
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
            printf '%s\n' "with-sops-dek: unexpected argument: ${1}" >&2
            printf '%s\n' '  (use -- before the command)' >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ${#} -lt 1 ]]; then
    printf '%s\n' 'with-sops-dek: need a command after options (-- CMD ...)' >&2
    usage
    exit 1
fi

if ! command -v sops >/dev/null 2>&1; then
    printf '%s\n' 'with-sops-dek: sops not in PATH' >&2
    exit 1
fi

if [[ ! -d /dev/shm ]]; then
    printf '%s\n' 'with-sops-dek: /dev/shm not found' >&2
    exit 1
fi

if [[ ! -x "${_get_dek}" ]]; then
    printf '%s\n' \
        "with-sops-dek: get-dek not executable: ${_get_dek}" >&2
    exit 1
fi

if [[ -n "${_sops_cfg}" ]]; then
    if [[ ! -f "${_sops_cfg}" ]]; then
        printf '%s\n' \
            "with-sops-dek: sops config not a file: ${_sops_cfg}" >&2
        exit 1
    fi
    _sops_cfg="$(cd "$(dirname "${_sops_cfg}")" && pwd)/$(basename "${_sops_cfg}")"
fi

_key_file="/dev/shm/keyring-sops-dek-$$"
trap 'rm -f "${_key_file}" 2>/dev/null' EXIT

if ! "${_get_dek}" -o "${_key_file}"; then
    printf '%s\n' 'with-sops-dek: get-dek.sh failed' >&2
    exit 1
fi
chmod 600 "${_key_file}"

unset SOPS_AGE_KEY 2>/dev/null || true
export SOPS_AGE_KEY_FILE="${_key_file}"
if [[ -n "${_sops_cfg}" ]]; then
    export SOPS_CONFIG="${_sops_cfg}"
fi

"$@"
_st=${?}
exit "${_st}"
