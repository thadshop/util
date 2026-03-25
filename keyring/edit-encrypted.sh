#!/usr/bin/env bash
# Interactive workflow: cleartext only in /dev/shm; encrypt with encrypt.sh
# (OpenSSL + KEK). For sops/secconfig, use secconfig/scripts/edit-encrypted-config.sh.
# Use: edit-encrypted.sh [options] new | edit ENCRYPTED_FILE
#
# Shared prompts: edit-encrypted-common.sh

set -e

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
# shellcheck source=lib.sh
source "${_script_dir}/lib.sh"

if ! secrets_no_debug; then
    printf '%s\n' "edit-encrypted: refused (xtrace or verbose enabled)" >&2
    exit 1
fi

export EEC_MSG_PREFIX="edit-encrypted"
# shellcheck source=edit-encrypted-common.sh
source "${_script_dir}/edit-encrypted-common.sh"

_encrypt_sh="${_script_dir}/encrypt.sh"
_decrypt_sh="${_script_dir}/decrypt.sh"
_default_get_kek="${_script_dir}/get-kek.sh"
_get_kek="${GET_KEK_PATH:-${_default_get_kek}}"
_plain_file=""
_tmp_encrypted=""

usage() {
    printf '%s\n' \
        "usage: edit-encrypted.sh [-k|--get-kek SCRIPT] [-h|--help]" >&2
    printf '%s\n' \
        "                        new | edit ENCRYPTED_FILE" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  new  — empty plaintext in /dev/shm; edit; encrypt with encrypt.sh." \
        >&2
    printf '%s\n' \
        "  edit — decrypt to /dev/shm; edit; re-encrypt (backup prompts)." >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  GET_KEK_PATH or -k selects get-kek.sh (default: ${_default_get_kek})." \
        >&2
    printf '%s\n' \
        '  For sops/.sops.yaml flows use secconfig/scripts/edit-encrypted-' \
        'config.sh.' >&2
}

cleanup_plain() {
    if [[ -n "${_plain_file}" ]] && [[ -f "${_plain_file}" ]]; then
        rm -f "${_plain_file}"
        printf '%s\n' "Removed plaintext: ${_plain_file}" >&2
    fi
}

cleanup_tmp_enc() {
    if [[ -n "${_tmp_encrypted}" ]] && [[ -f "${_tmp_encrypted}" ]]; then
        rm -f "${_tmp_encrypted}"
    fi
}

trap 'cleanup_plain; cleanup_tmp_enc' EXIT

if ! OPTS=$(getopt -o k:h --long get-kek:,help \
    -n "$(basename "${0}")" -- "${@}"); then
    usage
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -k|--get-kek)
            _get_kek="${2}"
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
            printf '%s\n' "edit-encrypted: invalid option: ${1}" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ ${#} -lt 1 ]]; then
    usage
    exit 1
fi

_subcmd="${1}"
shift

_require_prereqs() {
    eec_require_shm
    if [[ ! -x "${_encrypt_sh}" ]]; then
        printf '%s\n' \
            "edit-encrypted: encrypt.sh not executable: ${_encrypt_sh}" >&2
        exit 1
    fi
    if [[ ! -x "${_decrypt_sh}" ]]; then
        printf '%s\n' \
            "edit-encrypted: decrypt.sh not executable: ${_decrypt_sh}" >&2
        exit 1
    fi
    if [[ ! -x "${_get_kek}" ]]; then
        printf '%s\n' \
            "edit-encrypted: get-kek not executable: ${_get_kek}" >&2
        exit 1
    fi
}

# Temp ciphertext suffix next to final path (keeps extension convention).
_tmp_enc_suffix_from_path() {
    local _base
    _base="$(basename "${1}")"
    case "${_base}" in
        *.enc.yaml) printf '%s' '.enc.yaml' ;;
        *.enc.yml) printf '%s' '.enc.yml' ;;
        *.enc) printf '%s' '.enc' ;;
        *.bin) printf '%s' '.bin' ;;
        *) printf '%s' '.enc' ;;
    esac
}

_encrypt_validate_install() {
    local _plain_in="${1}"
    local _final="${2}"
    local _dir _suf
    _dir="$(cd "$(dirname "${_final}")" && pwd)"
    _suf="$(_tmp_enc_suffix_from_path "${_final}")"
    cleanup_tmp_enc
    _tmp_encrypted="$(mktemp "${_dir}/.edit-cipher.XXXXXX${_suf}")"
    chmod 600 "${_tmp_encrypted}"

    if ! "${_encrypt_sh}" -k "${_get_kek}" -i "${_plain_in}" \
        -o "${_tmp_encrypted}"; then
        printf '%s\n' 'edit-encrypted: encrypt.sh failed' >&2
        return 1
    fi
    if ! "${_decrypt_sh}" -k "${_get_kek}" -i "${_tmp_encrypted}" \
        -o /dev/null; then
        printf '%s\n' 'edit-encrypted: validation decrypt failed' >&2
        return 1
    fi
    if ! eec_confirm_overwrite "${_final}"; then
        return 1
    fi
    mv -f "${_tmp_encrypted}" "${_final}"
    _tmp_encrypted=""
    printf '%s\n' "Wrote validated ciphertext: ${_final}" >&2
    return 0
}

_run_new() {
    _require_prereqs

    _plain_file="$(mktemp '/dev/shm/edit-new-plain.XXXXXX')"
    : > "${_plain_file}"
    chmod 600 "${_plain_file}"

    printf '%s\n' "Created empty file: ${_plain_file}"
    eec_print_edit_instructions "${_plain_file}"
    eec_prompt_press_enter_after_edit encrypt
    eec_ensure_plain_nonempty_or_confirm "${_plain_file}"

    eec_new_prompt_output_path_and_mkdir
    local _final="${EEC_OUT_FINAL}"

    if ! _encrypt_validate_install "${_plain_file}" "${_final}"; then
        exit 1
    fi

    trap - EXIT
    rm -f "${_plain_file}"
    printf '%s\n' "Removed plaintext: ${_plain_file}"
}

_run_edit() {
    if [[ ${#} -ne 1 ]]; then
        printf '%s\n' \
            'edit-encrypted: edit requires exactly one file' >&2
        usage
        exit 1
    fi
    _require_prereqs

    local _enc_in
    _enc_in="$(realpath "${1}")"
    if [[ ! -f "${_enc_in}" ]]; then
        printf '%s\n' "edit-encrypted: not a file: ${_enc_in}" >&2
        exit 1
    fi

    _plain_file="$(mktemp '/dev/shm/edit-plain.XXXXXX')"
    chmod 600 "${_plain_file}"

    if ! "${_decrypt_sh}" -k "${_get_kek}" -i "${_enc_in}" \
        -o "${_plain_file}"; then
        printf '%s\n' 'edit-encrypted: decrypt failed' >&2
        rm -f "${_plain_file}"
        exit 1
    fi

    printf '%s\n' "Decrypted to: ${_plain_file}"
    eec_print_edit_instructions "${_plain_file}"
    eec_prompt_press_enter_after_edit re-encrypt
    eec_ensure_plain_nonempty_or_confirm "${_plain_file}"

    eec_backup_resolve_and_mv_live "${_enc_in}"

    if ! _encrypt_validate_install "${_plain_file}" "${_enc_in}"; then
        printf '%s\n' \
            'edit-encrypted: failed after moving old file. Restore:' >&2
        printf '  mv -f %q %q\n' "${EEC_BACKUP}" "${_enc_in}" >&2
        exit 1
    fi

    eec_optional_delete_backup_prompt "${EEC_BACKUP}"

    trap - EXIT
    rm -f "${_plain_file}"
    printf '%s\n' "Removed plaintext: ${_plain_file}"
}

case "${_subcmd}" in
    new)
        _run_new
        ;;
    edit)
        _run_edit "${@}"
        ;;
    *)
        printf '%s\n' "edit-encrypted: unknown command: ${_subcmd}" >&2
        usage
        exit 1
        ;;
esac
