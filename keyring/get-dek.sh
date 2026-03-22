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

if ! openssl enc -d -aes-256-cbc -pbkdf2 \
  -pass file:<(printf '%s' "${kek}") -in "${_dek_file}" 2>/dev/null; then
    printf '%s\n' "secrets: ${_script_path}: failed (decrypt)" >&2
    printf '%s\n' 'secrets: wrong KEK or corrupted file' >&2
    kek=''
    exit 1
fi
kek=''
