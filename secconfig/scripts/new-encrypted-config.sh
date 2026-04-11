#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Interactive sops workflow: start from empty plaintext in /dev/shm; edit;
# encrypt to a new path. With SECCONFIG_DIR: directory list (and per-dir file
# hints), then basename, or full path. Shared: .work-encrypted-config.bash
# To change an existing ciphertext: edit-encrypted-config.sh
#
# Use: new-encrypted-config.sh [-k|--get-dek SCRIPT]
#                               [-c|--sops-config FILE] [-h|--help]

set -e

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"

export EEC_MSG_PREFIX="new-encrypted-config"
# shellcheck source=.work-encrypted-config.bash
source "${_script_dir}/.work-encrypted-config.bash"

wek_new "${@}"
