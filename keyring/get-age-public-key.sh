#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Print the age *public* key (recipient) for the DEK stored in dek.encrypted.
# Use for .sops.yaml "age:" and sharing only the public line (age1...).
# Private key bytes exist only briefly in a chmod 600 file under /dev/shm.
#
# Requires: get-dek.sh prerequisites, age-keygen on PATH.
# Use: get-age-public-key.sh [--help]

set -e

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
_get_dek="${_script_dir}/get-dek.sh"

# shellcheck source=lib.bash
source "${_script_dir}/lib.bash"

usage() {
    printf '%s\n' "usage: $(basename "${0}") [--help]" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  Prints one line: the age public key (age1...) for this repo's DEK." \
        >&2
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

if [[ ${#} -gt 0 ]]; then
    printf '%s\n' "$(basename "${0}"): unexpected arguments" >&2
    usage
    exit 1
fi

if ! keyring_no_debug; then
    printf '%s\n' \
        "keyring: $(basename "${0}"): refused (debug mode enabled)" >&2
    exit 1
fi

if ! keyring_check_keyring; then
    printf '%s\n' \
        "keyring: $(basename "${0}"): keyring check failed" >&2
    exit 1
fi

if ! command -v age-keygen >/dev/null 2>&1; then
    printf '%s\n' \
        "$(basename "${0}"): age-keygen not on PATH (e.g. apt install age)" \
        >&2
    exit 1
fi

if [[ ! -x "${_get_dek}" ]]; then
    printf '%s\n' "$(basename "${0}"): not executable: ${_get_dek}" >&2
    exit 1
fi

_tmp="$(mktemp /dev/shm/age-dek-pub.XXXXXX)"
chmod 600 "${_tmp}"
trap 'rm -f "${_tmp}"' EXIT

if ! "${_get_dek}" -o "${_tmp}"; then
    printf '%s\n' "$(basename "${0}"): get-dek.sh failed" >&2
    exit 1
fi

if ! age-keygen -y "${_tmp}"; then
    printf '%s\n' "$(basename "${0}"): age-keygen -y failed" >&2
    exit 1
fi
