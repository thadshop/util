#!/usr/bin/env bash
# Output the KEK to stdout. Usable from Bash or Python.
# Exit 1 on failure; errors to stderr.
#
# Bash: kek=$(get-kek.sh) || { printf '%s\n' 'failed'; exit 1; }
# Python: subprocess.run(["./get-kek.sh"], capture_output=True, text=True)

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
# shellcheck source=lib.sh
source "${_script_dir}/lib.sh"

if ! secrets_get_kek; then
    printf '%s\n' "secrets: ${_script_path}: failed" >&2
    printf '%s\n' "secrets: to initialize: source ${_script_dir}/init.sh" >&2
    printf '%s\n' 'secrets: or open a new terminal '\
      '(if init.sh is in your profile)' >&2
    exit 1
fi
