#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Interactive sops workflow: decrypt/edit/re-encrypt one file. Cleartext only
# in /dev/shm. Shared implementation: .work-encrypted-config.bash
# To create a new encrypted file from scratch: new-encrypted-config.sh
#
# Use: edit-encrypted-config.sh [-k|--get-dek SCRIPT]
#                                [-c|--sops-config FILE] [-h|--help]
#                                [ENCRYPTED_FILE]
#
# With no ENCRYPTED_FILE: list under $SECCONFIG_DIR when possible, else path
# prompt; reads /dev/tty or stdin. Empty input aborts.

set -e

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"

export WE_MSG_PREFIX="edit-encrypted-config"
# shellcheck source=.work-encrypted-config.bash
source "${_script_dir}/.work-encrypted-config.bash"

wek_edit "${@}"
