#!/usr/bin/env bash
# Test that decryption will work (KEK in keyring, DEK decrypts,
# secrets-test.enc when present).
# Exit 0 if OK; exit 1 with error message if not.

_script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=lib.sh
source "${_script_dir}/lib.sh"

if ! secrets_test_decryption; then
    printf '%s\n' 'secrets: decryption test failed' >&2
    exit 1
fi

printf '%s\n' 'secrets: decryption test passed' >&2
exit 0
