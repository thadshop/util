#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Interactive workflow: start from empty file in /dev/shm; edit;
# encrypt with encrypt.sh (age, DEK recipient) to a new path.
# With SECCONFIG_DIR: directory list (and per-dir file hints), then
# basename, or full path. Shared: .work-encrypted.bash
# To change an existing ciphertext: edit-encrypted.sh
#
# Use: new-encrypted.sh [-k|--get-kek SCRIPT] [-h|--help]

set -e

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"

export WE_MSG_PREFIX="new-encrypted"
# shellcheck source=.work-encrypted.bash
source "${_script_dir}/.work-encrypted.bash"

we_new "${@}"
