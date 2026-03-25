#!/usr/bin/env bash
# Shared interactive helpers for edit-encrypted.sh (OpenSSL) and
# edit-encrypted-config.sh (sops). Source from those scripts; do not run alone.
# Caller should set EEC_MSG_PREFIX (e.g. edit-encrypted-config) before source.

# shellcheck shell=bash

: "${EEC_MSG_PREFIX:=edit-encrypted}"

# Cleartext editing instructions (path is the /dev/shm file to edit).
eec_print_edit_instructions() {
    local _plain="${1}"
    printf '%s\n' ""
    printf '%s\n' "Plaintext file (edit and save however you prefer):"
    printf '%s\n' "  ${_plain}"
    printf '%s\n' ""
    printf '%s\n' \
        "After saving, return here and press Enter. The plaintext will be" \
        "removed once encryption succeeds or if you exit (Ctrl-C) this script."
    printf '%s\n' ""
}

# After first Enter: if file still 0 bytes, prompt p/e/a.
eec_ensure_plain_nonempty_or_confirm() {
    local _pf="${1}"
    while [[ ! -s "${_pf}" ]]; do
        printf '%s\n' '' >&2
        printf '%s\n' 'Plaintext file is empty (0 bytes).' >&2
        printf '%s\n' \
            '  p — Proceed and encrypt empty content' >&2
        printf '%s\n' \
            '  e — Edit the file more; press Enter here when done' >&2
        printf '%s\n' '  a — Abort' >&2
        printf '%s' 'Choice [p/e/a]: ' >&2
        read -r _ch
        case "${_ch}" in
            p|P)
                return 0
                ;;
            e|E)
                printf '%s\n' "  File: ${_pf}" >&2
                printf '%s' \
                    'Press Enter when you have saved and want to continue... ' \
                    >&2
                read -r _
                ;;
            a|A|abort|Abort|ABORT)
                printf '%s\n' "${EEC_MSG_PREFIX}: aborted" >&2
                exit 1
                ;;
            *)
                printf '%s\n' 'Invalid choice; use p, e, or a.' >&2
                ;;
        esac
    done
    return 0
}

# Arg: prompt verb (e.g. encrypt | re-encrypt).
eec_prompt_press_enter_after_edit() {
    local _verb="${1:-encrypt}"
    printf '%s' \
        "Press Enter when the file is saved and you want to ${_verb}... "
    read -r _
}

# Read final path, optional mkdir -p; sets EEC_OUT_FINAL.
eec_new_prompt_output_path_and_mkdir() {
    printf '%s' 'Full path for new encrypted file: ' >&2
    read -r _out_raw
    if [[ -z "${_out_raw}" ]]; then
        printf '%s\n' "${EEC_MSG_PREFIX}: no output path" >&2
        exit 1
    fi
    EEC_OUT_FINAL="$(realpath -m "${_out_raw}")"
    local _odir
    _odir="$(dirname "${EEC_OUT_FINAL}")"
    if [[ ! -d "${_odir}" ]]; then
        printf '%s' "Create directory ${_odir}? [y/N] " >&2
        read -r _mk
        if [[ "${_mk}" != y ]]; then
            printf '%s\n' "${EEC_MSG_PREFIX}: cancelled" >&2
            exit 1
        fi
        mkdir -p "${_odir}"
    fi
}

# If path exists, require y to overwrite. Returns 1 if user declines.
eec_confirm_overwrite() {
    local _path="${1}"
    if [[ ! -e "${_path}" ]]; then
        return 0
    fi
    printf '%s\n' "Path already exists: ${_path}" >&2
    printf '%s' 'Overwrite? [y/N] ' >&2
    read -r _reply
    if [[ "${_reply}" != y ]]; then
        printf '%s\n' "${EEC_MSG_PREFIX}: cancelled" >&2
        return 1
    fi
    return 0
}

# Resolve backup path, mv live ciphertext to backup; sets EEC_BACKUP.
# Arg: path to current encrypted file (live).
eec_backup_resolve_and_mv_live() {
    local _enc_in="${1}"
    local _default_backup="${_enc_in}.old"
    local _backup=""
    printf '%s\n' "Backup path for the current encrypted file (default below)." >&2
    printf '%s\n' "  Default: ${_default_backup}" >&2
    printf '%s' 'Enter backup path, or Enter for default: ' >&2
    read -r _backup_raw
    if [[ -z "${_backup_raw}" ]]; then
        _backup="${_default_backup}"
    else
        _backup="$(realpath -m "${_backup_raw}")"
    fi

    local _backup_dir
    while true; do
        _backup_dir="$(dirname "${_backup}")"
        if [[ ! -d "${_backup_dir}" ]]; then
            printf '%s\n' \
                "${EEC_MSG_PREFIX}: backup directory missing: ${_backup_dir}" >&2
            printf '%s' 'Enter a new backup path, or type abort: ' >&2
            read -r _retry
            case "${_retry}" in
                abort|Abort|ABORT)
                    printf '%s\n' "${EEC_MSG_PREFIX}: aborted" >&2
                    exit 1
                    ;;
            esac
            if [[ -z "${_retry}" ]]; then
                continue
            fi
            _backup="$(realpath -m "${_retry}")"
            continue
        fi

        if [[ -e "${_backup}" ]]; then
            printf '%s\n' "Path already exists: ${_backup}" >&2
            printf '%s' 'Overwrite? [y/N] ' >&2
            read -r _reply
            if [[ "${_reply}" != y ]]; then
                printf '%s\n' \
                    'Enter a new backup path, or type abort to exit:' >&2
                printf '%s' '> ' >&2
                read -r _retry
                case "${_retry}" in
                    abort|Abort|ABORT)
                        printf '%s\n' "${EEC_MSG_PREFIX}: aborted" >&2
                        exit 1
                        ;;
                esac
                if [[ -z "${_retry}" ]]; then
                    continue
                fi
                _backup="$(realpath -m "${_retry}")"
                continue
            fi
        fi

        if mv -f "${_enc_in}" "${_backup}"; then
            printf '%s\n' "Previous ciphertext moved to: ${_backup}" >&2
            export EEC_BACKUP="${_backup}"
            return 0
        fi

        printf '%s\n' \
            "${EEC_MSG_PREFIX}: could not move ciphertext to ${_backup}" >&2
        printf '%s\n' \
            '(check permissions). Enter a different backup path, or abort:' >&2
        printf '%s' '> ' >&2
        read -r _retry
        case "${_retry}" in
            abort|Abort|ABORT)
                printf '%s\n' "${EEC_MSG_PREFIX}: aborted" >&2
                exit 1
                ;;
        esac
        if [[ -z "${_retry}" ]]; then
            continue
        fi
        _backup="$(realpath -m "${_retry}")"
    done
}

eec_optional_delete_backup_prompt() {
    local _backup="${1}"
    printf '%s' "Delete backup at ${_backup}? [y/N] " >&2
    read -r _delb
    if [[ "${_delb}" == y ]]; then
        rm -f "${_backup}"
        printf '%s\n' "Deleted backup." >&2
    else
        printf '%s\n' "Backup kept at ${_backup}" >&2
    fi
}

eec_require_shm() {
    if [[ ! -d /dev/shm ]]; then
        printf '%s\n' "${EEC_MSG_PREFIX}: /dev/shm not found" >&2
        exit 1
    fi
}
