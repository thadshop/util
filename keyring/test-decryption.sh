#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Test that decryption will work (KEK in keyring, DEK decrypts,
# keyring-test.enc when present).
# Exit 0 if OK; exit 1 with error message if not.

_script_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=lib.bash
source "${_script_dir}/lib.bash"

if ! keyring_test_decryption; then
    printf '%s\n' 'keyring: decryption test failed' >&2
    exit 1
fi

printf '%s\n' 'keyring: decryption test passed' >&2
exit 0
