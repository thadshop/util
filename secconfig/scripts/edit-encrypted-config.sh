#!/usr/bin/env bash
# Executable: run this file; do not `source` it.
#
# Interactive sops workflow: cleartext only in /dev/shm; uses .sops.yaml rules.
# Use: edit-encrypted-config.sh [options] new | edit ENCRYPTED_FILE
#
# Shared prompts: keyring/edit-encrypted-common.bash
# -c overrides $SECCONFIG_DIR/.sops.yaml. Plaintext is staged under dirname(output)
# so sops path_regex can match.

set -e

_script_path="$(realpath "${BASH_SOURCE[0]}")"
_script_dir="$(dirname "${_script_path}")"
_keyring_dir="$(cd "${_script_dir}/../../keyring" && pwd)"

# shellcheck source=../../keyring/lib.bash
source "${_keyring_dir}/lib.bash"

if ! keyring_no_debug; then
    printf '%s\n' "edit-encrypted-config: refused (xtrace or verbose enabled)" >&2
    exit 1
fi

export EEC_MSG_PREFIX="edit-encrypted-config"
# shellcheck source=../../keyring/edit-encrypted-common.bash
source "${_keyring_dir}/edit-encrypted-common.bash"

_with_sops_dek="${_keyring_dir}/with-sops-dek.sh"
_default_get_dek="${_keyring_dir}/get-dek.sh"

_get_dek="${GET_DEK_PATH:-${_default_get_dek}}"
_explicit_sops=""
_plain_file=""
_staging_file=""
_tmp_encrypted=""

usage() {
    printf '%s\n' \
        "usage: edit-encrypted-config.sh [-k|--get-dek SCRIPT]" >&2
    printf '%s\n' \
        "                                [-c|--sops-config FILE] [-h|--help]" >&2
    printf '%s\n' \
        "                                new | edit ENCRYPTED_FILE" >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  new  — empty plaintext in /dev/shm; edit; encrypt with sops." >&2
    printf '%s\n' \
        "  edit — decrypt to /dev/shm; edit; re-encrypt (backup prompts)." >&2
    printf '%s\n' "" >&2
    printf '%s\n' \
        "  -c sets SOPS_CONFIG (overrides \${SECCONFIG_DIR}/.sops.yaml)." >&2
    printf '%s\n' \
        "  -k / GET_DEK_PATH → get-dek.sh (default: ${_default_get_dek})." >&2
}

cleanup_plain() {
    if [[ -n "${_plain_file}" ]] && [[ -f "${_plain_file}" ]]; then
        rm -f "${_plain_file}"
        printf '%s\n' "Removed plaintext: ${_plain_file}" >&2
    fi
}

cleanup_staging() {
    if [[ -n "${_staging_file}" ]] && [[ -f "${_staging_file}" ]]; then
        rm -f "${_staging_file}"
    fi
}

cleanup_tmp_enc() {
    if [[ -n "${_tmp_encrypted}" ]] && [[ -f "${_tmp_encrypted}" ]]; then
        rm -f "${_tmp_encrypted}"
    fi
}

trap 'cleanup_plain; cleanup_staging; cleanup_tmp_enc' EXIT

if ! OPTS=$(getopt -o k:c:h --long get-dek:,sops-config:,help \
    -n "$(basename "${0}")" -- "${@}"); then
    usage
    exit 1
fi
eval set -- "${OPTS}"

while true; do
    case "${1}" in
        -k|--get-dek)
            _get_dek="${2}"
            shift 2
            ;;
        -c|--sops-config)
            _explicit_sops="${2}"
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
            printf '%s\n' "edit-encrypted-config: invalid option: ${1}" >&2
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
    if ! command -v sops >/dev/null 2>&1; then
        printf '%s\n' 'edit-encrypted-config: sops not in PATH' >&2
        exit 1
    fi
    eec_require_shm
    if [[ ! -x "${_with_sops_dek}" ]]; then
        printf '%s\n' \
            "edit-encrypted-config: with-sops-dek not executable: ${_with_sops_dek}" \
            >&2
        exit 1
    fi
    if [[ ! -x "${_get_dek}" ]]; then
        printf '%s\n' \
            "edit-encrypted-config: get-dek not executable: ${_get_dek}" >&2
        exit 1
    fi
}

_resolve_sops_config() {
    if [[ -n "${_explicit_sops}" ]]; then
        if [[ ! -f "${_explicit_sops}" ]]; then
            printf '%s\n' \
                "edit-encrypted-config: --sops-config not a file: ${_explicit_sops}" \
                >&2
            exit 1
        fi
        _SOPS_CFG="$(cd "$(dirname "${_explicit_sops}")" && pwd)/$(basename "${_explicit_sops}")"
        return 0
    fi
    if [[ -n "${SECCONFIG_DIR:-}" ]]; then
        _root="$(cd "${SECCONFIG_DIR}" && pwd)"
        _cand="${_root}/.sops.yaml"
        if [[ -f "${_cand}" ]]; then
            _SOPS_CFG="${_cand}"
            return 0
        fi
    fi
    printf '%s\n' \
        'edit-encrypted-config: need --sops-config or SECCONFIG_DIR with' \
        ' .sops.yaml' >&2
    exit 1
}

_with_sops_cmd() {
    "${_with_sops_dek}" -k "${_get_dek}" -c "${_SOPS_CFG}" -- "${@}"
}

_staging_suffix_from_path() {
    local _base
    _base="$(basename "${1}")"
    case "${_base}" in
        *.enc.yaml) printf '%s' '.yaml' ;;
        *.enc.yml) printf '%s' '.yml' ;;
        *.enc.pem) printf '%s' '.pem' ;;
        *.yaml) printf '%s' '.yaml' ;;
        *.yml) printf '%s' '.yml' ;;
        *.pem) printf '%s' '.pem' ;;
        *) printf '%s' '.dat' ;;
    esac
}

_encrypted_suffix_from_path() {
    local _base
    _base="$(basename "${1}")"
    case "${_base}" in
        *.enc.yaml) printf '%s' '.enc.yaml' ;;
        *.enc.yml) printf '%s' '.enc.yml' ;;
        *.yaml) printf '%s' '.yaml' ;;
        *.yml) printf '%s' '.yml' ;;
        *.pem) printf '%s' '.pem' ;;
        *) printf '%s' '.enc' ;;
    esac
}

_encrypt_validate_install() {
    local _staging="${1}"
    local _final="${2}"
    local _dir _enc_suf
    _dir="$(cd "$(dirname "${_final}")" && pwd)"
    _enc_suf="$(_encrypted_suffix_from_path "${_final}")"
    cleanup_tmp_enc
    _tmp_encrypted="$(mktemp "${_dir}/.edit-cipher.XXXXXX${_enc_suf}")"
    export SOPS_CONFIG="${_SOPS_CFG}"
    if ! sops -e --output "${_tmp_encrypted}" "${_staging}"; then
        printf '%s\n' 'edit-encrypted-config: sops encrypt failed' >&2
        return 1
    fi
    rm -f "${_staging}"
    _staging_file=""
    if ! _with_sops_cmd sops decrypt --output /dev/null \
        "${_tmp_encrypted}"; then
        printf '%s\n' 'edit-encrypted-config: validation decrypt failed' >&2
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
    _resolve_sops_config

    _plain_file="$(mktemp '/dev/shm/edit-new-plain.XXXXXX.yaml')"
    : > "${_plain_file}"
    chmod 600 "${_plain_file}"

    printf '%s\n' "Created empty file: ${_plain_file}"
    eec_print_edit_instructions "${_plain_file}"
    eec_prompt_press_enter_after_edit encrypt
    eec_ensure_plain_nonempty_or_confirm "${_plain_file}"

    eec_new_prompt_output_path_and_mkdir
    local _final="${EEC_OUT_FINAL}"

    local _suf
    _suf="$(_staging_suffix_from_path "${_final}")"
    local _odir
    _odir="$(dirname "${_final}")"
    _staging_file="$(mktemp "${_odir}/.edit-staging-plain.XXXXXX${_suf}")"
    chmod 600 "${_staging_file}"
    cp "${_plain_file}" "${_staging_file}"

    if ! _encrypt_validate_install "${_staging_file}" "${_final}"; then
        exit 1
    fi

    trap - EXIT
    rm -f "${_plain_file}"
    printf '%s\n' "Removed plaintext: ${_plain_file}"
}

_run_edit() {
    if [[ ${#} -ne 1 ]]; then
        printf '%s\n' \
            'edit-encrypted-config: edit requires exactly one file' >&2
        usage
        exit 1
    fi
    _require_prereqs
    _resolve_sops_config

    local _enc_in
    _enc_in="$(realpath "${1}")"
    if [[ ! -f "${_enc_in}" ]]; then
        printf '%s\n' "edit-encrypted-config: not a file: ${_enc_in}" >&2
        exit 1
    fi

    local _suf
    _suf="$(_staging_suffix_from_path "${_enc_in}")"
    _plain_file="$(mktemp "/dev/shm/edit-plain.XXXXXX${_suf}")"
    chmod 600 "${_plain_file}"

    if ! _with_sops_cmd sops decrypt --output "${_plain_file}" "${_enc_in}"; then
        printf '%s\n' 'edit-encrypted-config: decrypt failed' >&2
        rm -f "${_plain_file}"
        exit 1
    fi

    printf '%s\n' "Decrypted to: ${_plain_file}"
    eec_print_edit_instructions "${_plain_file}"
    eec_prompt_press_enter_after_edit re-encrypt
    eec_ensure_plain_nonempty_or_confirm "${_plain_file}"

    local _odir
    _odir="$(dirname "${_enc_in}")"
    _staging_file="$(mktemp "${_odir}/.edit-staging-plain.XXXXXX${_suf}")"
    chmod 600 "${_staging_file}"
    cp "${_plain_file}" "${_staging_file}"

    eec_backup_resolve_and_mv_live "${_enc_in}"

    if ! _encrypt_validate_install "${_staging_file}" "${_enc_in}"; then
        printf '%s\n' \
            'edit-encrypted-config: failed after moving old file. Restore:' >&2
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
        printf '%s\n' "edit-encrypted-config: unknown command: ${_subcmd}" >&2
        usage
        exit 1
        ;;
esac
